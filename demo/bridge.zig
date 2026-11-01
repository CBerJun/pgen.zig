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

    pub fn signalWriteFailed(self: *@This()) void {
        // The reason an allocating writer fails is because OOM.
        self.oom = true;
    }

    pub fn addError(self: *@This(), comptime fmt: []const u8, args: anytype) void {
        self.failed = true;
        if (self.oom)
            return;
        self.writer().print(fmt, args) catch {
            // The reason an allocating writer fails is OOM
            self.signalWriteFailed();
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

/// Returned buffer (`out_error`, `out_result`) must be deinited with
/// `releaseMessage`.
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

    var report: ErrorReport = .init();
    defer {
        out_error.* = report.getResult();
        report.deinit();
    }

    var result_alloc_writer: std.Io.Writer.Allocating = .init(gpa);
    defer result_alloc_writer.deinit();
    const writer = &result_alloc_writer.writer;

    var driver: pgen.driver.Driver = .init(gpa, reader, report.writer(), writer, .{
        .cst_owns_token = cst_owns_token,
    });
    driver.go() catch |err| {
        switch (err) {
            error.GrammarError => report.failed = true, // Already logged
            error.OutOfMemory => report.addError("out of memory!\n", .{}),
            error.ReadFailed => unreachable, // Fixed reader should not fail
            error.WriteFailed => report.signalWriteFailed(),
        }
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
