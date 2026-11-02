const std = @import("std");
const pgen = @import("pgen");

const gpa = std.heap.wasm_allocator;
const oom_message = "out of memory for stderr\n";

/// Returned buffer (`out_error`, `out_result`) must be deinited with
/// `releaseMessage`.
export fn pgenRun(
    src_ptr: [*]const u8,
    src_len: usize,
    out_error: *[]const u8,
    out_result: *[]const u8,
    // Config options
    algorithm: u8,
    cst_owns_token: bool,
) void {
    const src: []const u8 = src_ptr[0..src_len];
    var fixed_reader: std.Io.Reader = .fixed(src);
    const reader = &fixed_reader;

    out_result.* = &.{};

    var stderr_alloc_writer: std.Io.Writer.Allocating = .init(gpa);
    const stderr = &stderr_alloc_writer.writer;
    defer {
        out_error.* = stderr_alloc_writer.toOwnedSlice() catch oom_message;
        stderr_alloc_writer.deinit();
    }

    var result_alloc_writer: std.Io.Writer.Allocating = .init(gpa);
    defer result_alloc_writer.deinit();
    const writer = &result_alloc_writer.writer;

    var driver: pgen.driver.Driver = .init(gpa, reader, stderr, writer, .{
        .algorithm = switch (algorithm) {
            // Keep this table in sync with pgen-demo.js!
            0 => .slr,
            1 => .lr0,
            else => unreachable,
        },
        .cst_owns_token = cst_owns_token,
    });
    driver.go() catch |err| {
        switch (err) {
            error.GrammarError => {}, // Already logged
            // `WriteFailed` on `std.Io.Writer.Allocating` is due to OOM.
            error.OutOfMemory, error.WriteFailed => stderr.writeAll("out of memory!\n") catch {},
            error.ReadFailed => unreachable, // Fixed reader should not fail
        }
        return;
    };

    out_result.* = result_alloc_writer.toOwnedSlice() catch {
        stderr.writeAll("out of memory!\n") catch {};
        return;
    };
}

export fn releaseMessage(buf: *const []const u8) void {
    if (buf.ptr == oom_message) {
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
