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

// Returned buffer must be deinited with `pgenReleaseMessage`.
export fn pgenParse(src_ptr: [*]const u8, src_len: usize, out_ptr: *[]const u8) void {
    const src: []const u8 = src_ptr[0..src_len];
    var fixed_reader: std.Io.Reader = .fixed(src);
    const reader = &fixed_reader;

    var aggregator: pgen.diagnostic.Aggregator = .withLogging(gpa);
    defer aggregator.deinit();
    var report: ErrorReport = .init();
    defer {
        report.dumpAggregator(&aggregator);
        out_ptr.* = report.getResult();
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
        parser.feed(gpa, token) catch |err| switch (err) {
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
        };
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
