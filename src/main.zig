const std = @import("std");
const builtin = @import("builtin");
const pgen = @import("pgen");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

const BUFFER_SIZE = 4096;

pub fn main(init: std.process.Init) void {
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

    // Read the in file (grammar description)
    var arg_it = init.minimal.args.iterateAllocator(gpa) catch fatal("OOM (argv)", .{});
    defer arg_it.deinit();
    if (!arg_it.skip()) {
        fatal("expected argv[0] to exist", .{});
    }
    const in_file_path = arg_it.next() orelse fatal("expected input grammar path", .{});
    const in_file = std.Io.Dir.cwd().openFile(init.io, in_file_path, .{ .allow_directory = false }) catch |err| {
        fatal("failed to open in file: {s}", .{@errorName(err)});
    };
    const read_buffer = gpa.alloc(u8, BUFFER_SIZE) catch fatal("OOM (read buffer)", .{});
    defer gpa.free(read_buffer);
    var in_file_reader = in_file.reader(init.io, read_buffer);
    const reader = &in_file_reader.interface;

    // Tokenize and parse it
    var tokenizer: pgen.Tokenizer = .{
        .reader = reader,
        .payload_allocator = gpa,
        .scrap_allocator = gpa,
    };
    var parser = pgen.psr.Parser.init(gpa) catch |err| switch (err) {
        error.OutOfMemory => fatal("OOM (parser init)", .{}),
    };
    defer parser.deinit(gpa);
    while (tokenizer.nextToken() catch |err| switch (err) {
        // TODO: diagnostic
        error.InvalidSyntax => fatal("tokenize failed", .{}),
        error.OutOfMemory => fatal("OOM (in file tokenization)", .{}),
        error.ReadFailed => fatal("in file read failed", .{}),
    }) |token| {
        std.debug.print("{any}\n", .{token});
        parser.feed(gpa, token) catch |err| switch (err) {
            error.OutOfMemory => fatal("OOM (in file parsing)", .{}),
            // TODO: diagnostic
            error.PgenParseError => fatal("parse failed", .{}),
        };
    }
    var cst = parser.retrieve();
    defer cst.deinit(gpa);
    var ast = pgen.cst2ast.EbnfManaged.fromCst(cst, gpa, gpa) catch |err| switch (err) {
        error.OutOfMemory => fatal("OOM (CST to AST)", .{}),
        else => |e| fatal("CST to AST failed: {s}", .{@errorName(e)}),
    };
    defer ast.deinit();
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.debug.print("\n", .{});
    std.process.exit(1);
}
