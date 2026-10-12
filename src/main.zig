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
    const read_buffer = gpa.alloc(u8, BUFFER_SIZE) catch {
        logger.writeLine("OOM (read buffer)");
        return 1;
    };
    defer gpa.free(read_buffer);
    var in_file_reader = in_file.reader(init.io, read_buffer);
    const reader = &in_file_reader.interface;

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
    return 0;
}
