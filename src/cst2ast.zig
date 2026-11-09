const std = @import("std");
const psr = @import("pgen_meta_parser");
const pgen_core = @import("pgen_core");
const ast = pgen_core.ast;
const sym = pgen_core.sym;
const diagnostic = pgen_core.diagnostic;
const cr = pgen_core.conflict_resolver;

/// Managed `ast.Ebnf` with arena allocators and `ExprPool` which holds
/// the rhs EBNF nodes. This won't work if you have multiple `ast.Ebnf`s
/// sharing a pool. The allocation is split into multiple allocators since
/// the generated artifacts can have different lifetime, particularly: the
/// AST-to-CFG stage may reuse `Nonterminals` and `Terminals` objects for CFG.
pub const EbnfManaged = struct {
    symbol_spec: sym.SymbolSpec,
    productions: ast.EbnfProductions,
    /// `sym_diagnostic` uses the `allocator` directly.
    sym_diagnostic: ?sym.DiagnosticInfo,
    /// The pool from which all `Expr`s in `productions` are interned.
    pool: ast.ExprPool,
    /// Built conflict resolver
    cr_resolver: ?cr.Resolver,
    /// The arena for `productions` and `pool`.
    expr_arena: ?*std.heap.ArenaAllocator,
    /// The arena for `symbol_spec`.
    symbol_arena: ?*std.heap.ArenaAllocator,
    /// The allocator owning the arena themselves.
    allocator: std.mem.Allocator,

    pub const SymbolSpecManaged = struct {
        symbol_spec: sym.SymbolSpec,
        arena: *std.heap.ArenaAllocator,

        /// Use the same allocator as `EbnfManaged`'s `allocator`.
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.arena.deinit();
            allocator.destroy(self.arena);
            self.* = undefined;
        }
    };

    pub fn fromCst(cst: psr.CstNode, allocator: std.mem.Allocator, scrap_allocator: std.mem.Allocator, aggregator: *diagnostic.Aggregator) (SemanticError || std.mem.Allocator.Error)!@This() {
        var expr_arena = try allocator.create(std.heap.ArenaAllocator);
        expr_arena.* = .init(allocator);
        errdefer {
            expr_arena.deinit();
            allocator.destroy(expr_arena);
        }
        var symbol_arena = try allocator.create(std.heap.ArenaAllocator);
        symbol_arena.* = .init(allocator);
        errdefer {
            symbol_arena.deinit();
            allocator.destroy(symbol_arena);
        }
        const expr_allocator = expr_arena.allocator();
        var pool: ast.ExprPool = .init(expr_allocator);
        errdefer pool.deinit(); // In fact unnecessary
        const symbol_spec, const productions, const sym_diagnostic, const cr_resolver = try cstToEbnf(
            cst,
            &pool,
            expr_allocator,
            symbol_arena.allocator(),
            allocator,
            allocator,
            scrap_allocator,
            aggregator,
        );
        return .{
            .symbol_spec = symbol_spec,
            .productions = productions,
            .sym_diagnostic = sym_diagnostic,
            .expr_arena = expr_arena,
            .symbol_arena = symbol_arena,
            .pool = pool,
            .allocator = allocator,
            .cr_resolver = cr_resolver,
        };
    }

    /// Destroys `productions` and `pool`.
    pub fn deinitExpr(self: *@This()) void {
        if (self.expr_arena) |arena| {
            self.pool.deinit(); // In fact unnecessary
            arena.deinit();
            self.allocator.destroy(arena);
            self.expr_arena = null;
            self.productions = undefined;
        }
    }

    /// Transfer `symbol_spec`'s ownership.
    pub fn ownedSymbolSpec(self: *@This()) SymbolSpecManaged {
        defer {
            self.symbol_arena = null;
            self.symbol_spec = undefined;
        }
        return .{ .arena = self.symbol_arena.?, .symbol_spec = self.symbol_spec };
    }

    /// Transfer `sym_diagnostic`'s ownership.
    pub fn ownedSymDiagnostic(self: *@This()) sym.DiagnosticInfo {
        defer self.sym_diagnostic = null;
        return self.sym_diagnostic.?;
    }

    /// Transfer `cr_resolver`'s ownership; no resolver means the grammar didn't
    /// define any conflict resolution rules.
    pub fn ownedConflictResolver(self: *@This()) ?cr.Resolver {
        if (self.cr_resolver) |x| {
            self.cr_resolver = null;
            return x;
        }
        return null;
    }

    pub fn deinit(self: *@This()) void {
        self.deinitExpr();
        if (self.symbol_arena) |arena| {
            arena.deinit();
            self.allocator.destroy(arena);
        }
        if (self.sym_diagnostic) |sd| {
            var sd_ = sd;
            sd_.deinit();
        }
        if (self.cr_resolver) |cr_resolver| {
            var cr_resolver_ = cr_resolver;
            cr_resolver_.deinit();
        }
        self.* = undefined;
    }
};

pub const SemanticError = error{
    Cst2AstSemanticError,
};

/// Convert grammar CST to intermediate EBNF form, allocating memory using
/// `expr_allocator` (for `EbnfProductions`), `symbol_allocator`
/// (for `SymbolSpec`), `sym_diagnostic_allocator` (for `DiagnosticInfo`),
/// `cr_allocator` (for conflict resolver).
/// Memory owned by CST (including tokens) are not freed or reused. It is OK
/// and encouraged to pass in arena allocators for `expr_allocator` or
/// `symbol_allocator`. On error, it is not possible to remove already-interned
/// expressions in `pool`.
pub fn cstToEbnf(
    cst: psr.CstNode,
    pool: *ast.ExprPool,
    expr_allocator: std.mem.Allocator,
    symbol_allocator: std.mem.Allocator,
    sym_diagnostic_allocator: std.mem.Allocator,
    cr_allocator: std.mem.Allocator,
    scrap_allocator: std.mem.Allocator,
    aggregator: *diagnostic.Aggregator,
) (SemanticError || std.mem.Allocator.Error)!struct { sym.SymbolSpec, ast.EbnfProductions, sym.DiagnosticInfo, ?cr.Resolver } {
    // Pass 1: Collect terminals and nonterminals
    var named_terminals_map: std.StringHashMapUnmanaged(u32) = .empty;
    defer named_terminals_map.deinit(scrap_allocator); // Strings are borrowed
    var literal_terminals_map: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(u32)) = .empty; // {suffix: {content: id}}
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

    // Entry declaration
    grammar_it.eatToken().assertTag(.@"k.entry");
    const entry_token = grammar_it.eatToken();
    entry_token.assertTag(.WORD);
    const entry_nt_string = entry_token.payload.word;
    grammar_it.eatToken().assertTag(.@".;");

    // Precedence and priority blocks
    // We save them to convert later since we need the terminals/nonterminals
    // to be labelled before we can understand the precedence/priority rules.
    var precedence_state: ?psr.NtChildrenIterator.State = null;
    var priority_state: ?psr.NtChildrenIterator.State = null;
    while (grammar_it.peek().?.* == .leaf) {
        switch (grammar_it.eatToken().tag) {
            .@"k.precedence" => {
                grammar_it.eatToken().assertTag(.@".{");
                precedence_state = grammar_it.saveState();
                // Skip all internal nodes plus one more node (the @".}")
                while (grammar_it.eat().* == .internal) {}
            },
            .@"k.priority" => {
                grammar_it.eatToken().assertTag(.@".{");
                priority_state = grammar_it.saveState();
                while (grammar_it.eat().* == .internal) {}
            },
            else => unreachable,
        }
    }

    // Production list
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
    // Label nonterminals
    var node_forming_nt_names = try symbol_allocator.alloc([]u8, node_forming_nt_count);
    // Fill with empty slice to allow errdefer to clean up.
    @memset(node_forming_nt_names, &[0]u8{});
    errdefer {
        for (node_forming_nt_names) |name|
            symbol_allocator.free(name);
        symbol_allocator.free(node_forming_nt_names);
    }
    var sym_diagnostic = try sym.DiagnosticInfo.init(sym_diagnostic_allocator, nonterminal_count - node_forming_nt_count);
    errdefer sym_diagnostic.deinit();
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
                node_forming_nt_names[id] = try symbol_allocator.dupe(u8, entry.key_ptr.*);
            } else {
                sym_diagnostic.nodeless_nt_names[id - node_forming_nt_count] = try sym_diagnostic_allocator.dupe(u8, entry.key_ptr.*);
            }
            id_ptr.* += 1;
        }
        std.debug.assert(ids[0] == node_forming_nt_count);
        std.debug.assert(ids[1] == nonterminal_count);
    }
    // Resolve entry
    const entry_nt = nonterminals_map.get(entry_nt_string) orelse {
        return fatalAt(
            aggregator,
            entry_token,
            "specified entry nonterminal '{s}' is undefined",
            .{entry_nt_string},
        );
    };
    if (entry_nt >= node_forming_nt_count) {
        return fatalAt(
            aggregator,
            entry_token,
            "entry nonterminal must not be 'nodeless'",
            .{},
        );
    }
    // Label literal terminals
    var terminal_id: u32 = 0;
    var literal_collections = try symbol_allocator.alloc(sym.LiteralCollection, literal_terminals_map.size);
    var literal_terminal_i: u32 = 0;
    errdefer {
        for (literal_collections[0..literal_terminal_i]) |collection| {
            // `collection` must be a completely-built collection
            symbol_allocator.free(collection.suffix);
            for (collection.literals) |literal|
                symbol_allocator.free(literal);
            symbol_allocator.free(collection.literals);
        }
        symbol_allocator.free(literal_collections);
    }
    {
        var it = literal_terminals_map.iterator();
        while (it.next()) |entry| {
            const collection = &literal_collections[literal_terminal_i];
            collection.suffix = try symbol_allocator.dupe(u8, entry.key_ptr.*);
            errdefer symbol_allocator.free(collection.suffix);
            const map = entry.value_ptr.*;
            const literals = try symbol_allocator.alloc([]u8, map.size);
            collection.literals = literals;
            var literal_terminal_j: u32 = 0;
            errdefer {
                for (literals[0..literal_terminal_j]) |literal|
                    symbol_allocator.free(literal);
                symbol_allocator.free(literals);
            }
            var it2 = map.iterator();
            while (it2.next()) |entry2| {
                literals[literal_terminal_j] = try symbol_allocator.dupe(u8, entry2.key_ptr.*);
                literal_terminal_j += 1;
                entry2.value_ptr.* = terminal_id;
                terminal_id += 1;
            }
            literal_terminal_i += 1;
        }
    }
    // Label named terminals
    const named_terminals = try symbol_allocator.alloc([]u8, named_terminals_map.size);
    var named_terminals_i: u32 = 0;
    errdefer {
        for (named_terminals[0..named_terminals_i]) |slice|
            symbol_allocator.free(slice);
        symbol_allocator.free(named_terminals);
    }
    {
        var it = named_terminals_map.iterator();
        while (it.next()) |entry| {
            named_terminals[named_terminals_i] = try symbol_allocator.dupe(u8, entry.key_ptr.*);
            named_terminals_i += 1;
            entry.value_ptr.* = terminal_id;
            terminal_id += 1;
        }
    }

    // Create `SymbolManager` now that everything is labelled
    const symbol_manager: SymbolManager = .{
        .named_terminals_map = &named_terminals_map,
        .literal_terminals_map = &literal_terminals_map,
        .nonterminals_map = &nonterminals_map,
    };

    // Resolve precedence block
    var cr_sr_map = if (precedence_state) |target_state| precedence_block: {
        var cr_sr_builder: cr.ShiftReduceBuilder = .init(aggregator, cr_allocator);
        defer cr_sr_builder.deinit();
        grammar_it.loadState(target_state);
        while (true) {
            const node = grammar_it.eat();
            if (node.* == .leaf) {
                node.leaf.assertTag(.@".}");
                break;
            }
            var it = node.internal.iteratorOf(.precedence_decl);
            const nt_token = it.eatToken();
            nt_token.assertTag(.WORD);
            const nt = switch (try symbol_manager.resolveWordToken(nt_token, aggregator)) {
                .terminal => return fatalAt(
                    aggregator,
                    nt_token,
                    "precedence left hand side must be a nonterminal; '{s}' is a terminal",
                    .{nt_token.payload.word},
                ),
                .nonterminal => |nt| nt,
            };
            const rel_token = it.eatToken();
            const rel: cr.ShiftReduceDecision = switch (rel_token.tag) {
                .@".>" => .reduce,
                .@".<" => .shift,
                else => unreachable,
            };
            const terminal_token = it.eatToken();
            const terminal = switch (terminal_token.tag) {
                .WORD => switch (try symbol_manager.resolveWordToken(terminal_token, aggregator)) {
                    .terminal => |tid| tid,
                    .nonterminal => return fatalAt(
                        aggregator,
                        terminal_token,
                        "precedence right hand side must be a terminal; '{s}' is nonterminal",
                        .{terminal_token.payload.word},
                    ),
                },
                .STRING => symbol_manager.resolveLiteralToken(terminal_token) orelse return fatalAt(
                    aggregator,
                    terminal_token,
                    // TODO: stringify the literal token
                    "literal token is never used in any production",
                    .{},
                ),
                else => unreachable,
            };
            cr_sr_builder.addRule(nt, terminal, rel) catch |err| return switch (err) {
                error.InvalidConflictResolveRule => SemanticError.Cst2AstSemanticError,
                else => |e| e,
            };
        }
        break :precedence_block cr_sr_builder.retrieve();
    } else cr.ShiftReduceMap.init(cr_allocator);
    errdefer cr_sr_map.deinit();

    // Resolve priority block
    const cr_rr_resolver = if (priority_state) |target_state| priority_block: {
        // Optimization: empty priority block is same as no priority block
        grammar_it.loadState(target_state);
        if (grammar_it.peek().?.isToken(.@".}")) {
            break :priority_block null;
        }
        var cr_rr_builder = try cr.ReduceReduceBuilder.init(nonterminal_count, aggregator, cr_allocator);
        defer cr_rr_builder.deinit();
        while (true) {
            const node = grammar_it.eat();
            if (node.* == .leaf) {
                node.leaf.assertTag(.@".}");
                break;
            }
            var it = node.internal.iteratorOf(.priority_decl);
            const first_word = it.eatToken();
            first_word.assertTag(.WORD);
            var lhs = switch (try symbol_manager.resolveWordToken(first_word, aggregator)) {
                .terminal => return fatalAt(
                    aggregator,
                    first_word,
                    "priority operand must be a nonterminal; '{s}' is a terminal",
                    .{first_word.payload.word},
                ),
                .nonterminal => |nt| nt,
            };
            const rel: enum { lt, gt } = switch (it.peek().?.leaf.tag) {
                .@".<" => .lt,
                .@".>" => .gt,
                else => unreachable,
            };
            // All later operators are the same per the grammar (either all >
            // or all <)
            while (it.eatToken().tag != .@".;") {
                const word = it.eatToken();
                word.assertTag(.WORD);
                const rhs = switch (try symbol_manager.resolveWordToken(word, aggregator)) {
                    .terminal => return fatalAt(
                        aggregator,
                        word,
                        "priority operand must be a nonterminal; '{s}' is a terminal",
                        .{word.payload.word},
                    ),
                    .nonterminal => |nt| nt,
                };
                (switch (rel) {
                    .lt => cr_rr_builder.addGreaterThan(rhs, lhs),
                    .gt => cr_rr_builder.addGreaterThan(lhs, rhs),
                }) catch |err| return switch (err) {
                    error.InvalidConflictResolveRule => SemanticError.Cst2AstSemanticError,
                    else => |e| e,
                };
                lhs = rhs; // Current RHS is next relation's LHS
            }
        }
        break :priority_block cr_rr_builder.retrieve() catch |err| return switch (err) {
            error.InvalidConflictResolveRule => SemanticError.Cst2AstSemanticError,
            else => |e| e,
        };
    } else null;
    errdefer {
        if (cr_rr_resolver) |x| {
            var x_var = x;
            x_var.deinit();
        }
    }

    // Pass 2: Productions
    var productions = try expr_allocator.alloc(*const ast.Expr, nonterminal_count);
    errdefer expr_allocator.free(productions);
    grammar_it.loadState(grammar_it_production_start);
    const converter: CstRhsToAst = .{
        .symbol_manager = &symbol_manager,
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
    // A resolver object is not needed at all if both precedence and priority
    // blocks are empty.
    const conflict_resolver = if (cr_sr_map.capacity() == 0 and cr_rr_resolver == null) null else cr.Resolver{
        .sr = cr_sr_map,
        .rr = cr_rr_resolver,
        .relabeling = null,
        .relabeling_allocator = cr_allocator,
    };
    return .{ sym.SymbolSpec{
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
    }, productions.ptr, sym_diagnostic, conflict_resolver };
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

// Manages terminals/nonterminals during cst2ast.
const SymbolManager = struct {
    named_terminals_map: *const std.StringHashMapUnmanaged(u32),
    literal_terminals_map: *const std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(u32)),
    nonterminals_map: *const std.StringHashMapUnmanaged(u32),

    pub const ResolvedId = union(enum) {
        terminal: u32,
        nonterminal: u32,
    };

    /// Resolve an identifier
    pub fn resolveId(self: @This(), id: []const u8) ?ResolvedId {
        if (self.nonterminals_map.get(id)) |nt| {
            return .{ .nonterminal = nt };
        } else if (self.named_terminals_map.get(id)) |tid| {
            return .{ .terminal = tid };
        } else {
            return null;
        }
    }

    /// Resolve an identifier that appeared in source grammar (with a given
    /// `WORD` token). Log an error if identifier is undefined.
    pub fn resolveWordToken(self: @This(), token: *const psr.Token, aggregator: *diagnostic.Aggregator) SemanticError!ResolvedId {
        return self.resolveId(token.payload.word) orelse fatalAt(
            aggregator,
            token,
            "undefined identifier '{s}'",
            .{token.payload.word},
        );
    }

    /// Resolve a literal token (suffixed string); return terminal ID
    pub fn resolveLiteral(self: @This(), content: []const u8, suffix: []const u8) ?u32 {
        if (self.literal_terminals_map.get(suffix)) |hashmap| {
            if (hashmap.get(content)) |tid| {
                return tid;
            }
        }
        return null;
    }

    pub fn resolveLiteralToken(self: @This(), token: *const psr.Token) ?u32 {
        return self.resolveLiteral(token.payload.str.content, token.payload.str.suffix);
    }
};

const CstRhsToAst = struct {
    symbol_manager: *const SymbolManager,
    pool: *ast.ExprPool,
    aggregator: *diagnostic.Aggregator,

    pub const Error = std.mem.Allocator.Error || SemanticError;

    pub fn rhs(self: @This(), node: psr.NonterminalExpansion) Error!*const ast.Expr {
        const n_operands = @shrExact(node.children.len + 1, 1);
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
                // We did not check for undefined identifier in 1st Pass.
                return switch (try self.symbol_manager.resolveWordToken(first, self.aggregator)) {
                    .terminal => |tid| self.pool.makeTerminal(tid),
                    .nonterminal => |nt| self.pool.makeNonterminal(nt),
                };
            },
            .STRING => {
                std.debug.assert(it.done());
                // All literal tokens used are automatically defined, so
                // the lookup must succeed.
                return self.pool.makeTerminal(self.symbol_manager.resolveLiteralToken(first).?);
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
