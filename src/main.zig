const std = @import("std");
const builtin = @import("builtin");
const pgen = @import("pgen");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

const BUFFER_SIZE = 4096;

const Logger = struct {
    io: std.Io,
    stderr: std.Io.File,
    allocator: std.mem.Allocator,
    buffer: []u8,
    file_writer: std.Io.File.Writer,

    pub fn init(init_: std.process.Init, allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        const buffer = try allocator.alloc(u8, BUFFER_SIZE);
        const stderr = std.Io.File.stderr();
        return .{
            .io = init_.io,
            .stderr = stderr,
            .allocator = allocator,
            .buffer = buffer,
            .file_writer = stderr.writer(init_.io, buffer),
        };
    }

    pub fn writer(self: *@This()) *std.Io.Writer {
        return &self.file_writer.interface;
    }

    pub fn check(_: @This(), err_union: std.Io.Writer.Error!void) void {
        err_union catch {
            std.debug.print("writing to stderr failed\n", .{});
        };
    }

    pub fn deinit(self: *@This()) void {
        self.file_writer.flush() catch |err| {
            std.debug.print("write to stderr failed ({s})", .{@errorName(err)});
        };
        self.allocator.free(self.buffer);
        self.* = undefined;
    }

    pub fn printLine(self: *@This(), comptime fmt: []const u8, args: anytype) void {
        self.check(self.writer().print(fmt, args));
        self.check(self.writer().writeByte('\n'));
    }

    pub fn write(self: *@This(), str: []const u8) void {
        self.check(self.writer().writeAll(str));
    }

    pub fn writeLine(self: *@This(), str: []const u8) void {
        self.check(self.writer().writeAll(str));
        self.check(self.writer().writeByte('\n'));
    }
};

pub fn main(init: std.process.Init) u8 {
    // Setup allocator (see https://ziglang.org/download/0.14.0/release-notes.html#SmpAllocator)
    const gpa, const is_debug = gpa: {
        if (builtin.target.os.tag == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    var logger = Logger.init(init, gpa) catch {
        std.debug.print("no memory to create logger\n", .{});
        return 1;
    };
    defer logger.deinit();

    // Read the in file (grammar description)
    var arg_it = init.minimal.args.iterateAllocator(gpa) catch {
        logger.writeLine("OOM (argv)");
        return 1;
    };
    defer arg_it.deinit();
    if (!arg_it.skip()) {
        logger.writeLine("expected argv[0] to exist");
        return 1;
    }
    const in_file_path = arg_it.next() orelse {
        logger.writeLine("expected input grammar path");
        return 1;
    };
    const in_file = std.Io.Dir.cwd().openFile(init.io, in_file_path, .{ .allow_directory = false }) catch |err| {
        logger.printLine("failed to open in file: {s}", .{@errorName(err)});
        return 1;
    };
    defer in_file.close(init.io);
    const out_file_path = arg_it.next() orelse {
        logger.writeLine("expected output path");
        return 1;
    };
    const out_file = std.Io.Dir.cwd().createFile(init.io, out_file_path, .{}) catch |err| {
        logger.printLine("failed to open out file: {s}", .{@errorName(err)});
        return 1;
    };
    defer out_file.close(init.io);
    const read_buffer = gpa.alloc(u8, BUFFER_SIZE) catch {
        logger.writeLine("OOM (read buffer)");
        return 1;
    };
    defer gpa.free(read_buffer);
    var in_file_reader = in_file.reader(init.io, read_buffer);
    const reader = &in_file_reader.interface;
    const write_buffer = gpa.alloc(u8, BUFFER_SIZE) catch {
        logger.writeLine("OOM (write buffer)");
        return 1;
    };
    defer gpa.free(write_buffer);
    var out_file_writer = out_file.writer(init.io, write_buffer);
    const writer = &out_file_writer.interface;

    // Prepare diagnostic aggregator
    var aggregator: pgen.diagnostic.Aggregator = .withLogging(gpa);
    defer aggregator.deinit();
    defer aggregator.printDiagnostics(logger.writer()) catch |err| {
        logger.check(err);
    };

    // Tokenize and parse it
    var tokenizer: pgen.Tokenizer = .{
        .reader = reader,
        .payload_allocator = gpa,
        .scrap_allocator = gpa,
        .diagnostic_aggregator = &aggregator,
    };
    var parser = pgen.psr.Parser.init(gpa) catch |err| switch (err) {
        error.OutOfMemory => {
            logger.writeLine("OOM (parser init)");
            return 1;
        },
    };
    defer parser.deinit(gpa);
    while (tokenizer.nextToken() catch |err| {
        switch (err) {
            error.InvalidSyntax => logger.writeLine("tokenize failed"), // Details logged by aggregator
            error.OutOfMemory => logger.writeLine("OOM (in file tokenization)"),
            error.ReadFailed => logger.writeLine("in file read failed"),
        }
        return 1;
    }) |token| {
        parser.feed(gpa, token) catch |err| {
            token.deinit(gpa);
            switch (err) {
                error.OutOfMemory => logger.writeLine("OOM (in file parsing)"),
                // TODO: diagnostic
                error.PgenParseError => logger.writeLine("parse failed"),
            }
            return 1;
        };
        if (token.tag == .@"$") {
            // The EOI token does not end up in the CST and needs to be freed
            // separately.
            token.deinit(gpa);
        }
    }
    var cst = parser.retrieve();
    defer cst.deinit(gpa);
    var ast = pgen.cst2ast.EbnfManaged.fromCst(cst, gpa, gpa, &aggregator) catch |err| {
        switch (err) {
            error.OutOfMemory => logger.writeLine("OOM (CST to AST)"),
            error.Cst2AstSemanticError => logger.writeLine("CST to AST failed"), // Details logged by aggregator
        }
        return 1;
    };
    defer ast.deinit();
    // XXX: `cfg` does borrow from `ast`-owned memory. See core/ast2cfg.zig
    var cfg_managed = pgen.ast2cfg.CfgManaged.fromAst(ast.ebnf, &ast.pool, gpa, gpa) catch {
        logger.writeLine("OOM (AST to CFG)");
        return 1;
    };
    defer cfg_managed.deinit();
    const cfg = cfg_managed.cfg;

    // Debug dump the CFG
    // dumpCfg(cfg);

    // Currently just enable SLR backend.
    var ds: pgen.lr0.DataStructures = .{ .allocator = gpa, .grammar = cfg };
    defer ds.deinit();
    const tarjan = ds.getFirstTarjan() catch {
        logger.writeLine("OOM (FIRST graph Tarjan)");
        return 1;
    };
    const first_reachability = ds.getFirstReachability() catch {
        logger.writeLine("OOM (FIRST graph reachability)");
        return 1;
    };
    const follow_set = ds.getFollowSet() catch {
        logger.writeLine("OOM (FOLLOW set)");
        return 1;
    };
    var backend: pgen.backends.SlrBackend(
        pgen.backends.ZigSwitchActionHandler(void),
        pgen.backends.ZigSwitchGotoHandler,
    ) = .{
        .emitter = .{
            .out = writer,
            .cst_owns_token = true,
            .token_extra = &.{
                // deinit does nothing for now
                "pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {",
                "    _ = self;",
                "    _ = allocator;",
                "}",
            },
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
            error.OutOfMemory => logger.writeLine("OOM (LR(0) table gen)"),
            error.WriteFailed => logger.writeLine("Write to output file failed"),
            // TODO: diagnostics
            error.LrConflict => logger.writeLine("Table gen conflict! Your grammar is ambiguous OR not SLR-compatible."),
        }
        return 1;
    };
    writer.flush() catch {
        logger.writeLine("Flushing output stream failed");
        return 1;
    };
    return 0;
}

fn dumpCfg(cfg: pgen.cfg.Cfg) void {
    std.debug.print("CFG dump (T={}, NT={}/{}, P={}, E=NT{})\n", .{
        cfg.terminals.count,
        cfg.nonterminals.count,
        cfg.nonterminals.node_forming_count,
        cfg.total_productions,
        cfg.nonterminals.entry,
    });
    for (0..cfg.nonterminals.node_forming_count) |nt| {
        std.debug.print("  NT{}: {s}\n", .{ nt, cfg.nonterminals.names[nt] });
    }
    for (0..cfg.total_productions) |prod| {
        std.debug.print("  Prod({}) NT{}:", .{ prod, cfg.production_lhs[prod] });
        for (cfg.productions[prod]) |sym| {
            switch (sym) {
                .terminal => |t| std.debug.print(" T{}", .{t}),
                .nonterminal => |nt| std.debug.print(" NT{}", .{nt}),
            }
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("Pact:", .{});
    for (cfg.production_pact[0..cfg.nonterminals.count]) |pact| {
        std.debug.print(" {}", .{pact});
    }
    std.debug.print("\n", .{});
}
