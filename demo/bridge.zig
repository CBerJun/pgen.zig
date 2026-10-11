const std = @import("std");
const pgen = @import("pgen");

const gpa = std.heap.wasm_allocator;

const oom_instance = "Out of memory";
const ok_instance = "OK (no error)";

fn oom() []const u8 {
    return oom_instance;
}
fn ok() []const u8 {
    return ok_instance;
}

// Returned buffer must be deinited with `pgenReleaseMessage`.
export fn pgenParse(src_ptr: [*]const u8, src_len: usize, out_ptr: *[]const u8) void {
    const src: []const u8 = src_ptr[0..src_len];
    var out: []const u8 = undefined;
    defer out_ptr.* = out;
    var fixed_reader: std.Io.Reader = .fixed(src);
    const reader = &fixed_reader;

    var tokenizer: pgen.Tokenizer = .{
        .reader = reader,
        .payload_allocator = gpa,
        .scrap_allocator = gpa,
    };
    var parser = pgen.psr.Parser.init(gpa) catch |err| switch (err) {
        error.OutOfMemory => {
            out = oom();
            return;
        },
    };
    defer parser.deinit(gpa);
    while (tokenizer.nextToken() catch |err| switch (err) {
        error.InvalidSyntax => {
            const loc = tokenizer.current_loc;
            out = std.fmt.allocPrint(gpa, "tokenize failed near line {}, column {}", .{
                // 0-indexed to 1-indexed
                loc.ln + 1, loc.col + 1,
            }) catch oom();
            return;
        },
        error.OutOfMemory => {
            out = oom();
            return;
        },
        error.ReadFailed => unreachable,
    }) |token| {
        parser.feed(gpa, token) catch |err| switch (err) {
            error.OutOfMemory => {
                out = oom();
                return;
            },
            error.PgenParseError => {
                const loc = tokenizer.current_loc;
                out = std.fmt.allocPrint(gpa, "parse failed near line {}, column {}", .{
                    // 0-indexed to 1-indexed
                    loc.ln + 1, loc.col + 1,
                }) catch oom();
                return;
            },
        };
    }
    var cst = parser.retrieve();
    defer cst.deinit(gpa);
    var ast = pgen.cst2ast.EbnfManaged.fromCst(cst, gpa, gpa) catch |err| switch (err) {
        error.OutOfMemory => {
            out = oom();
            return;
        },
        else => |e| {
            out = std.fmt.allocPrint(gpa, "CST to AST failed: {s}", .{@errorName(e)}) catch oom();
            return;
        },
    };
    defer ast.deinit();
    out = ok();
}

export fn releaseMessage(buf: *const []const u8) void {
    if (buf.ptr == oom_instance or buf.ptr == ok_instance) {
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
    return @constCast(oom_instance[0..].ptr);
}
