//! Backends generate runnable parsers from parse table.
//! The parse table is never explicitly provided to the backend however.
//! See `lr0` for example.
//!
//! The two main tables used in LR parser generation are ACTION and GOTO,
//! so certain backends accept generic "action handler" and "goto handler"
//! that handles the corresponding table.

const std = @import("std");
const lr0 = @import("./lr0.zig");
const cfg = @import("./cfg.zig");
const sym = @import("./sym.zig");

/// Generic error for indicating a cause of LR parse table conflict
const ConflictError = error{
    /// An *unresolved* LR conflict.
    LrConflict,
};

/// Format a possibly empty grammar identifier (turned into @".") as a Zig
/// identifier
fn identifierToZig(str: []const u8, out: *std.Io.Writer) std.Io.Writer.Error!void {
    if (str.len == 0) {
        try out.writeAll("@\".\"");
    } else if (std.zig.Token.keywords.has(str)) {
        try out.print("@\"{s}\"", .{str});
    } else {
        try out.writeAll(str);
    }
}

/// Format any nonempty ASCII string as a Zig identifier.
fn stringToZigIdentifier(str: []const u8, out: *std.Io.Writer) std.Io.Writer.Error!void {
    if (blk: {
        if (!std.ascii.isAlphabetic(str[0]) and str[0] != '_')
            break :blk true;
        for (str[1..]) |char|
            if (!std.ascii.isAlphanumeric(char) and char != '_')
                break :blk true;
        break :blk false;
    }) {
        // Need @""
        try out.writeAll("@\"");
        try std.zig.stringEscape(str, out);
        try out.writeByte('"');
    } else {
        try out.writeAll(str);
    }
}

/// Struct responsible for emitting the final Zig source code.
/// Includes skeleton code shared by all LR style parsers.
///
/// A user (backend) must implement `Parser.gotoTable` and `Parser.action`
/// (the two table lookup methods), and the engine code (LR runtime) and data
/// model (token, CST nodes, integer types representing states etc.) are
/// supplied by this class.
pub const ZigEmitter = struct {
    out: *std.Io.Writer,
    /// Extra fields/methods in `Token` struct. Can be used to add extra info
    /// to tokens like source location or string literal contents. A list of
    /// lines to add to the `Token` struct (no need to add trailing `"\n"`).
    token_extra: []const []const u8 = &.{},
    /// A leaf `CSTNode`'s `deinit` will call `token.deinit(allocator)` if this
    /// is true. You can supply the `pub fn deinit()` through `token_extra`.
    cst_owns_token: bool = false,
    /// Bits of unsigned int type for holding number of children in a CST node.
    /// Should not be wider than target machine's usize. If 0, then usize is
    /// used.
    node_count_bits: u16 = 0,
    /// Indentation preference (Zig recommends 4 spaces)
    /// TODO: expose this to end user?
    indent_string: []const u8 = "    ",

    // --- Utility writer routines
    /// Current indent level
    indent_count: u8 = 0,

    /// Can only support 255 levels of indentation. Max indent level is supposed
    /// to be develop-time known.
    pub fn indent(self: *@This()) void {
        self.indent_count += 1;
    }
    pub fn dedent(self: *@This()) void {
        std.debug.assert(self.indent_count > 0);
        self.indent_count -= 1;
    }
    pub fn writeNIndent(self: @This(), n: u8) std.Io.Writer.Error!void {
        for (0..n) |_|
            try self.out.writeAll(self.indent_string);
    }
    pub fn writeIndent(self: @This()) std.Io.Writer.Error!void {
        try self.writeNIndent(self.indent_count);
    }
    pub fn writeNewline(self: @This()) std.Io.Writer.Error!void {
        try self.out.writeByte('\n');
    }
    pub fn writeLine(self: @This(), line: []const u8) std.Io.Writer.Error!void {
        if (line.len > 0) {
            try self.writeIndent();
            try self.out.writeAll(line);
        }
        try self.writeNewline();
    }
    pub fn printLine(self: @This(), comptime fmt: []const u8, args: anytype) std.Io.Writer.Error!void {
        try self.writeIndent();
        try self.out.print(fmt, args);
        try self.writeNewline();
    }
    /// `lines` is split by '\n', with prefixing "    " in each line replaced by
    /// the user's preferred indent string. A '\n' is added after the final line,
    /// so no trailing '\n' is needed in `lines` normally.
    pub fn writeLines(self: @This(), comptime lines: []const u8) std.Io.Writer.Error!void {
        const Line = struct {
            str: []const u8,
            /// Prefixing whitespace count
            ws: u8,
            const empty: @This() = .{ .str = "", .ws = 0 };
        };
        // Slice element must be immutable at comptime (without e.g. a backing array)
        comptime var translated: []const Line = &.{};
        translated = translated ++ &[_]Line{.empty};
        comptime var finished_indent = false;
        // To allow Zig to handle very long `lines`:
        @setEvalBranchQuota(@intCast(lines.len));
        inline for (lines) |char| {
            comptime var current_line = translated[translated.len - 1];
            if (!finished_indent and char == ' ') {
                current_line.ws += 1;
                translated = translated[0 .. translated.len - 1] ++ &[_]Line{current_line};
            } else if (char == '\n') {
                translated = translated ++ &[_]Line{.empty};
                finished_indent = false;
            } else {
                current_line.str = current_line.str ++ &[_]u8{char};
                finished_indent = true;
                translated = translated[0 .. translated.len - 1] ++ &[_]Line{current_line};
            }
        }
        for (translated) |line| {
            if (line.str.len > 0) {
                try self.writeNIndent(@divExact(line.ws, 4)); // prefixing space must come in multiple of 4
                try self.writeLine(line.str);
            } else {
                try self.writeNewline();
            }
        }
    }

    // --- Business logic

    // Token.Tag representation
    // We want user to be able to use ".xxx" when Zig can infer that the
    // expression is of `Token.Tag` type.
    // Rejected ideas:
    // - .named.name1, .literal.suffix.name2: Zig does not support attribute
    //   access on enum literal.
    // - .named(.name1), .literal_suffix(.name2): Zig does not support calling
    //   enum literal in switch prong.
    // In the end, we choose to use a normal Zig enum with special names
    // assigned to each token.
    // - Named tokens use their name in grammar source
    // - Literal tokens use the name suffix.content
    // - EOI uses @"$"

    pub fn writeProlog(self: *@This(), symbol_spec: *const sym.SymbolSpec, productions: *const cfg.CfgProductions) std.Io.Writer.Error!void {
        // Definitions
        try self.writeLines(
            \\//! Do not edit - auto generated by pgen Zig library
            \\const std = @import("std");
            \\
            \\pub const Token = struct {
        );
        self.indent(); // struct Token
        try self.writeLine("tag: Tag,");
        for (self.token_extra) |line| {
            try self.writeLine(line);
        }
        try self.writeNewline();

        try self.writeLines(
            \\pub fn assertTag(self: @This(), tag: Tag) void {
            \\    std.debug.assert(self.tag == tag);
            \\}
        );
        try self.printLine("const TagSize = u{};", .{self.tagBackingIntBits(symbol_spec)});
        try self.writeLine("pub const Tag = enum(TagSize) {");
        self.indent(); // enum Tag
        for (symbol_spec.terminals.literal) |collection| {
            for (collection.literals) |content| {
                try self.writeIndent();
                try self.out.print("@\"{s}.", .{collection.suffix});
                try std.zig.stringEscape(content, self.out);
                try self.out.writeAll("\",\n");
            }
        }
        for (symbol_spec.terminals.named) |name| {
            try self.writeIndent();
            try identifierToZig(name, self.out);
            try self.out.writeAll(",\n");
        }
        try self.writeLine("@\"$\",");
        self.dedent(); // end enum Tag
        try self.writeLine("};");
        try self.writeNewline();

        try self.writeLine("pub const literal_map = struct {");
        self.indent(); // struct literal_map
        var terminal_id: u32 = 0;
        for (symbol_spec.terminals.literal) |collection| {
            try self.writeIndent();
            try self.out.writeAll("pub const ");
            try identifierToZig(collection.suffix, self.out);
            try self.out.writeAll(" = std.StaticStringMap(Tag).initComptime(.{\n");
            self.indent(); // StaticStringMap(Tag).initComptime
            for (collection.literals) |literal| {
                try self.writeIndent();
                try self.out.writeAll(".{ \"");
                try std.zig.stringEscape(literal, self.out);
                try self.out.print("\", @as(Tag, @enumFromInt({})) }},\n", .{terminal_id});
                terminal_id += 1;
            }
            self.dedent(); // end StaticStringMap(Tag).initComptime
            try self.writeLine("});");
        }
        self.dedent(); // end struct literal_map
        try self.writeLine("};");
        self.dedent(); // end struct Token
        try self.writeLine("};");
        try self.writeNewline();

        // There is at least 1 node forming nt: the entry
        try self.printLine(
            "pub const Nonterminal = enum(u{}) {{",
            .{std.math.log2_int_ceil(u32, symbol_spec.nonterminals.node_forming_count)},
        );
        self.indent(); // enum Nonterminal
        for (symbol_spec.nonterminals.names[0..symbol_spec.nonterminals.node_forming_count]) |name| {
            try self.writeIndent();
            try identifierToZig(name, self.out);
            try self.out.writeAll(",\n");
        }
        self.dedent(); // end enum Nonterminal
        try self.writeLine("};");
        try self.writeNewline();

        try self.writeLines(
            \\pub const NonterminalExpansion = struct {
            \\    nonterminal: Nonterminal,
            \\    children: []CstNode,
            \\
            \\    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            \\        defer self.* = undefined;
            \\        for (self.children) |*node| node.deinit(allocator);
            \\        allocator.free(self.children);
            \\    }
            \\
            \\    pub fn iterator(self: @This()) NtChildrenIterator {
            \\        const slice = self.children;
            \\        return .{ .at = slice.ptr, .end = slice.ptr + slice.len };
            \\    }
            \\
            \\    pub fn iteratorOf(self: @This(), nt: Nonterminal) NtChildrenIterator {
            \\        std.debug.assert(self.nonterminal == nt);
            \\        return self.iterator();
            \\    }
            \\};
        );
        try self.writeNewline();

        try self.writeLine("pub const CstNode = union(enum) {");
        self.indent(); // union CstNode
        try self.writeLines(
            \\leaf: Token,
            \\internal: NonterminalExpansion,
            \\
            \\/// Recursively deinit this subtree.
        );
        if (self.cst_owns_token) {
            try self.writeLine("/// Tokens owned by the subtree are also deinited.");
        }
        try self.writeLine("pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {");
        self.indent(); // fn deinit
        try self.writeLines(
            \\defer self.* = undefined;
            \\switch (self.*) {
        );
        self.indent(); // switch
        try self.writeLine(".internal => |*expansion| expansion.deinit(allocator),");

        try self.writeIndent();
        try self.out.writeAll(".leaf => ");
        if (self.cst_owns_token) {
            try self.out.writeAll("|*token| token.deinit(allocator)");
        } else {
            try self.out.writeAll("{}");
        }
        try self.out.writeAll(",\n");

        self.dedent(); // end switch
        try self.writeLine("}");
        self.dedent(); // end fn deinit
        try self.writeLine("}");
        try self.writeNewline();

        try self.writeLines(
            \\pub fn isToken(self: @This(), tag: Token.Tag) bool {
            \\    return self == .leaf and self.leaf.tag == tag;
            \\}
            \\
            \\pub fn isNt(self: @This(), nt: Nonterminal) bool {
            \\    return self == .internal and self.internal.nonterminal == nt;
            \\}
        );
        self.dedent(); // end union CstNode
        try self.writeLine("};");
        try self.writeNewline();
        try self.writeLines(
            \\pub const NtChildrenIterator = struct {
            \\    at: [*]CstNode,
            \\    end: [*]CstNode,
            \\
            \\    pub fn eatToken(self: *@This()) *Token {
            \\        return &self.eat().leaf;
            \\    }
            \\
            \\    pub fn eatNt(self: *@This()) *NonterminalExpansion {
            \\        return &self.eat().internal;
            \\    }
            \\
            \\    pub fn eat(self: *@This()) *CstNode {
            \\        return self.next().?;
            \\    }
            \\
            \\    pub fn next(self: *@This()) ?*CstNode {
            \\        if (self.done())
            \\            return null;
            \\        defer self.at += 1;
            \\        return &self.at[0];
            \\    }
            \\
            \\    pub fn peek(self: @This()) ?*CstNode {
            \\        return if (self.done()) null else &self.at[0];
            \\    }
            \\
            \\    pub fn toss(self: *@This()) void {
            \\        std.debug.assert(!self.done());
            \\        self.at += 1;
            \\    }
            \\
            \\    pub fn done(self: @This()) bool {
            \\        return self.at == self.end;
            \\    }
            \\
            \\    pub const State = [*]CstNode;
            \\    pub fn saveState(self: @This()) State {
            \\        return self.at;
            \\    }
            \\    pub fn loadState(self: *@This(), state: State) void {
            \\        self.at = state;
            \\    }
            \\};
            \\
        );
        // Parser skeleton
        try self.writeLine("pub const Parser = struct {");
        self.indent(); // struct Parser
        try self.writeLines(
            \\state_stack: std.ArrayList(StateSize),
            \\node_count_stack: std.ArrayList(NodeCountSize),
            \\node_stack: std.ArrayList(CstNode),
            \\
            \\pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
            \\    var x = @This() {.state_stack = .empty, .node_count_stack = .empty, .node_stack = .empty};
            \\    try x.state_stack.append(allocator, 0);
            \\    return x;
            \\}
            \\
            \\pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            \\    defer self.* = undefined;
            \\    self.state_stack.deinit(allocator);
            \\    self.node_count_stack.deinit(allocator);
            \\    // May have partial results on error
            \\    for (self.node_stack.items) |*node| node.deinit(allocator);
            \\    self.node_stack.deinit(allocator);
            \\}
            \\
            \\pub const Error = error{PgenParseError};
            \\
            \\/// Call after sending the last token (which must be EOI) to get the parse tree.
            \\/// Caller owns the result.
            \\pub fn retrieve(self: *@This()) CstNode {
            \\    return self.node_stack.pop().?;
            \\}
            \\
            \\fn shift(self: *@This(), allocator: std.mem.Allocator, token: Token, new_state: StateSize) std.mem.Allocator.Error!void {
            \\    // This must atomic so that on error we don't keep `token`'s ownership.
            \\    try self.state_stack.append(allocator, new_state);
            \\    errdefer _ = self.state_stack.pop();
            \\    try self.node_stack.append(allocator, .{.leaf = token});
            \\    errdefer _ = self.node_stack.pop();
            \\    try self.node_count_stack.append(allocator, 1);
            \\}
            \\
            \\fn reduce(self: *@This(), allocator: std.mem.Allocator, rhs_len: RhsLenSize, lhs: NtSize) std.mem.Allocator.Error!void {
            \\    const form_node = isNodeForming(lhs);
            \\    const hi = self.node_count_stack.items.len;
            \\    const lo = hi - rhs_len;
            \\    var x: NodeCountSize = 0;
            \\    for (lo..hi) |i| {
            \\        x += self.node_count_stack.items[i];
            \\    }
            \\    try self.node_count_stack.resize(allocator, lo);
            \\    try self.node_count_stack.append(allocator, if (form_node) 1 else x);
            \\    if (form_node) {
            \\        const node_lo = self.node_stack.items.len - x;
            \\        const children = try allocator.dupe(CstNode, self.node_stack.items[node_lo..]);
            \\        errdefer allocator.free(children);
            \\        try self.node_stack.resize(allocator, node_lo);
            \\        try self.node_stack.append(allocator, .{.internal = .{
            \\            .nonterminal = @enumFromInt(lhs),
            \\            .children = children,
            \\        }});
            \\    }
            \\    try self.state_stack.resize(allocator, self.state_stack.items.len - rhs_len);
            \\    try self.goto(allocator, lhs);
            \\}
            \\
            \\const Action = union(enum) {
            \\    shift: StateSize,
            \\    reduce: struct {
            \\        rhs_len: RhsLenSize,
            \\        lhs: NtSize,
            \\    },
            \\    accept,
            \\    reject,
            \\};
            \\
        );
        try self.printLine("const NtSize = u{};", .{self.ntBits(symbol_spec)});
        {
            var max_len: u32 = 0;
            for (productions.rhs[0..productions.count]) |rhs| {
                max_len = @max(max_len, @as(u32, @intCast(rhs.len)));
            }
            // Note the +1:
            const rhs_len_size = if (max_len == 0) 0 else std.math.log2_int_ceil(u32, max_len + 1);
            try self.printLine("const RhsLenSize = u{};", .{rhs_len_size});
        }
        try self.writeNewline();

        try self.writeLine("/// Feed a token to the parser.");
        if (self.cst_owns_token) {
            try self.writeLines(
                \\/// `token`'s ownership is transferred to the temporary CST nodes owned
                \\/// by this parser, unless an error occurs, *or* it's the terminating
                \\/// token (of tag `.@"$"`) (which does not end up in the CST at all).
            );
        }
        try self.writeLines(
            \\pub fn feed(self: *@This(), allocator: std.mem.Allocator, token: Token) (Error || std.mem.Allocator.Error)!void {
            \\    const T = @intFromEnum(token.tag);
            \\    while (true) {
            \\        const state = self.state_stack.getLast();
            \\        switch (action(state, T)) {
            \\            .shift => |new_state| return self.shift(allocator, token, new_state),
            \\            .reduce => |r| try self.reduce(allocator, r.rhs_len, r.lhs),
            \\            .reject => return error.PgenParseError,
            \\            .accept => return,
            \\        }
            \\    }
            \\}
            \\
            \\fn goto(self: *@This(), allocator: std.mem.Allocator, nt: NtSize) std.mem.Allocator.Error!void {
            \\    const state = self.state_stack.getLast();
            \\    try self.state_stack.append(allocator, gotoTable(state, nt));
            \\}
            \\
        );
        try self.writeLine("fn isNodeForming(nt: NtSize) bool {");
        self.indent(); // fn isNodeForming
        try self.printLine("return nt < {};", .{symbol_spec.nonterminals.node_forming_count});
        self.dedent(); // end fn isNodeForming
        try self.writeLine("}");
        // We are still inside struct Parser.
    }

    pub fn tagBackingIntBits(_: @This(), symbol_spec: *const sym.SymbolSpec) u16 {
        // There is at least 1 terminal: the end-of-input
        return std.math.log2_int_ceil(u32, symbol_spec.terminals.count);
    }

    pub fn ntBits(_: @This(), symbol_spec: *const sym.SymbolSpec) u16 {
        // There is at least 1 nonterminal: the entry
        return std.math.log2_int_ceil(u32, symbol_spec.nonterminals.count);
    }

    pub fn stateBits(_: @This(), num_states: u32) std.math.Log2IntCeil(u32) {
        // There is at least 1 state: the starting state 0.
        return std.math.log2_int_ceil(u32, num_states);
    }

    pub fn writeReduceAction(self: @This(), productions: *const cfg.CfgProductions, prod_id: u32) std.Io.Writer.Error!void {
        try self.out.print(".{{.reduce = .{{.rhs_len = {}, .lhs = {}}}}}", .{
            productions.rhs[prod_id].len,
            productions.lhs[prod_id],
        });
    }

    pub fn writeShiftAction(self: @This(), new_state: u32) std.Io.Writer.Error!void {
        try self.out.print(".{{.shift = {}}}", .{new_state});
    }

    /// Writes information that can only be written *after* the table gen process
    /// is done.
    pub fn writeEpilog(self: *@This(), num_states: u32) std.Io.Writer.Error!void {
        try self.writeNewline();
        try self.printLine("const StateSize = u{};", .{self.stateBits(num_states)});
        if (self.node_count_bits > 0) {
            try self.printLine("const NodeCountSize = u{};", .{self.node_count_bits});
            try self.writeLines(
                \\comptime {
                \\    if (@typeInfo(NodeCountSize).int.bits > @typeInfo(usize).int.bits)
                \\        @compileError("node_count_bits is wider than usize");
                \\}
            );
        } else {
            try self.writeLine("const NodeCountSize = usize;");
        }
        self.dedent(); // end struct Parser
        try self.writeLine("};");
    }

    pub fn implementGotoTable(self: *@This()) std.Io.Writer.Error!void {
        try self.writeNewline();
        try self.writeLine("fn gotoTable(state: StateSize, nt: NtSize) StateSize {");
        self.indent();
    }

    pub fn implementAction(self: *@This()) std.Io.Writer.Error!void {
        try self.writeNewline();
        try self.writeLine("fn action(state: StateSize, lookahead: Token.TagSize) Action {");
        self.indent();
    }

    pub fn endMethod(self: *@This()) std.Io.Writer.Error!void {
        self.dedent();
        try self.writeLine("}");
    }
};

/// A row in a LR(0) ACTION table (what to do in a state). No support for
/// conflict resolution (use hash map from terminal to `SlrAction` instead).
const Lr0ActionRow = union(enum) {
    /// Always reject
    reject,
    /// Always reduce using this production
    reduce: u32,
    /// Shift/Accept based on (indexed by) upcoming terminal, or reject.
    shift: std.ArrayList(struct {
        /// Terminal needed to see
        terminal: u32,
        /// New state to transition to, or undefined if `terminal` is End of
        /// Input (accepting)
        new_state: u32,
    }),

    pub fn free(self: *@This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .shift => |*x| {
                x.deinit(allocator);
            },
            else => {},
        }
    }
};

/// Handle GOTO using switch statements nested in a switch statement.
pub const SwitchGotoHandler = struct {
    /// GOTO[state][nonterminal]
    goto_table: std.ArrayList(std.ArrayList(Entry)) = .empty,
    num_states: u32 = 0,

    /// A single cell in a GOTO table
    const Entry = struct {
        /// On seeing this nonterminal...
        nonterminal: u32,
        /// Transition to this new state.
        new_state: u32,
    };

    pub fn free(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.goto_table.items) |*row| {
            row.deinit(allocator);
        }
        self.goto_table.deinit(allocator);
    }
    pub fn newState(self: *@This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
        self.num_states += 1;
        try self.goto_table.append(allocator, .empty);
    }
    pub fn goto(self: *@This(), allocator: std.mem.Allocator, nt: u32, state: u32) std.mem.Allocator.Error!void {
        const row = &self.goto_table.items[self.goto_table.items.len - 1];
        try row.append(allocator, .{ .nonterminal = nt, .new_state = state });
    }
    pub fn writeGotoMethod(self: *@This(), allocator: std.mem.Allocator, emitter: *ZigEmitter, symbol_spec: *const sym.SymbolSpec) std.Io.Writer.Error!void {
        _ = allocator;
        try emitter.implementGotoTable();
        try emitter.writeLine("return switch (state) {");
        emitter.indent(); // outer switch
        var skipped_prong = false;
        for (self.goto_table.items, 0..) |table_row, state| {
            const goto_entries = table_row.items;
            if (goto_entries.len == 0) {
                skipped_prong = true;
                continue; // Unreachable state for GOTO table, no need to generate a branch
            }
            try emitter.writeIndent();
            try emitter.out.print("{} => switch (nt) {{", .{state});
            for (goto_entries) |entry| {
                try emitter.out.print("{} => {}, ", .{ entry.nonterminal, entry.new_state });
            }
            // Zig disallows extraneous else prong
            if (goto_entries.len < (@as(usize, 1) << @intCast(emitter.ntBits(symbol_spec)))) {
                try emitter.out.writeAll("else => unreachable");
            }
            try emitter.out.writeAll("},\n");
        }
        // Zig disallows extraneous else prong
        if (skipped_prong or self.goto_table.items.len < (@as(usize, 1) << @intCast(emitter.stateBits(self.num_states)))) {
            try emitter.writeLine("else => unreachable");
        }
        emitter.dedent(); // end outer switch
        try emitter.writeLine("};");
        try emitter.endMethod();
    }
};

/// Packed array GOTO table handler, similar to how ACTION tables get
/// compressed. Theoretically, we use GOTO[state][nonterminal], but in packing
/// it's better to index by the nonterminal first and use state as offset,
/// since states are more likely to be "distinct" (not every state will have
/// a nonempty GOTO row, but every nonterminal will be used to transition in
/// some row). The arrays involved are:
/// - packed: compressed array of state (nullable)
/// - base: offset in packed for each nonterminal (non-nullable)
pub const PackerGotoHandler = struct {
    /// GOTO[nonterminal][state] (note the indices order), initialized upon
    /// `begin` call.
    table: []std.ArrayList(Entry) = undefined,
    new_state_count: u32 = 0,

    /// A single cell in GOTO
    const Entry = struct {
        /// On this state, when seeing the row's nonterminal...
        state: u32,
        /// Transition to this new state.
        new_state: u32,
    };

    pub fn begin(self: *@This(), allocator: std.mem.Allocator, symbol_spec: *const sym.SymbolSpec) std.mem.Allocator.Error!void {
        const num_nts = symbol_spec.nonterminals.count;
        const table = try allocator.alloc(std.ArrayList(Entry), num_nts);
        errdefer allocator.free(table);
        @memset(table, .empty);
        self.table = table;
    }
    pub fn free(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.table) |*row| {
            row.deinit(allocator);
        }
        allocator.free(self.table);
    }
    pub fn newState(self: *@This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
        _ = allocator;
        self.new_state_count += 1;
    }
    fn currentState(self: @This()) u32 {
        return self.new_state_count - 1;
    }
    pub fn goto(self: *@This(), allocator: std.mem.Allocator, nt: u32, state: u32) std.mem.Allocator.Error!void {
        try self.table[nt].append(allocator, .{ .state = self.currentState(), .new_state = state });
    }

    /// For sorting heuristic
    const SortEntry = struct {
        /// Which nonterminal?
        row: u32,
        /// Minimum state that is an exception
        min_column: u32,
        /// Maximum state that is an exception
        max_column: u32,

        fn noException(row: u32) @This() {
            return .{ .row = row, .min_column = std.math.maxInt(u32), .max_column = 0 };
        }

        fn isNoException(self: @This()) bool {
            return self.max_column < self.min_column;
        }

        fn width(self: @This()) u32 {
            // The only overflow case is when `noException`
            // Put no exceptions to last - they simply get an undefined base, since
            // only valid GOTO queries are made (never reject). A nonterminal
            // that does not appear in the GOTO table is also unused.
            return self.max_column -| self.min_column;
        }

        /// Wider rows come first.
        fn lessThan(_: void, a: @This(), b: @This()) bool {
            const aw = a.width();
            const bw = b.width();
            // Stable sort key
            return aw > bw or (aw == bw and (a.min_column > b.min_column or (a.min_column == b.min_column and a.row < b.row)));
        }
    };

    /// Similar logic to `Packer`, but rejecting has undefined behavior, so
    /// more aggressive optimization can be done.
    pub fn writeGotoMethod(self: *@This(), allocator: std.mem.Allocator, emitter: *ZigEmitter, symbol_spec: *const sym.SymbolSpec) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
        const num_nts = symbol_spec.nonterminals.count;
        // Create temporary tables
        const Offset = isize;
        var t_base = try allocator.alloc(Offset, num_nts);
        defer allocator.free(t_base);
        // Unlike in `Packer`, we can always share a base since accessing a
        // GOTO entry that has no number in it has undefined behavior.
        // TODO: memory optimization (4 bytes for one bit?)
        var t_packed: std.ArrayList(?u32) = .empty;
        defer t_packed.deinit(allocator);
        // Pack the rows into tables
        // First sort rows
        var sort_entries = try allocator.alloc(SortEntry, num_nts);
        defer allocator.free(sort_entries);
        for (self.table, 0..) |row, i| {
            const nt: u32 = @intCast(i);
            sort_entries[nt] = if (row.items.len == 0) .noException(nt) else blk: {
                var min: u32 = std.math.maxInt(u32);
                var max: u32 = 0;
                for (row.items) |entry| {
                    min = @min(min, entry.state);
                    max = @max(max, entry.state);
                }
                break :blk .{ .row = nt, .min_column = min, .max_column = max };
            };
        }
        std.mem.sortUnstable(SortEntry, sort_entries, {}, SortEntry.lessThan);
        // Now pack them in according to that order.
        var low_zero: usize = 0; // Lowest unoccupied index in packed, a nonnegative `Offset`
        var max_nonnegative_base: Offset = 0; // Nonnegative
        for (sort_entries) |sort_entry| {
            const nt = sort_entry.row;
            if (sort_entry.isNoException()) {
                // If row is empty (no exception), we assign undefined as
                // mentioned in `SortEntry.lessThan`. That means any value
                // works below. Use 0 to avoid overflow.
                t_base[nt] = 0;
                continue;
            }
            // Find a spot in packed table to insert the row (greedy).
            const n = t_packed.items.len;
            // Base defaults to n, when no candidate below n works.
            var base: Offset = @intCast(n);
            // Any candidate before this must fail:
            const min_candidate = @as(Offset, @intCast(low_zero)) - @as(Offset, @intCast(sort_entry.min_column));
            var candidate: Offset = min_candidate;
            // Cannot use range since candidate can be negative.
            candidate_check: while (candidate < @as(Offset, @intCast(n))) : (candidate += 1) {
                for (self.table[nt].items) |entry| {
                    // @intCast for 32-bit platforms:
                    const i = candidate + @as(Offset, @intCast(entry.state));
                    if (0 < i and i < n and t_packed.items[@intCast(i)] != null) {
                        continue :candidate_check;
                    }
                }
                // This candidate works!
                base = candidate;
                break;
            }
            // Once we've found a spot, or we've decided no existing offset works
            // as base, we can insert the row.
            t_base[nt] = base;
            max_nonnegative_base = @max(max_nonnegative_base, base);
            // The @intCast is necessary on 32-bit platforms:
            const size_to_ensure = base + @as(Offset, @intCast(sort_entry.max_column)) + 1;
            std.debug.assert(size_to_ensure > 0);
            const size_to_extend = @as(usize, @intCast(size_to_ensure)) -| n;
            try t_packed.appendNTimes(allocator, null, size_to_extend);
            // Now fill in the packed table.
            for (self.table[nt].items) |entry| {
                const i = base + @as(Offset, @intCast(entry.state));
                std.debug.assert(i >= 0);
                std.debug.assert(t_packed.items[@intCast(i)] == null);
                t_packed.items[@intCast(i)] = entry.new_state;
            }
            // Update low_zero if some cells become occupied.
            while (low_zero < t_packed.items.len and t_packed.items[low_zero] != null) {
                low_zero += 1;
            }
        }
        // Now emit code.
        try emitter.implementGotoTable();
        // Similar to `Packed`:
        const extreme_offset = @as(usize, @intCast(max_nonnegative_base)) + self.new_state_count;
        const offset_bits = 1 + std.math.log2_int_ceil(usize, extreme_offset + 1);
        try emitter.printLine("const Offset = i{};", .{offset_bits});
        const packed_len = t_packed.items.len;
        const packed_bits = if (packed_len == 0) 0 else std.math.log2_int_ceil(usize, packed_len);
        try emitter.printLine("const PackedIndex = u{};", .{packed_bits});
        try emitter.writeIndent();
        try emitter.out.writeAll("const base = [_]Offset{");
        for (t_base) |x| {
            try emitter.out.print("{},", .{x});
        }
        try emitter.out.writeAll("};\n");
        try emitter.writeIndent();
        try emitter.out.writeAll("const @\"packed\" = [_]StateSize{");
        for (t_packed.items) |opt_entry| {
            if (opt_entry) |entry| {
                try emitter.out.print("{}", .{entry});
            } else {
                try emitter.out.writeAll("undefined");
            }
            try emitter.out.writeByte(',');
        }
        try emitter.out.writeAll("};\n");
        try emitter.writeLines(
            // No error checking / rejection makes it so much simpler!
            \\const I: PackedIndex = @intCast(base[nt] + state);
            \\return @"packed"[I];
        );
        try emitter.endMethod(); // end gotoTable
    }
};

/// Naive LR(0) backend that emits Zig source with
/// **no conflict resolution** using switch statements for all mappings.
pub fn Lr0SwitchBackend(comptime GotoHandler: type) type {
    return struct {
        emitter: ZigEmitter,
        // Internal fields:
        /// A `states` of `null` means `beginTableGen` has not been called.
        states: ?*const std.ArrayList([]lr0.Item) = null,
        allocator: std.mem.Allocator = undefined,
        symbol_spec: *const sym.SymbolSpec = undefined,
        productions: *const cfg.CfgProductions = undefined,
        /// ACTION[state][terminal]
        action_table: std.ArrayList(Lr0ActionRow) = .empty,
        goto_handler: GotoHandler,
        /// If there is a conflict, it will be logged to here.
        conflict_report: ?ReportedConflict(lr0.Item) = null,
        /// How many times `beginState` has been called
        state_counter: u32 = 0,

        pub fn free(self: *@This()) void {
            if (self.states == null) {
                return;
            }
            self.states = null;
            for (self.action_table.items) |*row| {
                row.free(self.allocator);
            }
            self.action_table.deinit(self.allocator);
            self.goto_handler.free(self.allocator);
            if (self.conflict_report) |cr| {
                cr.free(self.allocator);
            }
        }

        pub const Error = ConflictError || std.Io.Writer.Error || std.mem.Allocator.Error;

        pub fn beginTableGen(self: *@This(), symbol_spec: *const sym.SymbolSpec, productions: *const cfg.CfgProductions, states: *const std.ArrayList([]lr0.Item), allocator: std.mem.Allocator) Error!void {
            self.states = states;
            self.allocator = allocator;
            self.symbol_spec = symbol_spec;
            self.productions = productions;
            if (std.meta.hasMethod(GotoHandler, "begin")) {
                // Optional GOTO handler initializer
                try self.goto_handler.begin(allocator, symbol_spec);
            }
        }
        pub fn beginState(self: *@This()) Error!void {
            self.state_counter += 1;
            try self.action_table.append(self.allocator, .reject);
            try self.goto_handler.newState(self.allocator);
        }
        pub fn acceptOnEoi(self: *@This()) Error!void {
            // `state` can be anything.
            try self.shift(self.symbol_spec.terminals.eoi, 0);
        }
        pub fn reduce(self: *@This(), production: u32) Error!void {
            const row = &self.action_table.items[self.action_table.items.len - 1];
            switch (row.*) {
                .reject => {
                    row.* = .{ .reduce = production };
                },
                .shift => unreachable, // all reduce calls come after all shifts calls
                .reduce => |other_prod| {
                    try self.reportConflict(
                        .{ .reduce = other_prod },
                        .{ .reduce = production },
                        null,
                    );
                    return ConflictError.LrConflict;
                },
            }
        }
        pub fn goto(self: *@This(), nt: u32, state: u32) Error!void {
            try self.goto_handler.goto(self.allocator, nt, state);
        }
        pub fn shift(self: *@This(), terminal: u32, state: u32) Error!void {
            const row = &self.action_table.items[self.action_table.items.len - 1];
            switch (row.*) {
                .reject => {
                    row.* = .{ .shift = .empty };
                },
                .shift => {},
                .reduce => |reduce_by| {
                    try self.reportConflict(
                        .{ .shift = state },
                        .{ .reduce = reduce_by },
                        terminal,
                    );
                    return ConflictError.LrConflict;
                },
            }
            try row.shift.append(self.allocator, .{ .terminal = terminal, .new_state = state });
        }
        pub fn endTableGen(self: *@This()) Error!void {
            try self.emitter.writeProlog(self.symbol_spec, self.productions);
            // try lr0ActionTableToActionMethodSwitch(&self.emitter, self.symbol_spec, self.productions, self.action_table.items);
            try lr0ActionTableToActionMethodPacked(&self.emitter, self.symbol_spec, self.productions, self.action_table.items, self.allocator);
            try self.goto_handler.writeGotoMethod(self.allocator, &self.emitter, self.symbol_spec);
            const num_states: u32 = @intCast(self.states.?.items.len);
            try self.emitter.writeEpilog(num_states);
        }

        /// Report a conflict at current state. We don't have conflict resolution
        /// support since we assume if a state can reduce it must reduce for all
        /// lookahead tokens.
        fn reportConflict(self: *@This(), action1: Action, action2: Action, lookahead: ?u32) std.mem.Allocator.Error!void {
            const copied_core_set = try self.allocator.dupe(lr0.Item, self.states.?.items[self.state_counter - 1]);
            self.conflict_report = .{
                .action1 = action1,
                .action2 = action2,
                .lookahead = lookahead,
                .core_set = copied_core_set,
            };
        }
    };
}

fn lr0ActionTableToActionMethodSwitch(emitter: *ZigEmitter, symbol_spec: *const sym.SymbolSpec, productions: *const cfg.CfgProductions, actions: []Lr0ActionRow) std.Io.Writer.Error!void {
    try emitter.implementAction();
    try emitter.writeLine("return switch (state) {");
    emitter.indent(); // outer switch
    const num_states: u32 = @intCast(actions.len);
    const state_bits = emitter.stateBits(num_states);
    const tag_bits = emitter.tagBackingIntBits(symbol_spec);
    for (actions, 0..) |action_row, state| {
        try emitter.writeIndent();
        try emitter.out.print("{} => ", .{state});
        switch (action_row) {
            .reject => try emitter.out.writeAll(".reject"),
            .reduce => |prod_id| try emitter.writeReduceAction(productions, prod_id),
            .shift => |shifts| {
                try emitter.out.writeAll("switch (lookahead) {");
                for (shifts.items) |entry| {
                    try emitter.out.print("{} => ", .{entry.terminal});
                    if (entry.terminal == symbol_spec.terminals.eoi) { // Accept
                        @branchHint(.unlikely);
                        try emitter.out.writeAll(".accept");
                    } else {
                        try emitter.writeShiftAction(entry.new_state);
                    }
                    try emitter.out.writeAll(", ");
                }
                // Zig disallows extraneous else prong
                if (shifts.items.len < (@as(usize, 1) << @intCast(tag_bits))) {
                    try emitter.out.writeAll("else => .reject");
                }
                try emitter.out.writeAll("}");
            },
        }
        try emitter.out.writeAll(",\n");
    }
    // Zig disallows extraneous else prong
    if (num_states < (@as(usize, 1) << @intCast(state_bits))) {
        try emitter.writeLine("else => unreachable");
    }
    emitter.dedent(); // end outer switch
    try emitter.writeLine("};");
    try emitter.endMethod();
}

fn lr0ActionTableToActionMethodPacked(emitter: *ZigEmitter, symbol_spec: *const sym.SymbolSpec, productions: *const cfg.CfgProductions, actions: []Lr0ActionRow, scrap_allocator: std.mem.Allocator) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
    var backend: Lr0ActionTablePackerBackend = .{
        .actions = actions,
        .eoi = symbol_spec.terminals.eoi,
    };
    var packer = try Packer(Lr0ActionTablePackerBackend).init(symbol_spec, productions, &backend, scrap_allocator);
    defer packer.deinit();
    try packer.makePack();
    try packer.emit(emitter);
}

const Lr0ActionTablePackerBackend = struct {
    /// BORROWED action table
    actions: []Lr0ActionRow,
    /// EOI terminal ID
    eoi: u32,

    const ExceptionIterator = struct {
        row: *const Lr0ActionRow,
        /// `eoi` from the owner
        eoi: u32,
        /// Next index to return for `.shift` rows.
        i: u32 = 0,

        fn next(self: *@This()) ?Packer(Lr0ActionTablePackerBackend).ActionEntry {
            return switch (self.row.*) {
                // No exception when the entire row is the same action
                .reduce, .reject => null,
                .shift => |shifts| if (self.i == shifts.items.len) null else blk: {
                    const s = shifts.items[self.i];
                    self.i += 1;
                    break :blk .{
                        .check = s.terminal,
                        .action = if (s.terminal == self.eoi) .accept else .{ .shift = s.new_state },
                    };
                },
            };
        }
    };

    fn numStates(self: @This()) u32 {
        return @intCast(self.actions.len);
    }

    fn rowDefault(self: *@This(), state: u32) Packer(Lr0ActionTablePackerBackend).CompactAction {
        return switch (self.actions[state]) {
            .reduce => |production| .{ .reduce = production },
            .reject, .shift => .reject,
        };
    }

    fn rowExceptions(self: *@This(), state: u32) ExceptionIterator {
        return .{ .row = &self.actions[state], .eoi = self.eoi };
    }
};

/// A single (valid) action in a LR-style ACTION table.
pub const Action = union(enum) {
    /// Shift to this new state; or accept if this action is for the End of
    /// Input token (in which case the value is undefined).
    shift: u32,
    /// Reduce using this production
    reduce: u32,
};

const ShiftCell = struct {
    terminal: u32,
    state: u32,
};
/// A group of reduce actions. This is a compact representation if the same
/// item has many lookahead tokens that it accepts. This also allows us to
/// generate more efficient code in the switch prongs.
const GroupedReduces = struct {
    /// Production ID used to reduce.
    production: u32,
    /// The lookahead must be one of these.
    lookaheads: []u32,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.lookaheads);
        self.* = undefined;
    }
};

/// A (validated) row in an ACTION table. The action handlers are designed to
/// resolve conflicts with bitsets/arrays rather than hashmaps. Shifting an EOI
/// is considered to mean accept.
const ActionRow = struct {
    shifts: std.ArrayList(ShiftCell),
    reduces: std.ArrayList(GroupedReduces),

    pub const empty: @This() = .{
        .shifts = .empty,
        .reduces = .empty,
    };

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.shifts.deinit(allocator);
        for (self.reduces.items) |*reduce_group| {
            reduce_group.deinit(allocator);
        }
        self.reduces.deinit(allocator);
        self.* = undefined;
    }

    /// Inefficient linear scan.
    pub fn searchForReduce(self: @This(), lookahead: u32) ?u32 {
        for (self.reduces.items) |reduce_group| {
            if (std.mem.findScalar(u32, reduce_group.lookaheads, lookahead)) |_| {
                return reduce_group.production;
            }
        }
        return null;
    }

    /// Inefficient linear scan.
    pub fn searchForShift(self: @This(), lookahead: u32) ?u32 {
        for (self.shifts.items) |entry| {
            if (entry.terminal == lookahead) {
                return entry.state;
            }
        }
        return null;
    }

    /// Inefficient linear scan.
    pub fn searchForAction(self: @This(), lookahead: u32) ?Action {
        if (self.searchForShift(lookahead)) |new_state| {
            return .{ .shift = new_state };
        }
        if (self.searchForReduce(lookahead)) |production| {
            return .{ .reduce = production };
        }
        return null;
    }
};

/// Convert action table (`std.ArrayList(ActionRow)`) into `Parser.action`
/// method in generated parser, using nested `switch` (naive).
fn actionTableToActionMethodSwitch(symbol_spec: *const sym.SymbolSpec, productions: *const cfg.CfgProductions, action_table: std.ArrayList(ActionRow), emitter: *ZigEmitter) std.Io.Writer.Error!void {
    const num_states: u32 = @intCast(action_table.items.len);
    const state_bits = emitter.stateBits(num_states);
    const tag_bits = emitter.tagBackingIntBits(symbol_spec);
    try emitter.implementAction();
    try emitter.writeLine("return switch (state) {");
    emitter.indent(); // outer switch
    for (action_table.items, 0..) |action_row, state| {
        try emitter.writeIndent();
        try emitter.out.print("{} => switch (lookahead) {{", .{state});
        var terminals_written: u32 = @intCast(action_row.shifts.items.len);
        for (action_row.shifts.items) |shift_entry| {
            try emitter.out.print("{} => ", .{shift_entry.terminal});
            if (shift_entry.terminal == symbol_spec.terminals.eoi) { // Accept
                @branchHint(.unlikely);
                try emitter.out.writeAll(".accept");
            } else {
                try emitter.writeShiftAction(shift_entry.state);
            }
            try emitter.out.writeAll(", ");
        }
        for (action_row.reduces.items) |reduce_group| {
            // Lookahead set may become empty due to conflict resolution
            // Cannot write empty list as switch case.
            if (reduce_group.lookaheads.len == 0) {
                continue;
            }
            // The benefit of grouping reduce actions :)
            for (reduce_group.lookaheads) |terminal| {
                try emitter.out.print("{},", .{terminal});
            }
            try emitter.out.writeAll(" => ");
            try emitter.writeReduceAction(productions, reduce_group.production);
            try emitter.out.writeAll(", ");
            terminals_written += @intCast(reduce_group.lookaheads.len);
        }
        // Zig disallows extraneous else prong
        if (terminals_written < (@as(u32, 1) << @intCast(tag_bits))) {
            try emitter.out.writeAll("else => .reject");
        }
        try emitter.out.writeAll("},\n");
    }
    // Zig disallows extraneous else prong
    if (num_states < (@as(usize, 1) << @intCast(state_bits))) {
        try emitter.writeLine("else => unreachable");
    }
    emitter.dedent(); // end outer switch
    try emitter.writeLine("};");
    try emitter.endMethod();
}

/// Similar to `actionTableToActionMethodSwitch` but generate more efficient
/// parser using constant arrays packed with data.
fn actionTableToActionMethodPacked(symbol_spec: *const sym.SymbolSpec, productions: *const cfg.CfgProductions, action_table: std.ArrayList(ActionRow), emitter: *ZigEmitter, scrap_allocator: std.mem.Allocator) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    var backend: ActionTablePackerBackend = .{
        .action_rows = action_table.items,
        .eoi = symbol_spec.terminals.eoi,
    };
    var packer = try Packer(ActionTablePackerBackend).init(symbol_spec, productions, &backend, scrap_allocator);
    defer packer.deinit();
    try packer.makePack();
    try packer.emit(emitter);
}

/// `Packer` backend for `[]ActionRow` representation of ACTION table.
const ActionTablePackerBackend = struct {
    /// BORROWED slice
    action_rows: []ActionRow,
    /// EOI token ID
    eoi: u32,

    const ExceptionIterator = struct {
        /// Corresponding row (borrowed)
        action_row: *const ActionRow,
        /// EOI token ID from owner
        eoi: u32,
        /// In `shifts` or `reduce`?
        stage: enum { shift, reduce } = .shift,
        /// The next index to return
        i: u32 = 0,
        /// Next secondary index to return (for reduce only)
        j: u32 = 0,

        fn next(self: *@This()) ?Packer(ActionTablePackerBackend).ActionEntry {
            if (self.stage == .shift) {
                if (self.i == self.action_row.shifts.items.len) {
                    self.stage = .reduce;
                    self.i = 0;
                } else {
                    defer self.i += 1;
                    const shift = self.action_row.shifts.items[self.i];
                    return .{
                        .action = if (shift.terminal == self.eoi) .accept else .{ .shift = shift.state },
                        .check = shift.terminal,
                    };
                }
            }
            std.debug.assert(self.stage == .reduce);
            while (self.i < self.action_row.reduces.items.len) {
                const group = self.action_row.reduces.items[self.i];
                if (self.j == group.lookaheads.len) {
                    self.j = 0;
                    self.i += 1;
                } else {
                    defer self.j += 1;
                    return .{
                        .action = .{ .reduce = group.production },
                        .check = group.lookaheads[self.j],
                    };
                }
            }
            return null;
        }
    };

    fn numStates(self: @This()) u32 {
        return @intCast(self.action_rows.len);
    }

    /// For now, always use reject as default
    /// TODO: sometimes reduce can be a better default, analyze size of reduce
    /// groups vs. number of reject columns
    fn rowDefault(self: *@This(), state: u32) Packer(ActionTablePackerBackend).CompactAction {
        _ = self;
        _ = state;
        return .reject;
    }

    fn rowExceptions(self: *@This(), state: u32) ExceptionIterator {
        return .{ .action_row = &self.action_rows[state], .eoi = self.eoi };
    }
};

/// Pack ACTION table into compact arrays. Intended to be useful to *all*
/// (traditional) LR-family algorithms. A consumer must implement a `PackerBackend`
/// supporting the following:
/// ```zig
/// const ExceptionIterator = struct {
///     fn next(self: *@This()) ?Packer(PackerBackend).ActionEntry
/// };
/// fn numStates(self: @This()) u32
/// /// Default action for this state
/// fn rowDefault(self: *@This(), state: u32) Packer(PackerBackend).CompactAction
/// /// Iterate through the exceptions (non-default columns)
/// fn rowExceptions(self: *@This(), state: u32) ExceptionIterator
/// ```
/// TODO: many heuristic optimizations to be made here.
fn Packer(comptime Backend: type) type {
    return struct {
        symbol_spec: *const sym.SymbolSpec,
        productions: *const cfg.CfgProductions,
        backend: *Backend,
        num_states: u32,
        /// `action` and `check` arrays combined.
        t_action: std.ArrayList(ActionEntry),
        /// Base of each row in compact `t_action`, or `no_row` if it's always
        /// the default action. The base can be negative, in which case if the
        /// state+terminal index is negative, the default action is invoked.
        t_base: []Offset,
        /// Default action in each state
        /// TODO: substantial defaults are going to be rejects?
        t_default: []CompactAction,
        /// Used base may not be reused unless two rows are exactly identical
        /// TODO: replace with a growing bitset?
        used_base: std.AutoHashMapUnmanaged(Offset, void),
        /// The lowest base that is unoccupied (lowest `i` such that
        /// `t_action[i].isEmpty()`, or length of `t_action` if no such `i`
        /// exists). This is always nonnegative.
        low_zero: Offset,
        /// The maximum base (synced to the maximum in `used_base`)
        max_base: Offset,
        /// Allocator for storing generated tables
        allocator: std.mem.Allocator,

        const Offset = isize;

        fn init(symbol_spec: *const sym.SymbolSpec, productions: *const cfg.CfgProductions, backend: *Backend, allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
            const num_states = backend.numStates();
            const t_base = try allocator.alloc(Offset, num_states);
            const t_default = try allocator.alloc(CompactAction, num_states);
            return .{
                .symbol_spec = symbol_spec,
                .productions = productions,
                .backend = backend,
                .num_states = num_states,
                .t_action = .empty,
                .t_base = t_base,
                .t_default = t_default,
                .used_base = .empty,
                .low_zero = 0,
                .max_base = std.math.minInt(Offset),
                .allocator = allocator,
            };
        }

        fn deinit(self: *@This()) void {
            self.t_action.deinit(self.allocator);
            self.allocator.free(self.t_base);
            self.used_base.deinit(self.allocator);
            self.allocator.free(self.t_default);
        }

        /// For heuristic of putting wider rows in first, we must sort the rows.
        /// This struct includes facts that allow us to sort.
        const SortEntry = struct {
            /// Which state?
            row: u32,
            /// Minimum terminal that is an exception
            min_terminal: u32,
            /// Maximum terminal that is an exception
            max_terminal: u32,

            fn noException(row: u32) @This() {
                return .{ .row = row, .min_terminal = std.math.maxInt(u32), .max_terminal = 0 };
            }

            fn isNoException(self: @This()) bool {
                return self.max_terminal < self.min_terminal;
            }

            fn width(self: @This()) u32 {
                // The only overflow case is when `noException`; when we handle those
                // does not actually matter (they don't change the pact arrays anyway).
                return self.max_terminal -| self.min_terminal;
            }

            /// Wider rows come first.
            fn lessThan(_: void, a: @This(), b: @This()) bool {
                const aw = a.width();
                const bw = b.width();
                // Stable sort key
                return aw > bw or (aw == bw and (a.min_terminal > b.min_terminal or (a.min_terminal == b.min_terminal and a.row < b.row)));
            }
        };

        /// An action in generated compact representation.
        const CompactAction = union(enum) {
            /// State number
            shift: u32,
            /// Rule ID
            reduce: u32,
            accept,
            reject,

            fn emit(self: @This(), emitter: *ZigEmitter) std.Io.Writer.Error!void {
                switch (self) {
                    .accept => {
                        @branchHint(.unlikely);
                        try emitter.out.writeAll(".accept");
                    },
                    .reduce => |prod_id| try emitter.out.print(".{{.reduce={}}}", .{prod_id}),
                    .shift => |new_state| try emitter.out.print(".{{.shift={}}}", .{new_state}),
                    .reject => try emitter.out.writeAll(".reject"),
                }
            }
        };

        /// An entry in the compact `action` array
        const ActionEntry = struct {
            action: CompactAction,
            /// The expected terminal/lookahead. If equals `empty` means unoccupied
            /// cell; `action` is undefined in that case.
            check: u32,

            const empty_check = std.math.maxInt(u32);
            const empty: @This() = .{
                .action = undefined,
                .check = empty_check,
            };

            fn isEmpty(self: @This()) bool {
                return self.check == empty_check;
            }
        };

        // base[i] = no_row => No base offset; always use default action.
        const no_row = std.math.minInt(Offset);

        fn makePack(self: *@This()) std.mem.Allocator.Error!void {
            // Collect basic info on each row (first pass)
            var sort_entries = try self.allocator.alloc(SortEntry, self.num_states);
            defer self.allocator.free(sort_entries);
            for (0..self.num_states) |state_usize| {
                const state: u32 = @intCast(state_usize);
                const entry = &sort_entries[state];
                entry.* = .noException(state);
                var it: Backend.ExceptionIterator = self.backend.rowExceptions(state);
                while (it.next()) |action_entry| {
                    const t = action_entry.check;
                    entry.min_terminal = @min(entry.min_terminal, t);
                    entry.max_terminal = @max(entry.max_terminal, t);
                }
            }
            // Sort the rows (heuristic, widest row first inserted)
            std.mem.sortUnstable(SortEntry, sort_entries, {}, SortEntry.lessThan);
            // Now pack the rows into arrays
            for (sort_entries) |sort_entry| {
                const state = sort_entry.row;
                // You always fill in the default action!
                self.t_default[state] = self.backend.rowDefault(state);
                if (sort_entry.isNoException()) {
                    // If row is empty (no exception), assign `no_row`. This is currently
                    // only possible with LR(0) which reduces for the entire row, or when
                    // we have a nonproductive entry nt (i.e. when the grammar does not
                    // accept any string).
                    self.t_base[state] = no_row;
                    continue;
                }
                // Find a spot in action table to insert the row (greedy).
                const n = self.t_action.items.len;
                // Base defaults to n, when no candidate below n works.
                var base: Offset = @intCast(n);
                // Anything candidate before that must fail.
                // The @intCast is necessary on 32-bit platforms:
                const min_candidate = self.low_zero - @as(Offset, @intCast(sort_entry.min_terminal));
                var candidate: Offset = min_candidate;
                // Cannot use range since candidate can be negative.
                candidate_check: while (candidate < @as(Offset, @intCast(n))) : (candidate += 1) {
                    if (self.used_base.get(candidate) != null) {
                        // TODO: identical rows can share a base
                        continue;
                    }
                    var it: Backend.ExceptionIterator = self.backend.rowExceptions(state);
                    while (it.next()) |action_entry| {
                        // The @intCast is necessary on 32-bit platforms:
                        const i = candidate + @as(Offset, @intCast(action_entry.check));
                        if (0 < i and i < n and !self.t_action.items[@intCast(i)].isEmpty()) {
                            continue :candidate_check;
                        }
                    }
                    // This candidate works!
                    base = candidate;
                    break;
                }
                // Once we've found a spot, or we've decided no existing offset works
                // as base, we can insert the row.
                self.t_base[state] = base;
                try self.used_base.put(self.allocator, base, {});
                self.max_base = @max(self.max_base, base);
                // The @intCast is necessary on 32-bit platforms:
                const size_to_ensure = base + @as(Offset, @intCast(sort_entry.max_terminal)) + 1;
                std.debug.assert(size_to_ensure > 0);
                const size_to_extend = @as(usize, @intCast(size_to_ensure)) -| n;
                try self.t_action.appendNTimes(self.allocator, .empty, size_to_extend);
                // Now fill in the action table.
                {
                    var it: Backend.ExceptionIterator = self.backend.rowExceptions(state);
                    while (it.next()) |action_entry| {
                        const i = base + @as(Offset, @intCast(action_entry.check));
                        std.debug.assert(i >= 0);
                        std.debug.assert(self.t_action.items[@intCast(i)].isEmpty());
                        self.t_action.items[@intCast(i)] = action_entry;
                    }
                }
                // Update low_zero if some cells become occupied.
                while (@as(usize, @intCast(self.low_zero)) < self.t_action.items.len and !self.t_action.items[@intCast(self.low_zero)].isEmpty()) {
                    self.low_zero += 1;
                }
            }
        }

        fn emit(self: *@This(), emitter: *ZigEmitter) std.Io.Writer.Error!void {
            // Table calculated; proceed to table emission.
            try emitter.writeLine("const Packed = struct {");
            emitter.indent(); // struct Packed
            // The runtime `Offset` type must be able to hold:
            // - A minimum of -total_terminals (or rather minimum base)
            // - A maximum of maximum base + total_terminals
            // - For Offset to win in peer type resolution with Token.TagSize:
            //   a maximum of total_terminals.
            const extreme_offset = @max(0, self.max_base) + self.symbol_spec.terminals.count;
            std.debug.assert(extreme_offset > 0);
            // iN range is [-2**(i-1), 2**(i-1))
            // Note the two "+1":
            const offset_bits = 1 + std.math.log2_int_ceil(usize, @as(usize, @intCast(extreme_offset)) + 1);
            try emitter.printLine("const Offset = i{};", .{offset_bits});

            const action_len = self.t_action.items.len;
            const action_bits = if (action_len == 0) 0 else std.math.log2_int_ceil(usize, action_len);
            try emitter.printLine("const ActionIndex = u{};", .{action_bits});

            try emitter.writeIndent();
            try emitter.out.writeAll("const base = [_]?Offset{");
            for (self.t_base) |offset| {
                if (offset == no_row) {
                    try emitter.out.writeAll("null,");
                } else {
                    // This is the idea, but will not compile since we used ceil, so left
                    // shift can overflow:
                    // std.debug.assert(offset < @shlExact(@as(usize, 1), action_bits));
                    try emitter.out.print("{},", .{offset});
                }
            }
            try emitter.out.writeAll("};\n");

            const production_bits = if (self.productions.count == 0) 0 else std.math.log2_int_ceil(u32, self.productions.count);
            try emitter.printLine("const ProductionSize = u{};", .{production_bits});
            try emitter.writeLines(
                \\const CompactAction = union(enum) {
                \\    shift: StateSize,
                \\    reduce: ProductionSize,
                \\    accept,
                \\    reject,
                \\
                \\    fn toNonCompact(self: @This()) Action {
                \\        return switch (self) {
                \\            .accept => .accept,
                \\            .reject => .reject,
                \\            .shift => |new_state| .{.shift = new_state},
                \\            .reduce => |p| .{.reduce = .{.rhs_len = rhs_len[p], .lhs = lhs[p]}},
                \\        };
                \\    }
                // \\
                // \\    fn debugPrint(self: @This()) void {
                // \\        switch (self) {
                // \\            .accept => std.debug.print("accept", .{}),
                // \\            .shift => |s| std.debug.print("shift {}", .{s}),
                // \\            .reduce => |r| std.debug.print("reduce {}", .{r}),
                // \\            .reject => std.debug.print("reject", .{}),
                // \\        }
                // \\    }
                \\};
            );

            // To avoid collision with action() method:
            try emitter.writeIndent();
            try emitter.out.writeAll("const action_ = [_]CompactAction{");
            for (self.t_action.items) |entry| {
                if (entry.isEmpty()) {
                    try emitter.out.writeAll("undefined");
                } else {
                    try entry.action.emit(emitter);
                }
                try emitter.out.writeByte(',');
            }
            try emitter.out.writeAll("};\n");

            try emitter.writeIndent();
            try emitter.out.writeAll("const default = [_]CompactAction{");
            for (self.t_default) |action| {
                try action.emit(emitter);
                try emitter.out.writeByte(',');
            }
            try emitter.out.writeAll("};\n");

            try emitter.writeIndent();
            try emitter.out.writeAll("const check = [_]?Token.TagSize{");
            for (self.t_action.items) |entry| {
                if (entry.isEmpty()) {
                    try emitter.out.writeAll("null,");
                } else {
                    try emitter.out.print("{},", .{entry.check});
                }
            }
            try emitter.out.writeAll("};\n");

            // We need additional tables for production LHS and RHS count
            try emitter.writeIndent();
            try emitter.out.writeAll("const lhs = [_]NtSize{");
            for (self.productions.lhs[0..self.productions.count]) |lhs| {
                try emitter.out.print("{},", .{lhs});
            }
            try emitter.out.writeAll("};\n");
            try emitter.writeIndent();
            try emitter.out.writeAll("const rhs_len = [_]RhsLenSize{");
            for (self.productions.rhs[0..self.productions.count]) |rhs| {
                try emitter.out.print("{},", .{rhs.len});
            }
            try emitter.out.writeAll("};\n");
            emitter.dedent(); // end struct Packed
            try emitter.writeLine("};");

            // Tables emitted, now comes lookup logic
            // Be very careful with integer overflow.
            try emitter.implementAction();
            try emitter.writeLines(
                // \\std.debug.print("state: {} lookahead: {} ", .{state, lookahead});
                // \\defer std.debug.print("\n", .{});
                \\if (Packed.base[state]) |B| {
                \\    const I_signed = B + lookahead;
                \\    if (I_signed >= 0 and I_signed < Packed.check.len) {
                \\        const I: Packed.ActionIndex = @intCast(I_signed);
                \\        if (Packed.check[I]) |expected_column| {
                \\            if (expected_column == lookahead) {
                // \\                Packed.action_[I].debugPrint();
                \\                return Packed.action_[I].toNonCompact();
                \\            }
                \\        }
                \\    }
                \\}
                // \\Packed.default[state].debugPrint();
                \\return Packed.default[state].toNonCompact();
            );
            try emitter.endMethod();
        }
    };
}

/// Specialized `ActionHandler(void)`.
const ActionHandlerNoConflict = struct {
    symbol_spec: *const sym.SymbolSpec,
    productions: *const cfg.CfgProductions,
    conflict_resolver: void,
    // Following are for conflict reporting; they are undefined if no
    // conflict occurred.
    conflicting_action1: Action,
    conflicting_action2: Action,
    conflicting_lookahead: u32,

    // --- Internal
    /// ACTION[state][terminal]
    action_table: std.ArrayList(ActionRow),
    /// Current ACTION row we're building, null if none exists
    current_row: BuildingActionRow,
    /// If we've started the first ACTION row.
    started_first_row: bool,

    /// Reexport the conflict resolver type.
    pub const ConflictResolver = void;

    /// A row in an ACTION table that is *being built*.
    const BuildingActionRow = struct {
        /// Length is number of terminals; records if each terminal has a
        /// corresponding action. For conflict detection.
        occupied: std.DynamicBitSetUnmanaged,
        /// The actual action row.
        row: ?ActionRow,

        pub fn init(allocator: std.mem.Allocator, num_terminals: u32) std.mem.Allocator.Error!@This() {
            const occupied = try std.DynamicBitSetUnmanaged.initEmpty(allocator, num_terminals);
            errdefer occupied.deinit(allocator);
            return .{
                .occupied = occupied,
                .row = null,
            };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            defer self.* = undefined;
            self.occupied.deinit(allocator);
            if (self.row) |row| {
                var row_ = row;
                row_.deinit(allocator);
            }
        }

        /// Start a building row.
        pub fn beginRow(self: *@This()) void {
            self.occupied.unsetAll();
            self.row = .empty;
        }

        /// End the current building row, returning the resulting row (ownership
        /// is transferred).
        pub fn endRow(self: *@This()) ActionRow {
            defer self.row = null;
            return self.row.?;
        }
    };

    pub fn init(allocator: std.mem.Allocator, symbol_spec: *const sym.SymbolSpec, productions: *const cfg.CfgProductions, conflict_resolver: void) std.mem.Allocator.Error!@This() {
        const building_row = try BuildingActionRow.init(allocator, symbol_spec.terminals.count);
        errdefer building_row.deinit(allocator);
        return .{
            .symbol_spec = symbol_spec,
            .productions = productions,
            .conflict_resolver = conflict_resolver,
            .action_table = .empty,
            .current_row = building_row,
            .started_first_row = false,
            .conflicting_action1 = undefined,
            .conflicting_action2 = undefined,
            .conflicting_lookahead = undefined,
        };
    }

    pub fn free(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.action_table.items) |*row| {
            row.deinit(allocator);
        }
        self.action_table.deinit(allocator);
        self.current_row.deinit(allocator);
    }

    pub const ActionError = std.mem.Allocator.Error || ConflictError;

    fn potentialEndOfPreviousRow(self: *@This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
        if (self.started_first_row) {
            @branchHint(.likely);
            try self.action_table.append(allocator, self.current_row.endRow());
        } else {
            self.started_first_row = true;
        }
    }
    pub fn newState(self: *@This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
        try self.potentialEndOfPreviousRow(allocator);
        self.current_row.beginRow();
    }
    pub fn shift(self: *@This(), allocator: std.mem.Allocator, terminal: u32, new_state: u32) ActionError!void {
        if (self.current_row.occupied.isSet(terminal)) {
            self.conflicting_lookahead = terminal;
            self.conflicting_action1 = .{ .shift = new_state };
            // We have to find the reduce rule that is in conflict
            self.conflicting_action2 = .{ .reduce = self.current_row.row.?.searchForReduce(terminal).? };
            return ConflictError.LrConflict;
        }
        self.current_row.occupied.set(terminal);
        try self.current_row.row.?.shifts.append(allocator, .{ .terminal = terminal, .state = new_state });
    }
    pub fn reduceMultiple(self: *@This(), allocator: std.mem.Allocator, terminals: std.DynamicBitSetUnmanaged, production: u32) ActionError!void {
        { // Conflict detection
            var row_copy = try self.current_row.occupied.clone(allocator);
            defer row_copy.deinit(allocator);
            row_copy.setIntersection(terminals);
            // If conflict, find one example lookahead to report on
            if (row_copy.findFirstSet()) |terminal| {
                self.conflicting_lookahead = @intCast(terminal);
                self.conflicting_action1 = .{ .reduce = production };
                // Must be a reduce-reduce conflict since all shift calls come
                // after the reduce call.
                const other_reduce = self.current_row.row.?.searchForReduce(@intCast(terminal)).?;
                self.conflicting_action2 = .{ .reduce = other_reduce };
                return ConflictError.LrConflict;
            }
        }
        const n_lookaheads = terminals.count();
        var lookaheads = try allocator.alloc(u32, n_lookaheads);
        errdefer allocator.free(lookaheads);
        var it = terminals.iterator(.{});
        var i: u32 = 0;
        while (it.next()) |terminal| {
            lookaheads[i] = @intCast(terminal);
            i += 1;
        }
        self.current_row.occupied.setUnion(terminals);
        try self.current_row.row.?.reduces.append(allocator, .{
            .lookaheads = lookaheads,
            .production = production,
        });
    }
    pub fn acceptOnEoi(self: *@This(), allocator: std.mem.Allocator) ActionError!void {
        // New `state` can be any
        return self.shift(allocator, self.symbol_spec.terminals.eoi, 0);
    }
    pub fn done(self: *@This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
        try self.potentialEndOfPreviousRow(allocator);
    }
};

// Conflict resolver template:
// pub const Resolver = struct {
//     pub const Error = error{};
//     pub fn resolveShiftReduce(self: *@This(), terminal: u32, nonterminal: u32) Error!?enum{shift, reduce} {}
//     pub fn resolveReduceReduce(self: *@This(), nonterminals: [2]u32) Error!?u1 {}
// };

/// Emit Zig code to handle any LR-style ACTION table. A `ConflictResolver_`
/// of `void` means no conflict resolution.
pub fn ActionHandler(comptime ConflictResolver_: type) type {
    if (ConflictResolver_ == void) {
        // We have specialized the case when no conflict resolution is needed
        // (optimized code/data model).
        return ActionHandlerNoConflict;
    }
    return struct {
        symbol_spec: *const sym.SymbolSpec,
        productions: *const cfg.CfgProductions,
        /// Optional conflict resolver
        conflict_resolver: ConflictResolver,
        // Following are for conflict reporting; they are undefined if no
        // conflict occurred.
        conflicting_action1: Action,
        conflicting_action2: Action,
        conflicting_lookahead: u32,

        // --- Internal
        /// ACTION[state][terminal]
        action_table: std.ArrayList(ActionRow),
        /// Lazy array of length (number of terminals) for conflict detection
        /// and resolution. It is called lazy because it persists across
        /// states.
        lazy: []LazyEntry,
        /// Whether the corresponding `lazy` array slot contains a valid entry.
        /// We don't use `[]?LazyEntry` because they costs 4 bytes to be added
        /// per item when only 1 bit of those is needed.
        has_lazy: std.DynamicBitSetUnmanaged,
        /// Currently building row.
        current_row: BuildingActionRow,
        /// If we've started the first ACTION row.
        started_first_row: bool,

        /// Refers to an ACTION cell that is a reduce. See `.lazy`.
        const LazyEntry = struct {
            /// For which state is this?
            state: u32,
            /// Index in `row.reduces` for that state's `ActionRow`.
            group_index: u32,
        };
        /// An ACTION row being built (corresponds to current state).
        const BuildingActionRow = struct {
            /// The shifts ArrayList's ownership is transferred to the completed
            /// row directly.
            shifts: std.ArrayList(ShiftCell),
            /// This array list never has its objects deinited to prevent
            /// reallocation over different states. Its len represents how
            /// many have been inited.
            raw_reduces: std.ArrayList(ReduceGroup),
            /// Actual length of `raw_reduces` with contents.
            reduce_len: u32,

            /// Similar to `GroupedReduce` but allows efficient modification on
            /// `.lookaheads` (for conflict resolution).
            const ReduceGroup = struct {
                /// Production ID used to reduce.
                production: u32,
                /// We can't do ArrayList because we want efficient random removal.
                /// A BBST works here but that's kind of expensive in constant. In
                /// the end I decided we should just keep bitset from upstream
                /// (follow set).
                lookaheads: std.DynamicBitSetUnmanaged,

                pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                    self.lookaheads.deinit(allocator);
                    self.* = undefined;
                }
            };

            pub const init: @This() = .{
                .shifts = .empty,
                .raw_reduces = .empty,
                .reduce_len = 0,
            };

            pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                self.shifts.deinit(allocator);
                for (self.raw_reduces.items) |*reduce_group| {
                    reduce_group.deinit(allocator);
                }
                self.raw_reduces.deinit(allocator);
            }

            pub fn addReduce(self: *@This(), allocator: std.mem.Allocator, production: u32, lookaheads: std.DynamicBitSetUnmanaged) std.mem.Allocator.Error!void {
                if (self.reduce_len == self.raw_reduces.items.len) {
                    // If not enough space, allocate new
                    // initEmpty is not important (bits can be undefined)
                    var new_lookaheads = try std.DynamicBitSetUnmanaged.initEmpty(allocator, lookaheads.bit_length);
                    errdefer new_lookaheads.deinit(allocator);
                    try self.raw_reduces.append(allocator, .{
                        .lookaheads = new_lookaheads,
                        .production = undefined,
                    });
                }
                const group = &self.raw_reduces.items[self.reduce_len];
                group.production = production;
                const num_masks = std.math.divCeil(usize, lookaheads.bit_length, @typeInfo(std.DynamicBitSetUnmanaged.MaskInt).int.bits) catch unreachable;
                @memcpy(group.lookaheads.masks[0..num_masks], lookaheads.masks[0..num_masks]);
                self.reduce_len += 1;
            }

            pub fn popReduce(self: *@This()) void {
                self.reduce_len -= 1;
            }

            pub fn getReduce(self: @This(), index: u32) *ReduceGroup {
                return &self.raw_reduces.items[index];
            }

            /// End the current building row and return the resulting row
            /// (ownership transferred).
            pub fn endRow(self: *@This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!ActionRow {
                var reduces_slice = try allocator.alloc(GroupedReduces, self.reduce_len);
                errdefer allocator.free(reduces_slice);
                const reduces: std.ArrayList(GroupedReduces) = .fromOwnedSlice(reduces_slice);
                var i: u32 = 0;
                errdefer {
                    for (0..i) |j| {
                        allocator.free(reduces_slice[j].lookaheads);
                    }
                }
                while (i < self.reduce_len) : (i += 1) {
                    const raw = self.raw_reduces.items[i];
                    var lookaheads = try allocator.alloc(u32, raw.lookaheads.count());
                    errdefer allocator.free(lookaheads);
                    var it = raw.lookaheads.iterator(.{});
                    var j: u32 = 0;
                    while (it.next()) |lookahead| {
                        lookaheads[j] = @intCast(lookahead);
                        j += 1;
                    }
                    reduces_slice[i] = .{
                        .production = raw.production,
                        .lookaheads = lookaheads,
                    };
                }
                defer {
                    // On success:
                    self.reduce_len = 0;
                    self.shifts = .empty;
                }
                return .{
                    .shifts = self.shifts,
                    .reduces = reduces,
                };
            }
        };

        /// Reexport the conflict resolver type.
        pub const ConflictResolver = ConflictResolver_;

        pub fn init(allocator: std.mem.Allocator, symbol_spec: *const sym.SymbolSpec, productions: *const cfg.CfgProductions, conflict_resolver: ConflictResolver) std.mem.Allocator.Error!@This() {
            const lazy = try allocator.alloc(LazyEntry, symbol_spec.terminals.count);
            errdefer allocator.free(lazy);
            const has_lazy = try std.DynamicBitSetUnmanaged.initEmpty(allocator, symbol_spec.terminals.count);
            errdefer has_lazy.deinit(allocator);
            return .{
                .symbol_spec = symbol_spec,
                .productions = productions,
                .conflict_resolver = conflict_resolver,
                .conflicting_action1 = undefined,
                .conflicting_action2 = undefined,
                .conflicting_lookahead = undefined,
                .action_table = .empty,
                .lazy = lazy,
                .has_lazy = has_lazy,
                .current_row = .init,
                .started_first_row = false,
            };
        }

        pub fn free(self: *@This(), allocator: std.mem.Allocator) void {
            for (self.action_table.items) |*row| {
                row.deinit(allocator);
            }
            self.action_table.deinit(allocator);
            self.current_row.deinit(allocator);
            self.has_lazy.deinit(allocator);
            allocator.free(self.lazy);
            self.* = undefined;
        }

        pub const ActionError = std.mem.Allocator.Error || ConflictError;

        fn potentialEndOfPreviousRow(self: *@This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
            if (self.started_first_row) {
                @branchHint(.likely);
                var row = try self.current_row.endRow(allocator);
                errdefer row.deinit(allocator);
                try self.action_table.append(allocator, row);
            } else {
                self.started_first_row = true;
            }
        }
        pub fn newState(self: *@This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
            try self.potentialEndOfPreviousRow(allocator);
        }
        // Remember reduce callbacks get called prior to shift callbacks for
        // any given state.
        pub fn reduceMultiple(self: *@This(), allocator: std.mem.Allocator, terminals: std.DynamicBitSetUnmanaged, production: u32) (ActionError || ConflictResolver.Error)!void {
            const state: u32 = @intCast(self.action_table.items.len);
            var it = terminals.iterator(.{});
            const group_index: u32 = self.current_row.reduce_len;
            try self.current_row.addReduce(allocator, production, terminals);
            var won_at_least_once = false;
            while (it.next()) |terminal| {
                // Check for conflict
                var this_rule_won = true;
                if (self.has_lazy.isSet(terminal)) {
                    const existing = self.lazy[terminal];
                    if (existing.state == state) {
                        // Oops, reduce-reduce conflict!
                        const reduce_group = self.current_row.getReduce(existing.group_index);
                        if (try self.conflict_resolver.resolveReduceReduce(.{
                            self.productions.lhs[reduce_group.production],
                            self.productions.lhs[production],
                        })) |which| {
                            if (which == 1) {
                                // Replace with new reduce
                                reduce_group.lookaheads.unset(terminal);
                            } else {
                                // Retain the old reduce
                                this_rule_won = false;
                                self.current_row.getReduce(group_index).lookaheads.unset(terminal);
                            }
                        } else {
                            // Unresolved conflict
                            self.conflicting_action1 = .{ .reduce = reduce_group.production };
                            self.conflicting_action2 = .{ .reduce = production };
                            self.conflicting_lookahead = @intCast(terminal);
                            return ConflictError.LrConflict;
                        }
                    } else {
                        // Nothing to do since the lazy entry will be
                        // overwritten anyway.
                    }
                } else {
                    self.has_lazy.set(terminal);
                }
                // Update the lazy array
                if (this_rule_won) {
                    self.lazy[terminal] = .{ .state = state, .group_index = group_index };
                    won_at_least_once = true;
                }
            }
            // Small optimization: make sure the rule is not useless (empty
            // lookahead set) (removing this does not change the correctness)
            if (!won_at_least_once) {
                self.current_row.popReduce();
            }
        }
        pub fn shift(self: *@This(), allocator: std.mem.Allocator, terminal: u32, new_state: u32) (ActionError || ConflictResolver.Error)!void {
            const state: u32 = @intCast(self.action_table.items.len);
            // Check for conflict
            // The shift action does not go into the lazy array at all since
            // all shift-reduce conflicts are detected in `shift`, thanks to
            // the fact that shift calls come after reduce calls.
            var do_shift = true;
            if (self.has_lazy.isSet(terminal)) {
                const existing = self.lazy[terminal];
                if (existing.state == state) {
                    // Oops, shift-reduce conflict
                    const reduce_group = self.current_row.getReduce(existing.group_index);
                    if (try self.conflict_resolver.resolveShiftReduce(terminal, self.productions.lhs[reduce_group.production])) |x| {
                        switch (x) {
                            .shift => {
                                // Replace reduce with shift
                                reduce_group.lookaheads.unset(terminal);
                            },
                            .reduce => {
                                // Retain reduce
                                do_shift = false;
                            },
                        }
                    } else {
                        // Unresolved conflict
                        self.conflicting_action1 = .{ .shift = new_state };
                        self.conflicting_action2 = .{ .reduce = reduce_group.production };
                        self.conflicting_lookahead = terminal;
                        return ConflictError.LrConflict;
                    }
                } else { // Expired lazy entry
                    // This is optional:
                    self.has_lazy.unset(terminal);
                }
            }
            if (do_shift) {
                try self.current_row.shifts.append(allocator, .{ .terminal = terminal, .state = new_state });
            }
        }
        pub fn acceptOnEoi(self: *@This(), allocator: std.mem.Allocator) ActionError!void {
            // `state` can be anything (shifting on EOI = accept)
            return self.shift(allocator, self.symbol_spec.terminals.eoi, 0);
        }
        pub fn done(self: *@This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
            try self.potentialEndOfPreviousRow(allocator);
        }
    };
}

/// A conflict reported to the user with additional information on context
/// (i.e. core set of state). `Item` is set depending on whether it's LR(0)/SLR
/// or LR(1)/LALR. An `Action` of shifting the EOI token is treated as
/// accepting, as usual.
pub fn ReportedConflict(comptime Item: type) type {
    return struct {
        /// Owned slice
        core_set: []Item,
        /// Lookahead may be null for a reduce-reduce conflict under LR(0)
        lookahead: ?u32,
        action1: Action,
        action2: Action,

        pub fn free(self: @This(), allocator: std.mem.Allocator) void {
            allocator.free(self.core_set);
        }
    };
}

/// Generic Zig backend for SLR parsers.
pub fn SlrBackend(comptime ConflictResolver: type, comptime GotoHandler: type) type {
    return struct {
        /// Controls output of source code
        emitter: ZigEmitter,
        /// Precomputed FOLLOW sets for SLR
        follow_sets: *const lr0.DpBasedSets,
        /// Conflict resolver to forward to the action handler (borrowed)
        conflict_resolver: ConflictResolver,
        /// ACTION handler
        action_handler: ActionHandler(ConflictResolver) = undefined,
        /// GOTO handler
        goto_handler: GotoHandler,
        /// If there is a conflict, it will be logged to here.
        conflict_report: ?ReportedConflict(lr0.Item) = null,
        // Internal fields:
        /// A `states` of `null` means `beginTableGen` has not been called.
        states: ?*const std.ArrayList([]lr0.Item) = null,
        /// How many times `beginState` has been called
        state_counter: u32 = 0,
        allocator: std.mem.Allocator = undefined,
        symbol_spec: *const sym.SymbolSpec = undefined,
        productions: *const cfg.CfgProductions = undefined,

        pub fn free(self: *@This()) void {
            if (self.states == null) {
                return;
            }
            self.states = null;
            self.action_handler.free(self.allocator);
            self.goto_handler.free(self.allocator);
            if (self.conflict_report) |cr|
                cr.free(self.allocator);
        }

        pub const Error = ConflictError || std.Io.Writer.Error || std.mem.Allocator.Error || (if (ConflictResolver == void) error{} else ConflictResolver.Error);

        pub fn beginTableGen(self: *@This(), symbol_spec: *const sym.SymbolSpec, productions: *const cfg.CfgProductions, states: *const std.ArrayList([]lr0.Item), allocator: std.mem.Allocator) Error!void {
            self.states = states;
            self.allocator = allocator;
            self.symbol_spec = symbol_spec;
            self.productions = productions;
            self.action_handler = try ActionHandler(ConflictResolver).init(
                self.allocator,
                symbol_spec,
                productions,
                self.conflict_resolver,
            );
            if (std.meta.hasMethod(GotoHandler, "begin")) {
                // Optional GOTO handler initializer
                try self.goto_handler.begin(allocator, symbol_spec);
            }
        }
        pub fn beginState(self: *@This()) Error!void {
            self.state_counter += 1;
            try self.action_handler.newState(self.allocator);
            try self.goto_handler.newState(self.allocator);
        }
        pub fn goto(self: *@This(), nt: u32, state: u32) Error!void {
            try self.goto_handler.goto(self.allocator, nt, state);
        }
        fn onConflict(self: *@This()) std.mem.Allocator.Error!void {
            const copied_core_set = try self.allocator.dupe(lr0.Item, self.states.?.items[self.state_counter - 1]);
            self.conflict_report = ReportedConflict(lr0.Item){
                .action1 = self.action_handler.conflicting_action1,
                .action2 = self.action_handler.conflicting_action2,
                .core_set = copied_core_set,
                .lookahead = self.action_handler.conflicting_lookahead,
            };
        }
        pub fn acceptOnEoi(self: *@This()) Error!void {
            self.action_handler.acceptOnEoi(self.allocator) catch |err| {
                if (err == ConflictError.LrConflict) {
                    try self.onConflict();
                }
                return err;
            };
        }
        pub fn shift(self: *@This(), terminal: u32, state: u32) Error!void {
            self.action_handler.shift(self.allocator, terminal, state) catch |err| {
                if (err == ConflictError.LrConflict) {
                    try self.onConflict();
                }
                return err;
            };
        }
        pub fn reduce(self: *@This(), production: u32) Error!void {
            const nt = self.productions.lhs[production];
            const follow = self.follow_sets.get(nt);
            // Only reduce if lookahead token is in FOLLOW set of `nt`.
            self.action_handler.reduceMultiple(self.allocator, follow, production) catch |err| {
                if (err == ConflictError.LrConflict) {
                    try self.onConflict();
                }
                return err;
            };
        }
        pub fn endTableGen(self: *@This()) Error!void {
            try self.emitter.writeProlog(self.symbol_spec, self.productions);
            try self.action_handler.done(self.allocator);
            try actionTableToActionMethodPacked(self.symbol_spec, self.productions, self.action_handler.action_table, &self.emitter, self.allocator);
            try self.goto_handler.writeGotoMethod(self.allocator, &self.emitter, self.symbol_spec);
            const num_states: u32 = @intCast(self.states.?.items.len);
            try self.emitter.writeEpilog(num_states);
        }
    };
}
