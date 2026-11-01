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

    // Prepare diagnostic aggregator for CLI
    var aggregator: pgen.diagnostic.Aggregator = .withLogging(gpa);
    defer aggregator.deinit();
    var cli = CliParser.init(init, gpa, &aggregator) catch {
        logger.writeLine("OOM (CLI parser)");
        return 1;
    };
    defer cli.deinit();

    if (!cli.go()) {
        logger.writeLine("CLI parsing failed; pass -h to see usage");
        aggregator.printDiagnostics(logger.writer()) catch |err| logger.check(err);
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

    const driver: pgen.driver.Driver = .init(gpa, reader, logger.writer(), writer, .{
        .cst_owns_token = cli.cst_owns_token,
        .token_extra = &.{cli.token_extra},
        .dump_cfg = cli.dump_cfg,
    });
    driver.go() catch |err| {
        switch (err) {
            error.GrammarError => {}, // Already logged
            error.OutOfMemory => logger.writeLine("out of memory!"),
            error.ReadFailed => logger.writeLine("read input failed!"),
            error.WriteFailed => logger.writeLine("write output/stderr failed!"),
        }
        return 1;
    };
    return 0;
}
