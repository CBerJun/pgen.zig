const std = @import("std");
const pgen = @import("pgen");

const gpa = std.heap.wasm_allocator;

const ErrorReport = struct {
    allocating_writer: std.Io.Writer.Allocating,
    oom: bool,
    failed: bool,

    pub const oom_instance = "Out of memory while printing error";
    pub const ok_instance = "OK (no error)";

    pub fn init() @This() {
        return .{
            .allocating_writer = .init(gpa),
            .oom = false,
            .failed = false,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.allocating_writer.deinit();
        self.* = undefined;
    }

    pub fn writer(self: *@This()) *std.Io.Writer {
        return &self.allocating_writer.writer;
    }

    pub fn addError(self: *@This(), comptime fmt: []const u8, args: anytype) void {
        self.failed = true;
        if (self.oom)
            return;
        self.writer().print(fmt, args) catch {
            // The reason an allocating writer fails is OOM
            self.oom = true;
        };
    }

    pub fn dumpAggregator(self: *@This(), aggregator: *pgen.diagnostic.Aggregator) void {
        if (aggregator.fatal)
            self.failed = true;
        if (self.oom)
            return;
        aggregator.printDiagnostics(self.writer()) catch {
            self.oom = true;
        };
    }

    pub fn getResult(self: *@This()) []const u8 {
        if (self.oom)
            return oom_instance;
        if (!self.failed)
            return ok_instance;
        return self.allocating_writer.toOwnedSlice() catch oom_instance;
    }
};

// Returned buffer (`out_error`, `out_result`) must be deinited with
// `releaseMessage`.
export fn pgenParse(
    src_ptr: [*]const u8,
    src_len: usize,
    out_error: *[]const u8,
    out_result: *[]const u8,
    // Config options
    cst_owns_token: bool,
) void {
    const src: []const u8 = src_ptr[0..src_len];
    var fixed_reader: std.Io.Reader = .fixed(src);
    const reader = &fixed_reader;

    out_result.* = &.{};

    var aggregator: pgen.diagnostic.Aggregator = .withLogging(gpa);
    defer aggregator.deinit();
    var report: ErrorReport = .init();
    defer {
        report.dumpAggregator(&aggregator);
        out_error.* = report.getResult();
        report.deinit();
    }

    var tokenizer: pgen.Tokenizer = .{
        .reader = reader,
        .payload_allocator = gpa,
        .scrap_allocator = gpa,
        .diagnostic_aggregator = &aggregator,
    };
    var parser = pgen.psr.Parser.init(gpa) catch |err| switch (err) {
        error.OutOfMemory => {
            report.addError("OOM (tokenizer)\n", .{});
            return;
        },
    };
    defer parser.deinit(gpa);
    while (tokenizer.nextToken() catch |err| switch (err) {
        error.InvalidSyntax => {
            // Details logged by aggregator.
            return;
        },
        error.OutOfMemory => {
            report.addError("OOM (nextToken)\n", .{});
            return;
        },
        error.ReadFailed => unreachable,
    }) |token| {
        parser.feed(gpa, token) catch |err| {
            token.deinit(gpa);
            switch (err) {
                error.OutOfMemory => {
                    report.addError("OOM (parser)\n", .{});
                    return;
                },
                error.PgenParseError => {
                    const loc = tokenizer.current_loc;
                    report.addError("parse failed near line {}, column {}", .{
                        // 0-indexed to 1-indexed
                        loc.ln + 1, loc.col + 1,
                    });
                    return;
                },
            }
        };
        if (token.tag == .@"$") {
            // The EOI token does not end up in the CST and needs to be freed
            // separately.
            token.deinit(gpa);
        }
    }
    var cst = parser.retrieve();
    defer cst.deinit(gpa);
    var ast = pgen.cst2ast.EbnfManaged.fromCst(cst, gpa, gpa, &aggregator) catch |err| switch (err) {
        error.OutOfMemory => {
            report.addError("OOM (CST to AST)\n", .{});
            return;
        },
        error.Cst2AstSemanticError => {
            // Details logged by aggregator.
            return;
        },
    };
    defer ast.deinit();
    var cfg_managed = pgen.ast2cfg.CfgManaged.fromAst(ast.ebnf, &ast.pool, gpa, gpa) catch {
        report.addError("OOM (AST to CFG)", .{});
        return;
    };
    defer cfg_managed.deinit();
    const cfg = cfg_managed.cfg;

    // BELIEVE IT OR NOT, DELETING THIS STATEMENT BELOW CAUSES A CRASH AT
    // RUNTIME: changing `cfg.total_productions` to something else that does
    // not access `cfg` also causes crash. It's either an upstream bug in
    // Zig compiler, or we are invoking illegal behavior. However this code
    // is mostly adapted from the main CLI which runs just fine.
    defer report.addError("Total CFG productions: {}\n", .{
        cfg.total_productions,
    });
    // Currently just enable SLR backend.
    var ds: pgen.lr0.DataStructures = .{ .allocator = gpa, .grammar = cfg };
    defer ds.deinit();
    const tarjan = ds.getFirstTarjan() catch {
        report.addError("OOM (FIRST graph Tarjan)", .{});
        return;
    };
    const first_reachability = ds.getFirstReachability() catch {
        report.addError("OOM (FIRST graph reachability)", .{});
        return;
    };
    const follow_set = ds.getFollowSet() catch {
        report.addError("OOM (FOLLOW set)", .{});
        return;
    };

    var result_alloc_writer: std.Io.Writer.Allocating = .init(gpa);
    defer result_alloc_writer.deinit();
    const writer = &result_alloc_writer.writer;

    var backend: pgen.backends.SlrBackend(
        pgen.backends.ZigSwitchActionHandler(void),
        pgen.backends.ZigSwitchGotoHandler,
    ) = .{
        .emitter = .{
            .out = writer,
            .cst_owns_token = cst_owns_token,
            // No -token-extra for web demo
            .token_extra = &.{},
        },
        .follow_sets = &follow_set,
        .action_handler = .{
            .grammar = &cfg,
            .conflict_resolver = {},
        },
        .goto_handler = .{},
    };
    defer backend.free();
    pgen.lr0.lr0(
        cfg,
        tarjan,
        first_reachability,
        @TypeOf(backend),
        &backend,
        gpa,
    ) catch |err| {
        switch (err) {
            error.OutOfMemory => report.addError("OOM (LR(0) table gen)", .{}),
            error.WriteFailed => report.addError("Write to output file failed", .{}),
            // TODO: diagnostics
            error.LrConflict => report.addError("Table gen conflict! Your grammar is ambiguous OR not SLR-compatible.", .{}),
        }
        return;
    };
    writer.flush() catch {
        report.addError("Flushing output stream failed", .{});
        return;
    };

    out_result.* = result_alloc_writer.toOwnedSlice() catch {
        report.addError("OOM (result to owned)", .{});
        return;
    };
}

export fn releaseMessage(buf: *const []const u8) void {
    if (buf.ptr == ErrorReport.oom_instance or buf.ptr == ErrorReport.ok_instance) {
        return;
    }
    gpa.free(buf.*);
}

export fn newMessagePtr() *[]const u8 {
    return gpa.create([]const u8) catch @ptrCast(@alignCast(invalidPtr()));
}

export fn newBuffer(n: usize) [*]u8 {
    const slice = gpa.alloc(u8, n) catch {
        return @ptrCast(invalidPtr());
    };
    return slice.ptr;
}

export fn freeBuffer(ptr: [*]u8, n: usize) void {
    gpa.free(ptr[0..n]);
}

export fn messagePtr(msg: *const []const u8) [*]const u8 {
    return msg.ptr;
}
export fn messageLen(msg: *const []const u8) usize {
    return msg.len;
}

export fn invalidPtr() *anyopaque {
    return @constCast(&gpa);
}
