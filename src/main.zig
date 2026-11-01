const std = @import("std");
const builtin = @import("builtin");
const pgen = @import("pgen");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

const BUFFER_SIZE = 4096;

const ParsedArgs = struct {
    allocator: std.mem.Allocator,
    // These specify the default values.
    cst_owns_token: bool = false,
    token_extra: []u8 = &.{},
    in_file_path: []u8 = &.{},
    out_file_path: []u8 = &.{},
    dump_cfg: bool = false,
    help: bool = false,

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.token_extra);
        self.allocator.free(self.in_file_path);
        self.allocator.free(self.out_file_path);
        self.* = undefined;
    }
};

const CliParser = struct {
    iterator: std.process.Args.Iterator,
    /// Allocator for string options
    allocator: std.mem.Allocator,
    /// CLI errors use aggregator too
    aggregator: *pgen.diagnostic.Aggregator,

    pub const help_message =
        \\Usage: pgenzig [options] in_file
        \\
        \\Option list:
        \\    --                End of option list signal
        \\    -o/-out FILE      Output file
        \\    -cst-owns-token   If set, `CSTNode`s will own the passed in tokens. There is implication on mem management. See generated source's doc.
        \\    -token-extra CODE Extra source code to add into the `Token` struct
        \\    -h                Print this message and exit
        \\
        \\Debug options for developers:
        \\    -dump-cfg         Dump generated CFG
        \\
    ;

    pub const Error = std.mem.Allocator.Error || error{
        CliParseError,
    };

    pub fn init(process_init: std.process.Init, allocator: std.mem.Allocator, aggregator: *pgen.diagnostic.Aggregator) std.mem.Allocator.Error!@This() {
        const iterator = try process_init.minimal.args.iterateAllocator(allocator);
        return .{
            .iterator = iterator,
            .allocator = allocator,
            .aggregator = aggregator,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.iterator.deinit();
        self.* = undefined;
    }

    /// Run the parser; for `error.CliParseError` we log the message into
    /// aggregator.
    pub fn go(self: *@This()) Error!ParsedArgs {
        var ans: ParsedArgs = .{ .allocator = self.allocator };
        errdefer ans.deinit();
        // Skip argv[0]
        if (!self.iterator.skip()) {
            self.aggregator.add(.fatal, "expected argv[0] to exist", .{});
            return error.CliParseError;
        }
        var end_of_options = false; // Reached forced end of option "--"
        while (self.iterator.next()) |arg| {
            if (arg.len == 0) {
                self.aggregator.add(.warning, "skipping empty CLI argument", .{});
                continue;
            }
            if (arg[0] != '-' or end_of_options) {
                // Non-option, treat as input file
                ans.in_file_path = try self.allocator.dupe(u8, arg);
                if (self.iterator.skip()) {
                    self.aggregator.add(.warning, "ignoring CLI arguments after {s}", .{ans.in_file_path});
                }
                break;
            }
            // Now process options
            const rest = arg[1..];
            if (std.mem.eql(u8, rest, "-")) {
                end_of_options = true;
            } else if (std.mem.eql(u8, rest, "cst-owns-token")) {
                ans.cst_owns_token = true;
            } else if (std.mem.eql(u8, rest, "token-extra")) {
                if (ans.token_extra.len > 0) {
                    self.aggregator.add(.fatal, "-token-extra already set", .{});
                    return error.CliParseError;
                }
                if (self.iterator.next()) |payload| {
                    ans.token_extra = try self.allocator.dupe(u8, payload);
                } else {
                    self.aggregator.add(.fatal, "expected parameter following -token-extra", .{});
                    return error.CliParseError;
                }
            } else if (std.mem.eql(u8, rest, "o") or std.mem.eql(u8, rest, "out")) {
                if (ans.out_file_path.len > 0) {
                    self.aggregator.add(.fatal, "-o/-out already set", .{});
                    return error.CliParseError;
                }
                if (self.iterator.next()) |payload| {
                    ans.out_file_path = try self.allocator.dupe(u8, payload);
                } else {
                    self.aggregator.add(.fatal, "expected parameter following -o/-out", .{});
                    return error.CliParseError;
                }
            } else if (std.mem.eql(u8, rest, "h")) {
                ans.help = true;
            } else if (std.mem.eql(u8, rest, "dump-cfg")) {
                ans.dump_cfg = true;
            } else {
                self.aggregator.add(.fatal, "unrecognized argument -{s}", .{rest});
                return error.CliParseError;
            }
        }
        if (ans.in_file_path.len == 0 and !ans.help) {
            self.aggregator.add(.fatal, "expected input grammar path", .{});
            return error.CliParseError;
        }
        return ans;
    }
};

fn mainInner(init: std.process.Init, gpa: std.mem.Allocator, stderr: *std.Io.Writer) error{ OutOfMemory, ReadFailed, WriteFailed, UserError }!void {
    var cli = blk: {
        var aggregator: pgen.diagnostic.Aggregator = .withLogging(gpa);
        defer aggregator.deinit();
        var cli_parser = try CliParser.init(init, gpa, &aggregator);
        defer cli_parser.deinit();
        break :blk cli_parser.go() catch |err| switch (err) {
            error.CliParseError => {
                try stderr.writeAll("CLI parsing failed; pass -h to see usage\n");
                try aggregator.printDiagnostics(stderr);
                return error.UserError;
            },
            else => |e| return e,
        };
    };
    defer cli.deinit();

    if (cli.help) {
        try stderr.writeAll(CliParser.help_message);
        return;
    }

    // Read in file (grammar description)
    const in_file = std.Io.Dir.cwd().openFile(init.io, cli.in_file_path, .{ .allow_directory = false }) catch |err| {
        try stderr.print("failed to open in file: {s}\n", .{@errorName(err)});
        return error.UserError;
    };
    defer in_file.close(init.io);

    // Invent an out file path if not specified
    if (cli.out_file_path.len == 0) {
        const suffix = ".zig";
        cli.out_file_path = try cli.allocator.alloc(u8, cli.in_file_path.len + suffix.len);
        @memcpy(cli.out_file_path[0..cli.in_file_path.len], cli.in_file_path);
        @memcpy(cli.out_file_path[cli.in_file_path.len..], suffix);
    }

    // Open output file
    const out_file = std.Io.Dir.cwd().createFile(init.io, cli.out_file_path, .{}) catch |err| {
        try stderr.print("failed to open out file: {s}\n", .{@errorName(err)});
        return error.UserError;
    };
    defer out_file.close(init.io);

    // Prepare buffered readers/writers
    const read_buffer = try gpa.alloc(u8, BUFFER_SIZE);
    defer gpa.free(read_buffer);
    var in_file_reader = in_file.reader(init.io, read_buffer);
    const reader = &in_file_reader.interface;
    const write_buffer = try gpa.alloc(u8, BUFFER_SIZE);
    defer gpa.free(write_buffer);
    var out_file_writer = out_file.writer(init.io, write_buffer);
    const writer = &out_file_writer.interface;

    const driver: pgen.driver.Driver = .init(gpa, reader, stderr, writer, .{
        .cst_owns_token = cli.cst_owns_token,
        .token_extra = &.{cli.token_extra},
        .dump_cfg = cli.dump_cfg,
    });
    driver.go() catch |err| return switch (err) {
        error.GrammarError => error.UserError, // Already logged
        else => |e| e,
    };
}

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

    const stderr_file = std.Io.File.stderr();
    const stderr_buffer = gpa.alloc(u8, BUFFER_SIZE) catch {
        stderr_file.writeStreamingAll(init.io, "out of memory!\n") catch {};
        return 1;
    };
    defer gpa.free(stderr_buffer);
    var stderr_writer = stderr_file.writer(init.io, stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    mainInner(init, gpa, stderr) catch |err| {
        switch (err) {
            error.OutOfMemory => stderr.writeAll("out of memory!\n") catch {},
            error.ReadFailed => stderr.writeAll("read input failed!\n") catch {},
            error.WriteFailed => stderr.writeAll("write output/stderr failed!\n") catch {},
            error.UserError => {}, // Already logged
        }
        return 1;
    };
    return 0;
}
