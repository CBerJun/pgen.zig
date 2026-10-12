const std = @import("std");
const psr = @import("pgen_meta_parser");
const pgen_core = @import("pgen_core");
const ast = pgen_core.ast;
const cfg = pgen_core.cfg;
const diagnostic = pgen_core.diagnostic;

/// Managed `ast.Ebnf` with an arena allocator and `ExprPool` which holds
/// the rhs EBNF nodes. This won't work if you have multiple `ast.Ebnf`s
/// sharing a pool.
pub const EbnfManaged = struct {
    /// The unmanaged `ast.Ebnf`.
    ebnf: ast.Ebnf,
    /// The arena from which all memory owned by `ebnf` and `pool` is
    /// allocated from.
    arena: std.heap.ArenaAllocator,
    /// The pool from which all `Expr`s in `productions` are interned.
    pool: ast.ExprPool,

    pub fn fromCst(cst: psr.CstNode, allocator: std.mem.Allocator, scrap_allocator: std.mem.Allocator, aggregator: *diagnostic.Aggregator) (SemanticError || std.mem.Allocator.Error)!@This() {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();
        var pool: ast.ExprPool = .init(arena_allocator);
        return .{
            .ebnf = try cstToEbnf(cst, &pool, arena_allocator, scrap_allocator, aggregator),
            .arena = arena,
            .pool = pool,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.pool.deinit(); // In fact unnecessary
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const SemanticError = error{
    Cst2AstSemanticError,
};

/// Convert grammar CST to intermediate EBNF form, allocating memory for
/// the `ast.Ebnf` using `allocator`. Memory owned by CST (including tokens)
/// are not freed or reused. It is OK and encouraged to pass in an arena
/// allocator for `allocator`, as all memory owned by `ast.Ebnf` probably share
/// the same lifespan; just remember to deinit arena on error. Do not pass in
/// an arena for `scrap_allocator`. On error, it is not possible to remove
/// already-interned expressions in `pool`.
pub fn cstToEbnf(cst: psr.CstNode, pool: *ast.ExprPool, allocator: std.mem.Allocator, scrap_allocator: std.mem.Allocator, aggregator: *diagnostic.Aggregator) (SemanticError || std.mem.Allocator.Error)!ast.Ebnf {
    // Pass 1: Label terminals and nonterminals with integers
    var named_terminals_map: std.StringHashMapUnmanaged(u32) = .empty;
    defer named_terminals_map.deinit(scrap_allocator); // Strings are borrowed
    var literal_terminals_map: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(u32)) = .empty;
    defer {
        var it = literal_terminals_map.valueIterator();
        while (it.next()) |m|
            m.deinit(scrap_allocator);
        literal_terminals_map.deinit(scrap_allocator);
    }
    var nonterminals_map: std.StringHashMapUnmanaged(u32) = .empty;
    defer nonterminals_map.deinit(scrap_allocator);
    var grammar_it = cst.internal.iteratorOf(.grammar);
    grammar_it.eatToken().assertTag(.@"k.tokens");
    grammar_it.eatToken().assertTag(.@".{");
    while (!grammar_it.peek().?.isToken(.@".}")) {
        var token_decl_it = grammar_it.eatNt().iteratorOf(.token_decl);
        const word_or_str = token_decl_it.eatToken();
        token_decl_it.eatToken().assertTag(.@".;");
        std.debug.assert(token_decl_it.done());
        switch (word_or_str.tag) {
            .WORD => {
                const id = word_or_str.payload.word;
                const gop = try named_terminals_map.getOrPut(scrap_allocator, id);
                if (gop.found_existing) {
                    return fatalAt(
                        aggregator,
                        word_or_str,
                        "duplicate declaration of named token '{s}'",
                        .{id},
                    );
                }
            },
            .STRING => {
                const s = word_or_str.payload.str;
                if (s.content.len > 0)
                    return fatalAt(
                        aggregator,
                        word_or_str,
                        "literal token definition string must be empty (like this: \"\"{s})",
                        .{s.suffix},
                    );
                const gop = try literal_terminals_map.getOrPut(scrap_allocator, s.suffix);
                if (gop.found_existing)
                    return fatalAt(
                        aggregator,
                        word_or_str,
                        "duplicate declaration of literal token suffix \"\"{s}",
                        .{s.suffix},
                    );
                gop.value_ptr.* = .empty;
            },
            else => unreachable,
        }
    }
    grammar_it.eatToken().assertTag(.@".}");
    grammar_it.eatToken().assertTag(.@"k.entry");
    const entry_token = grammar_it.eatToken();
    entry_token.assertTag(.WORD);
    const entry_nt_string = entry_token.payload.word;
    grammar_it.eatToken().assertTag(.@".;");
    const grammar_it_production_start = grammar_it.saveState();
    var node_forming_nt_count: u32 = 0;
    while (grammar_it.next()) |production_node| {
        var production_it = production_node.internal.iteratorOf(.production);
        const qualifier_node = production_it.eatNt();
        var nodeless = false;
        for (qualifier_node.children) |q| {
            if (q.isToken(.@"k.nodeless")) {
                nodeless = true;
            } else unreachable;
        }
        const nt_token = production_it.eatToken();
        nt_token.assertTag(.WORD);
        const nt_string = nt_token.payload.word;
        if (named_terminals_map.contains(nt_string))
            return fatalAt(
                aggregator,
                nt_token,
                "nonterminal name '{s}' shadows the named terminal with the same name",
                .{nt_string},
            );
        const gop = try nonterminals_map.getOrPut(scrap_allocator, nt_string);
        if (gop.found_existing)
            return fatalAt(
                aggregator,
                nt_token,
                "duplicate definition of nonterminal '{s}'",
                .{nt_string},
            );
        // Temporarily store `nodeless` as hashmap value
        gop.value_ptr.* = @intFromBool(nodeless);
        node_forming_nt_count += @intFromBool(!nodeless);
        production_it.eatToken().assertTag(.@".:");
        const rhs = production_it.eatNt();
        production_it.eatToken().assertTag(.@".;");
        std.debug.assert(production_it.done());
        // Pass 1 expression DFS. Just collect possible values for literal
        // tokens.
        var stack: std.ArrayList(*psr.NonterminalExpansion) = .empty;
        defer stack.deinit(scrap_allocator);
        try stack.append(scrap_allocator, rhs);
        while (stack.pop()) |nt_expansion| {
            var it = nt_expansion.iterator();
            switch (nt_expansion.nonterminal) {
                .rhs => {
                    try stack.append(scrap_allocator, it.eatNt());
                    while (!it.done()) {
                        it.eatToken().assertTag(.@".|");
                        try stack.append(scrap_allocator, it.eatNt());
                    }
                },
                .rhs_factor => {
                    if (it.peek().?.* == .internal) {
                        while (it.next()) |term|
                            try stack.append(scrap_allocator, &term.internal);
                    } else {
                        it.eatToken().assertTag(.@"k.epsilon");
                    }
                },
                .rhs_term => {
                    try stack.append(scrap_allocator, it.eatNt());
                    // Following are semantically useless (for assertion only)
                    if (it.next()) |second| {
                        const tag = second.leaf.tag;
                        std.debug.assert(tag == .@".+" or tag == .@".*");
                    }
                },
                .rhs_atom => {
                    const first = it.eatToken();
                    switch (first.tag) {
                        .WORD => {
                            // We will check if identifier is defined in Pass 2
                        },
                        .STRING => {
                            // Register literal token
                            const s = first.payload.str;
                            if (literal_terminals_map.getPtr(s.suffix)) |map| {
                                if (s.content.len == 0)
                                    return fatalAt(
                                        aggregator,
                                        first,
                                        "literal token value may not be empty",
                                        .{},
                                    );
                                _ = try map.getOrPut(scrap_allocator, s.content);
                            } else {
                                return fatalAt(
                                    aggregator,
                                    first,
                                    "undeclared literal token suffix (add '\"\"{s};' to 'tokens' section)",
                                    .{s.suffix},
                                );
                            }
                        },
                        .@".(" => {
                            try stack.append(scrap_allocator, it.eatNt());
                            it.eatToken().assertTag(.@".)");
                        },
                        .@".[" => {
                            try stack.append(scrap_allocator, it.eatNt());
                            it.eatToken().assertTag(.@".]");
                        },
                        else => unreachable,
                    }
                },
                else => unreachable,
            }
            std.debug.assert(it.done());
        }
    }
    const nonterminal_count = nonterminals_map.size;
    // Resolve entry
    const entry_nt = nonterminals_map.get(entry_nt_string) orelse {
        return fatalAt(
            aggregator,
            entry_token,
            "specified entry nonterminal '{s}' is undefined",
            .{entry_nt_string},
        );
    };
    // Label nonterminals
    var node_forming_nt_names = try allocator.alloc([]u8, node_forming_nt_count);
    // Fill with empty slice to allow errdefer to clean up.
    @memset(node_forming_nt_names, &[0]u8{});
    errdefer {
        for (node_forming_nt_names) |name|
            allocator.free(name);
        allocator.free(node_forming_nt_names);
    }
    {
        var ids: [2]u32 = .{ 0, node_forming_nt_count };
        var it = nonterminals_map.iterator();
        while (it.next()) |entry| {
            // Remember `nonterminals_map` values store
            // `@intFromBool(nodeless)`.
            const id_ptr = &ids[entry.value_ptr.*];
            const id = id_ptr.*;
            entry.value_ptr.* = id;
            if (id < node_forming_nt_count) {
                node_forming_nt_names[id] = try allocator.dupe(u8, entry.key_ptr.*);
            }
            id_ptr.* += 1;
        }
        std.debug.assert(ids[0] == node_forming_nt_count);
        std.debug.assert(ids[1] == nonterminal_count);
    }
    // Label literal terminals
    var terminal_id: u32 = 0;
    var literal_collections = try allocator.alloc(cfg.LiteralCollection, literal_terminals_map.size);
    var literal_terminal_i: u32 = 0;
    errdefer {
        for (literal_collections[0..literal_terminal_i]) |collection| {
            // `collection` must be a completely-built collection
            allocator.free(collection.suffix);
            for (collection.literals) |literal|
                allocator.free(literal);
            allocator.free(collection.literals);
        }
        allocator.free(literal_collections);
    }
    {
        var it = literal_terminals_map.iterator();
        while (it.next()) |entry| {
            const collection = &literal_collections[literal_terminal_i];
            collection.suffix = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(collection.suffix);
            const map = entry.value_ptr.*;
            const literals = try allocator.alloc([]u8, map.size);
            collection.literals = literals;
            var literal_terminal_j: u32 = 0;
            errdefer {
                for (literals[0..literal_terminal_j]) |literal|
                    allocator.free(literal);
                allocator.free(literals);
            }
            var it2 = map.iterator();
            while (it2.next()) |entry2| {
                literals[literal_terminal_j] = try allocator.dupe(u8, entry2.key_ptr.*);
                literal_terminal_j += 1;
                entry2.value_ptr.* = terminal_id;
                terminal_id += 1;
            }
            literal_terminal_i += 1;
        }
    }
    // Label named terminals
    const named_terminals = try allocator.alloc([]u8, named_terminals_map.size);
    var named_terminals_i: u32 = 0;
    errdefer {
        for (named_terminals[0..named_terminals_i]) |slice|
            allocator.free(slice);
        allocator.free(named_terminals);
    }
    {
        var it = named_terminals_map.iterator();
        while (it.next()) |entry| {
            named_terminals[named_terminals_i] = try allocator.dupe(u8, entry.key_ptr.*);
            named_terminals_i += 1;
            entry.value_ptr.* = terminal_id;
            terminal_id += 1;
        }
    }
    // Pass 2: Productions
    var productions = try allocator.alloc(*const ast.Expr, nonterminal_count);
    errdefer allocator.free(productions);
    grammar_it.loadState(grammar_it_production_start);
    const converter: CstRhsToAst = .{
        .named_terminals_map = &named_terminals_map,
        .literal_terminals_map = &literal_terminals_map,
        .nonterminals_map = &nonterminals_map,
        .pool = pool,
        .aggregator = aggregator,
    };
    while (grammar_it.next()) |production_node| {
        var production_it = production_node.internal.iteratorOf(.production);
        std.debug.assert(production_it.eatNt().nonterminal == .nonterminal_qualifier);
        const nt_token = production_it.eatToken();
        nt_token.assertTag(.WORD);
        const nt_string = nt_token.payload.word;
        production_it.eatToken().assertTag(.@".:");
        const rhs = production_it.eatNt().*;
        production_it.eatToken().assertTag(.@".;");
        std.debug.assert(production_it.done());
        const nt = nonterminals_map.get(nt_string).?;
        productions[nt] = try converter.rhs(rhs);
    }
    return .{
        .terminals = .{
            .eoi = terminal_id,
            .count = terminal_id + 1,
            .named = named_terminals,
            .literal = literal_collections,
        },
        .nonterminals = .{
            .entry = entry_nt,
            .count = nonterminal_count,
            .node_forming_count = node_forming_nt_count,
            .names = node_forming_nt_names.ptr,
        },
        .productions = productions.ptr,
    };
}

/// Convenience function for `cstToEbnf`.
fn fatal(aggregator: *diagnostic.Aggregator, comptime fmt: []const u8, args: anytype) SemanticError {
    aggregator.add(.fatal, fmt, args);
    return SemanticError.Cst2AstSemanticError;
}

/// Convenience function for `cstToEbnf`.
fn fatalAt(aggregator: *diagnostic.Aggregator, token: *const psr.Token, comptime fmt: []const u8, args: anytype) SemanticError {
    return fatal(aggregator, "at line {} column {}: " ++ fmt, .{
        // 0-indexed to 1-indexed
        token.loc.ln + 1, token.loc.col + 1,
    } ++ args);
}

const CstRhsToAst = struct {
    named_terminals_map: *const std.StringHashMapUnmanaged(u32),
    literal_terminals_map: *const std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(u32)),
    nonterminals_map: *const std.StringHashMapUnmanaged(u32),
    pool: *ast.ExprPool,
    aggregator: *diagnostic.Aggregator,

    pub const Error = std.mem.Allocator.Error || SemanticError;

    pub fn rhs(self: @This(), node: psr.NonterminalExpansion) Error!*const ast.Expr {
        const n_operands = (node.children.len + 1) >> 1;
        var operands = try self.pool.allocator.alloc(*const ast.Expr, n_operands);
        var i: usize = 1;
        defer if (i < n_operands) self.pool.allocator.free(operands);
        var it = node.iteratorOf(.rhs);
        operands[0] = try self.rhsFactor(it.eatNt().*);
        while (!it.done()) {
            it.eatToken().assertTag(.@".|");
            operands[i] = try self.rhsFactor(it.eatNt().*);
            i += 1;
        }
        std.debug.assert(i == n_operands);
        return self.pool.makeChoose(operands);
    }

    pub fn rhsFactor(self: @This(), node: psr.NonterminalExpansion) Error!*const ast.Expr {
        var it = node.iteratorOf(.rhs_factor);
        if (it.peek().?.* == .internal) {
            const n_operands = node.children.len;
            var operands = try self.pool.allocator.alloc(*const ast.Expr, n_operands);
            var i: usize = 0;
            defer if (i < n_operands) self.pool.allocator.free(operands);
            while (it.next()) |rhs_term| {
                operands[i] = try self.rhsTerm(rhs_term.internal);
                i += 1;
            }
            std.debug.assert(i == n_operands);
            return self.pool.makeConcat(operands);
        } else {
            it.eatToken().assertTag(.@"k.epsilon");
            std.debug.assert(it.done());
            return self.pool.makeEpsilon();
        }
    }

    pub fn rhsTerm(self: @This(), node: psr.NonterminalExpansion) Error!*const ast.Expr {
        var it = node.iteratorOf(.rhs_term);
        const operand = try self.rhsAtom(it.eatNt().*);
        if (it.done())
            return operand;
        const modifier_token = it.eatToken();
        std.debug.assert(it.done());
        return switch (modifier_token.tag) {
            .@".+" => self.pool.makeOneOrMore(operand),
            .@".*" => self.pool.makeZeroOrMore(operand),
            else => unreachable,
        };
    }

    pub fn rhsAtom(self: @This(), node: psr.NonterminalExpansion) Error!*const ast.Expr {
        var it = node.iteratorOf(.rhs_atom);
        const first = it.eatToken();
        switch (first.tag) {
            .WORD => {
                std.debug.assert(it.done());
                const word = first.payload.word;
                if (self.nonterminals_map.get(word)) |nt| {
                    return self.pool.makeNonterminal(nt);
                } else if (self.named_terminals_map.get(word)) |tid| {
                    return self.pool.makeTerminal(tid);
                } else {
                    // We did not check for this in 1st Pass.
                    return fatalAt(
                        self.aggregator,
                        first,
                        "undefined identifier '{s}'",
                        .{word},
                    );
                }
            },
            .STRING => {
                std.debug.assert(it.done());
                const s = first.payload.str;
                const tid = self.literal_terminals_map.get(s.suffix).?.get(s.content).?;
                return self.pool.makeTerminal(tid);
            },
            .@".(" => {
                const inner = it.eatNt().*;
                it.eatToken().assertTag(.@".)");
                std.debug.assert(it.done());
                return self.rhs(inner);
            },
            .@".[" => {
                const inner = it.eatNt().*;
                it.eatToken().assertTag(.@".]");
                std.debug.assert(it.done());
                return self.pool.makeOptional(try self.rhs(inner));
            },
            else => unreachable,
        }
    }
};
