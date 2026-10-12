//! Manages diagnostics issued on the input grammar.
const std = @import("std");

pub const Level = enum {
    fatal,
    warning,
};

/// A single diagnostic, representing a detected problem or warning.
pub const Diagnostic = struct {
    level: Level,
    /// Owned, human-readable message.
    message: []const u8,
};

/// Aggregates diagnostics. Passed as a parameter to processors such as
/// the tokenizer.
pub const Aggregator = struct {
    /// Used to allocate messages. If you don't want diagnostics stored at all,
    /// pass null.
    allocator: ?std.mem.Allocator,
    /// List of owned diagnostics, if `allocator` is non-null.
    diagnostics: std.MultiArrayList(Diagnostic) = .empty,
    /// Got any fatal diagnostic? This works regardless of `allocator`.
    fatal: bool = false,
    /// Out-of-memory occurred during generation of error messages?
    oom: bool = false,

    /// An aggregator that does not store messages
    pub const no_logging: @This() = .{
        .allocator = null,
    };

    pub fn withLogging(allocator: std.mem.Allocator) @This() {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *@This()) void {
        if (self.allocator) |allocator| {
            for (self.diagnostics.items(.message)) |message|
                allocator.free(message);
            self.diagnostics.deinit(allocator);
        }
        self.* = undefined;
    }

    pub fn dumpDiagnostics(self: *@This()) std.MultiArrayList(Diagnostic) {
        defer self.diagnostics = .empty;
        return self.diagnostics;
    }

    pub fn add(self: *@This(), level: Level, comptime fmt: []const u8, args: anytype) void {
        if (level == .fatal)
            self.fatal = true;
        if (self.allocator) |allocator| {
            const message = std.fmt.allocPrint(allocator, fmt, args) catch {
                self.oom = true;
                return;
            };
            self.diagnostics.append(allocator, .{
                .level = level,
                .message = message,
            }) catch {
                allocator.free(message);
                self.oom = true;
            };
        }
    }

    /// Print all the diagnostics in human-readable form.
    pub fn printDiagnostics(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.diagnostics.items(.level), self.diagnostics.items(.message)) |level, message| {
            try writer.writeAll(@tagName(level));
            try writer.writeAll(": ");
            try writer.writeAll(message);
            try writer.writeByte('\n');
        }
        if (self.oom) {
            try writer.writeAll("some logs were omitted due to out-of-memory!");
        }
    }
};
