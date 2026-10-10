//! Convert grammar file to token stream, then to CST (done by the meta
//! parser), then to pooled AST.

const std = @import("std");
const psr = @import("pgen_meta_parser");

pub const Tokenizer = struct {
    reader: *std.Io.Reader,
    payload_allocator: std.mem.Allocator,
    scrap_allocator: std.mem.Allocator,
    // Internal
    current_loc: psr.Token.Loc = .{ .ln = 0, .col = 0 },

    pub const Error = std.Io.Reader.Error || std.mem.Allocator.Error || error{InvalidSyntax};

    /// Keep reading characters into `al` until a character that cannot be a
    /// continue character in an identifier appears. Allocates with
    /// `self.payload_allocator`. Does not modify `self.current_loc`.
    fn readIdContinue(self: *@This(), al: *std.ArrayListUnmanaged(u8)) (std.mem.Allocator.Error || error{ReadFailed})!void {
        while (true) {
            const ch = self.reader.peekByte() catch |err| switch (err) {
                error.ReadFailed => |e| return e,
                error.EndOfStream => break,
            };
            if (std.ascii.isAlphanumeric(ch) || ch == '_') {
                self.reader.toss(1);
                try al.append(self.payload_allocator, ch);
            } else {
                break;
            }
        }
    }

    /// Whether `ch` can be first character of an identifier.
    fn isIdStart(ch: u8) bool {
        return std.ascii.isAlphabetic(ch) || ch == '_';
    }

    /// Read quoted string assuming the starting '"' is already consumed.
    /// Does not modify `self.current_loc`. Return the string content (escapes
    /// processed) and number of bytes consumed. The ending '"' is consumed.
    fn readQuotedStr(self: *@This()) Error!struct { usize, []const u8 } {
        var allocating_writer: std.Io.Writer.Allocating = .init(self.scrap_allocator);
        defer allocating_writer.deinit();
        const writer = &allocating_writer.writer;
        var string: std.ArrayListUnmanaged(u8) = .empty;
        errdefer string.deinit(self.payload_allocator);
        var has_more = true;
        var bytes_consumed: usize = 0;
        while (has_more) {
            bytes_consumed += self.reader.streamDelimiter(writer, '"') catch |err| switch (err) {
                error.WriteFailed => return error.OutOfMemory,
                error.ReadFailed => |e| return e,
                error.EndOfStream => return error.InvalidSyntax, // Unclosed '"' (EOF)
            };
            bytes_consumed += 1;
            self.reader.toss(1); // Skip '"'
            const buf = allocating_writer.written();
            var i: usize = 0;
            try string.ensureUnusedCapacity(self.payload_allocator, buf.len); // Speculative allocation
            // Invariant: we've allocated enough memory. The literal is
            // always longer than the string value it describes.
            has_more = false;
            while (i < buf.len) {
                switch (buf[i]) {
                    '\\' => {
                        i += 1;
                        if (i == buf.len) {
                            has_more = true;
                            string.appendAssumeCapacity('"');
                            break;
                        }
                        switch (buf[i]) {
                            '\\' => {
                                string.appendAssumeCapacity('\\');
                                i += 1;
                            },
                            '"' => unreachable,
                            else => return error.InvalidSyntax, // Unrecognized escape
                        }
                    },
                    '"' => unreachable,
                    '\n' => return error.InvalidSyntax, // Unclosed '"' (newline)
                    else => string.appendAssumeCapacity(buf[i]),
                }
            }
            allocating_writer.clearRetainingCapacity();
        }
        return .{ bytes_consumed, string.toOwnedSlice(self.payload_allocator) };
    }

    /// Get the next token. Newly created token must be deinited with
    /// `self.payload_allocator`.
    pub fn nextToken(self: *@This()) Error!psr.Token {
        while (true) {
            const first = try self.reader.takeByte();
            if (isIdStart(first)) {
                var identifier: std.ArrayListUnmanaged(u8) = .empty;
                errdefer identifier.deinit(self.payload_allocator);
                try identifier.append(self.payload_allocator, first);
                try self.readIdContinue(&identifier);
                const bytes_consumed = identifier.items.len;
                // Newline character cannot appear in an identifier
                defer self.current_loc.col += bytes_consumed;
                if (psr.Token.literal_map.k.get(identifier.items)) |tag| {
                    identifier.deinit(self.payload_allocator);
                    return .{ .tag = tag, .payload = .{ .none = void{} }, .loc = self.current_loc };
                } else {
                    const payload = try identifier.toOwnedSlice(self.payload_allocator);
                    return .{ .tag = .named.WORD, .payload = .{ .word = payload }, .loc = self.current_loc };
                }
            } else if (first == '"') {
                var bytes_consumed, const content = try self.readQuotedStr();
                bytes_consumed += 1; // Starting '"'
                // Suffix
                var suffix: []const u8 = &.{};
                if (self.reader.peekByte()) |after_quote| {
                    if (isIdStart(after_quote)) {
                        self.reader.toss(1);
                        var al: std.ArrayListUnmanaged(u8) = .empty;
                        errdefer al.deinit(self.payload_allocator);
                        try al.append(self.payload_allocator, after_quote);
                        try self.readIdContinue(&al);
                        suffix = try al.toOwnedSlice(self.payload_allocator);
                        bytes_consumed += suffix.len;
                    }
                } else |err| switch (err) {
                    error.ReadFailed => |e| return e,
                    error.EndOfStream => {},
                }
                // Newline character cannot appear in a string literal
                defer self.current_loc.col += bytes_consumed;
                return .{ .tag = .named.STRING, .payload = .{ .str = .{ .content = content, .suffix = suffix } }, .loc = self.current_loc };
            } else if (first == '#') {
                _ = self.reader.discardDelimiterInclusive('\n') catch |err| switch (err) {
                    error.ReadFailed => |e| return e,
                    error.EndOfStream => {},
                };
                self.current_loc.ln += 1;
                self.current_loc.col = 0;
            } else if (std.ascii.isWhitespace(first)) {
                if (first == '\n') {
                    self.current_loc.ln += 1;
                    self.current_loc.col = 0;
                }
            } else if (psr.Token.literal_map.@".".get((&first)[0..1])) |tag| {
                defer self.current_loc.col += 1;
                return .{ .tag = tag, .payload = .{ .none = void{} }, .loc = self.current_loc };
            } else {
                return error.InvalidSyntax; // Invalid character
            }
        }
    }
};
