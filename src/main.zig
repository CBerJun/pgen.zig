const std = @import("std");
const builtin = @import("builtin");
const pgen = @import("pgen");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

const BUFFER_SIZE = 4096;

const Logger = struct {
    io: std.Io,
    file: std.Io.File,
    allocator: std.mem.Allocator,
    buffer: []u8,
    file_writer: std.Io.File.Writer,

    pub fn init(init_: std.process.Init, allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        const buffer = try allocator.alloc(u8, BUFFER_SIZE);
        const stderr = std.Io.File.stderr();
        return .{
            .io = init_.io,
            .file = stderr,
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
            std.debug.print("writing to stderr failed ({s})", .{@errorName(err)});
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

const CliParser = struct {
    iterator: std.process.Args.Iterator,
    /// Allocator for string options
    allocator: std.mem.Allocator,
    /// CLI errors use aggregator too
    aggregator: *pgen.diagnostic.Aggregator,

    // Following are parsed option values, owned by this struct
    cst_owns_token: bool = false,
    token_extra: []u8 = &.{},
    in_file_path: []u8 = &.{},
    out_file_path: []u8 = &.{},
    dump_cfg: bool = false,

    pub fn init(process_init: std.process.Init, allocator: std.mem.Allocator, aggregator: *pgen.diagnostic.Aggregator) std.mem.Allocator.Error!@This() {
        return .{
            .iterator = try process_init.minimal.args.iterateAllocator(allocator),
            .allocator = allocator,
            .aggregator = aggregator,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.iterator.deinit();
        self.allocator.free(self.token_extra);
        self.allocator.free(self.in_file_path);
        self.allocator.free(self.out_file_path);
        self.* = undefined;
    }

    /// Run the parser, return successful or not
    pub fn go(self: *@This()) bool {
        // Skip argv[0]
        if (!self.iterator.skip()) {
            self.aggregator.add(.fatal, "expected argv[0] to exist", .{});
            return false;
        }
        var end_of_options = false; // Reached forced end of option "--"
        while (self.iterator.next()) |arg| {
            if (arg.len == 0) {
                self.aggregator.add(.warning, "skipping empty CLI argument", .{});
                continue;
            }
            if (arg[0] != '-' or end_of_options) {
                // Non-option, treat as input file
                self.in_file_path = self.allocator.dupe(u8, arg) catch {
                    self.aggregator.add(.fatal, "OOM (dupe in file path)", .{});
                    return false;
                };
                if (self.iterator.skip()) {
                    self.aggregator.add(.warning, "ignoring CLI arguments after {s}", .{self.in_file_path});
                }
                break;
            }
            // Now process options
            const rest = arg[1..];
            if (std.mem.eql(u8, rest, "-")) {
                end_of_options = true;
            } else if (std.mem.eql(u8, rest, "cst-owns-token")) {
                self.cst_owns_token = true;
            } else if (std.mem.eql(u8, rest, "token-extra")) {
                if (self.token_extra.len > 0) {
                    self.aggregator.add(.fatal, "-token-extra already set", .{});
                    return false;
                }
                if (self.iterator.next()) |payload| {
                    self.token_extra = self.allocator.dupe(u8, payload) catch {
                        self.aggregator.add(.fatal, "OOM (dupe -token-extra)", .{});
                        return false;
                    };
                } else {
                    self.aggregator.add(.fatal, "expected parameter following -token-extra", .{});
                    return false;
                }
            } else if (std.mem.eql(u8, rest, "o") or std.mem.eql(u8, rest, "out")) {
                if (self.out_file_path.len > 0) {
                    self.aggregator.add(.fatal, "-o/-out already set", .{});
                    return false;
                }
                if (self.iterator.next()) |payload| {
                    self.out_file_path = self.allocator.dupe(u8, payload) catch {
                        self.aggregator.add(.fatal, "OOM (dupe -o/-out)", .{});
                        return false;
                    };
                } else {
                    self.aggregator.add(.fatal, "expected parameter following -o/-out", .{});
                    return false;
                }
            } else if (std.mem.eql(u8, rest, "h")) {
                std.debug.print(
                    \\Usage: pgenzig [options] in_file
                    \\
                    \\Option list:
                    \\    --                End of option list signal
                    \\    -o/-out FILE      Output file
                    \\    -cst-owns-token   If set, CSTNodes will own the passed in tokens. There is implication on mem management. See generated source's doc.
                    \\    -token-extra CODE Extra source code to add into the Token struct.
                    \\    -h                Print this message
                    \\
                    \\Debug option for developers:
                    \\    -dump-cfg         Dump generated CFG
                    \\
                , .{});
            } else if (std.mem.eql(u8, rest, "dump-cfg")) {
                self.dump_cfg = true;
            } else {
                self.aggregator.add(.fatal, "unrecognized argument -{s}", .{rest});
                return false;
            }
        }
        if (self.in_file_path.len == 0) {
            self.aggregator.add(.fatal, "expected input grammar path", .{});
            return false;
        }
        return true;
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

    // Prepare diagnostic aggregator
    var aggregator: pgen.diagnostic.Aggregator = .withLogging(gpa);
    defer aggregator.deinit();
    defer aggregator.printDiagnostics(logger.writer()) catch |err| {
        logger.check(err);
    };

    var cli = CliParser.init(init, gpa, &aggregator) catch {
        logger.writeLine("OOM (CLI parser)");
        return 1;
    };
    defer cli.deinit();

    if (!cli.go()) {
        logger.writeLine("CLI parsing failed; pass -h to see usage");
        return 1;
    }

    // Read the in file (grammar description)
    const in_file = std.Io.Dir.cwd().openFile(init.io, cli.in_file_path, .{ .allow_directory = false }) catch |err| {
        logger.printLine("failed to open in file: {s}", .{@errorName(err)});
        return 1;
    };
    defer in_file.close(init.io);

    // Invent an out file path if not specified
    if (cli.out_file_path.len == 0) {
        const suffix = ".zig";
        cli.out_file_path = cli.allocator.alloc(u8, cli.in_file_path.len + suffix.len) catch {
            logger.printLine("OOM (auto out file path)", .{});
            return 1;
        };
        @memcpy(cli.out_file_path[0..cli.in_file_path.len], cli.in_file_path);
        @memcpy(cli.out_file_path[cli.in_file_path.len..], suffix);
    }

    const out_file = std.Io.Dir.cwd().createFile(init.io, cli.out_file_path, .{}) catch |err| {
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
    var cfg_managed, var symbol_spec = blk: {
        var ast = pgen.cst2ast.EbnfManaged.fromCst(cst, gpa, gpa, &aggregator) catch |err| {
            switch (err) {
                error.OutOfMemory => logger.writeLine("OOM (CST to AST)"),
                error.Cst2AstSemanticError => logger.writeLine("CST to AST failed"), // Details logged by aggregator
            }
            return 1;
        };
        defer ast.deinit();
        break :blk .{ pgen.ast2cfg.CfgManaged.fromAst(ast.symbol_spec, ast.productions, &ast.pool, gpa, gpa) catch {
            logger.writeLine("OOM (AST to CFG)");
            return 1;
        }, ast.ownedSymbolSpec() };
    };
    defer symbol_spec.deinit(gpa);
    defer cfg_managed.deinit();

    // Debug dump the CFG
    if (cli.dump_cfg) {
        dumpCfg(cfg_managed.symbol_spec, cfg_managed.productions);
    }

    // Currently just enable SLR backend.
    var ds: pgen.lr0.DataStructures = .{
        .allocator = gpa,
        .symbol_spec = cfg_managed.symbol_spec,
        .productions = cfg_managed.productions,
    };
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
            .cst_owns_token = cli.cst_owns_token,
            .token_extra = &.{cli.token_extra},
        },
        .follow_sets = &follow_set,
        .action_handler = .{
            .symbol_spec = &cfg_managed.symbol_spec,
            .productions = &cfg_managed.productions,
            .conflict_resolver = {},
        },
        .goto_handler = .{},
    };
    defer backend.free();
    pgen.lr0.lr0(
        cfg_managed.symbol_spec,
        cfg_managed.productions,
        tarjan,
        first_reachability,
        @TypeOf(backend),
        &backend,
        gpa,
    ) catch |err| {
        switch (err) {
            error.OutOfMemory => logger.writeLine("OOM (LR(0) table gen)"),
            error.WriteFailed => logger.writeLine("Write to output file failed"),
            error.LrConflict => {
                logger.writeLine("Table gen conflict! Your grammar is ambiguous OR not SLR-compatible.");
                const cr = backend.conflict_report.?;
                pgen.explain.conflict(
                    gpa,
                    pgen.lr0.Item,
                    logger.writer(),
                    cfg_managed.symbol_spec,
                    cfg_managed.productions,
                    cr,
                ) catch |err2| {
                    switch (err2) {
                        error.OutOfMemory => logger.writeLine("OOM (conflict message)"),
                        error.WriteFailed => |e| logger.check(e),
                    }
                    return 1;
                };
            },
        }
        return 1;
    };
    writer.flush() catch {
        logger.writeLine("Flushing output stream failed");
        return 1;
    };
    return 0;
}

fn dumpCfg(symbol_spec: pgen.sym.SymbolSpec, productions: pgen.cfg.CfgProductions) void {
    std.debug.print("CFG dump (T={}, NT={}/{}, P={}, E=NT{})\n", .{
        symbol_spec.terminals.count,
        symbol_spec.nonterminals.count,
        symbol_spec.nonterminals.node_forming_count,
        productions.count,
        symbol_spec.nonterminals.entry,
    });
    for (0..symbol_spec.nonterminals.node_forming_count) |nt| {
        std.debug.print("  NT{}: {s}\n", .{ nt, symbol_spec.nonterminals.names[nt] });
    }
    for (0..productions.count) |prod| {
        std.debug.print("  Prod({}) NT{}:", .{ prod, productions.lhs[prod] });
        for (productions.rhs[prod]) |sym| {
            switch (sym) {
                .terminal => |t| std.debug.print(" T{}", .{t}),
                .nonterminal => |nt| std.debug.print(" NT{}", .{nt}),
            }
        }
        std.debug.print("\n", .{});
    }
    std.debug.print("Pact:", .{});
    for (productions.pact[0..symbol_spec.nonterminals.count]) |pact| {
        std.debug.print(" {}", .{pact});
    }
    std.debug.print("\n", .{});
}
