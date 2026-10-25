//! LR(0) and SLR related algorithms

const std = @import("std");
const digraph = @import("./digraph.zig");
const cfg = @import("./cfg.zig");
const sym = @import("./sym.zig");

/// Graph of nonterminals.
/// Edge u -> v iff there is a production for u starting with v. This
/// graph can contain self loops and parallel edges, though parallel
/// edges are redundant (the number don't have to reflect how many such
/// productions exist)
pub fn firstGraph(symbol_spec: sym.SymbolSpec, productions: cfg.CfgProductions, allocator: std.mem.Allocator) std.mem.Allocator.Error!digraph.Digraph {
    const graph: digraph.Digraph = try .empty(symbol_spec.nonterminals.count, allocator);
    errdefer graph.free(allocator);

    for (0..symbol_spec.nonterminals.count) |nt| {
        var succ: std.ArrayList(u32) = .empty;
        errdefer succ.deinit(allocator);

        for (productions.productionsOf(symbol_spec, @intCast(nt))) |rhs| {
            if (rhs.len > 0) {
                switch (rhs[0]) {
                    .nonterminal => |x| try succ.append(allocator, x),
                    .terminal => {},
                }
            }
        }
        graph.succ[nt] = try succ.toOwnedSlice(allocator);
    }
    return graph;
}

pub const DefUse = struct {
    /// `uses[i]` is list of production IDs that contain nonterminal `i`.
    /// Duplicate indicates multiple occurrences of same nonterminal.
    uses: []std.ArrayList(u32),

    pub fn free(self: @This(), allocator: std.mem.Allocator) void {
        for (self.uses) |*list| {
            list.deinit(allocator);
        }
        allocator.free(self.uses);
    }

    pub fn fromCfg(symbol_spec: sym.SymbolSpec, productions: cfg.CfgProductions, allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        const result = @This(){ .uses = try allocator.alloc(std.ArrayList(u32), symbol_spec.nonterminals.count) };
        for (result.uses) |*list| {
            list.* = .empty;
        }
        errdefer result.free(allocator);
        for (0..symbol_spec.nonterminals.count) |nt_l| {
            var prod_index = productions.production_pact[nt_l];
            const prod_end = productions.productionEndIndexOf(symbol_spec, @intCast(nt_l));
            while (prod_index < prod_end) : (prod_index += 1) {
                for (productions.productions[prod_index]) |symbol| {
                    switch (symbol) {
                        .nonterminal => |nt_r| try result.uses[nt_r].append(allocator, prod_index),
                        .terminal => {},
                    }
                }
            }
        }
        return result;
    }
};

/// Compute if each nonterminal can derive epsilon. Relies on a valid `DefUse`.
pub fn nullableAnalysis(symbol_spec: sym.SymbolSpec, productions: cfg.CfgProductions, def_use: DefUse, allocator: std.mem.Allocator) std.mem.Allocator.Error!std.DynamicBitSetUnmanaged {
    // We shall use a method similar to topological sort.
    // Maintain a counter for each production, initially set to the
    // number of symbols on RHS.
    // While there is some rhs with count=0:
    //   Mark the lhs of that production as nullable
    //   For all productions that use this lhs on their rhs, subtract
    //   from their counter the number of occurrences of this lhs
    var nullable: std.DynamicBitSetUnmanaged = try .initEmpty(allocator, symbol_spec.nonterminals.count);
    errdefer nullable.deinit(allocator);

    var count = try allocator.alloc(u32, productions.total_productions);
    defer allocator.free(count);
    // Initialize count to number of symbols on RHS for each production
    for (0..productions.total_productions) |i| {
        count[i] = @intCast(productions.productions[i].len);
    }

    var work_list: std.ArrayList(u32) = .empty;
    defer work_list.deinit(allocator);

    for (0..symbol_spec.nonterminals.count) |nt| {
        for (productions.productionsOf(symbol_spec, @intCast(nt))) |rhs| {
            if (rhs.len == 0) {
                nullable.set(nt);
                try work_list.append(allocator, @intCast(nt));
                break;
            }
        }
    }

    while (work_list.pop()) |nt| {
        for (def_use.uses[nt].items) |prod_index| {
            const lhs = productions.production_lhs[prod_index];
            if (nullable.isSet(lhs)) { // Already nullable
                continue;
            }
            count[prod_index] -= 1;
            if (count[prod_index] == 0) {
                nullable.set(lhs);
                try work_list.append(allocator, lhs);
            }
        }
    }

    return nullable;
}

/// Compute FIRST set for each node.
/// For each production
///   X -> a_1 a_2 ... a_k
/// If a_1 is term then a_1 is in FIRST(X), otherwise FIRST(X) includes
/// FIRST(a_1). If a_1 is a nullable non-term, then keep checking a_2 in
/// the same way. This can keep going until a_k is done.
/// In practice, we build a digraph with non terms as nodes. There is an
/// edge u -> v iff FIRST(u) should include FIRST(v) due to the above
/// reasoning. We also track a set T[u] for each node u, which is the set
/// of all terminals that should be included in FIRST(u) due to the above
/// reasoning (getting a terminal in the production for u).
/// Now FIRST(u) = union(T[x] for all x reachable from u in the digraph)
/// We can compute this efficiently by running an SCC. Notice that all
/// nodes in the same SCC have the same FIRST set. Now process the
/// condensation graph in reverse topological order, setting dp(p) to be
///   union(union(T[x] for x in all nodes in SCC p),
///         union(dp(q) for q in all successor SCCs of p))
/// Now FIRST(u) is just dp(the SCC that u is in).
pub fn firstSet(symbol_spec: sym.SymbolSpec, productions: cfg.CfgProductions, nullable: std.DynamicBitSetUnmanaged, allocator: std.mem.Allocator) std.mem.Allocator.Error!DpBasedSets {
    const graph: digraph.Digraph = try .empty(symbol_spec.nonterminals.count, allocator);
    defer graph.free(allocator);

    const T = try allocator.alloc(std.DynamicBitSetUnmanaged, symbol_spec.nonterminals.count);
    defer allocator.free(T);
    var i: u32 = 0;
    defer {
        while (i > 0) : (i -= 1) {
            T[i - 1].deinit(allocator);
        }
    }
    while (i < symbol_spec.nonterminals.count) : (i += 1) {
        T[i] = try std.DynamicBitSetUnmanaged.initEmpty(allocator, symbol_spec.terminals.count);
    }

    for (0..symbol_spec.nonterminals.count) |u| {
        var succ: std.ArrayList(u32) = .empty; // Successors of `u` in `graph`
        errdefer succ.deinit(allocator);

        for (productions.productionsOf(symbol_spec, @intCast(u))) |rhs| {
            for (rhs) |symbol| {
                switch (symbol) {
                    .terminal => |tid| {
                        T[u].set(tid);
                        break;
                    },
                    .nonterminal => |v| {
                        try succ.append(allocator, v);
                        if (!nullable.isSet(v)) {
                            break;
                        }
                    },
                }
            }
        }

        graph.succ[u] = try succ.toOwnedSlice(allocator);
    }

    const tarjan = try graph.tarjanScc(allocator);
    errdefer tarjan.free(allocator);

    const dp = try graph.reachDp(T.ptr, symbol_spec.terminals.count, tarjan, allocator);
    return .{
        .tarjan = tarjan,
        .dp = dp,
    };
}

/// Encapsulates precomputed FIRST and FOLLOW sets
pub const DpBasedSets = struct {
    // These members are owned
    tarjan: digraph.TarjanSccResult,
    dp: digraph.ReachDpResult,

    /// Get the set (as a bitset) associated with node `u`.
    pub fn get(self: @This(), u: u32) std.DynamicBitSetUnmanaged {
        return self.dp.get(u, self.tarjan);
    }

    pub fn free(self: @This(), allocator: std.mem.Allocator) void {
        self.tarjan.free(allocator);
        self.dp.free(allocator);
    }
};

/// Compute FOLLOW based on FIRST. Consider production
///   X -> ... Y a_1 a_2 ... a_k
/// If a_1 is term then a_1 is in FOLLOW(Y), otherwise FOLLOW(Y) should
/// include FIRST(a_1). If a_1 is a nullable non-term, then keep checking
/// a_2 in the same way. This can keep going until a_k is done. If
/// a_1...a_k are all nullable non-terms, then FOLLOW(Y) should include
/// FOLLOW(X). Be careful: in FOLLOW sets we may also include the special
/// end of input token, so consider the augmented productions.
/// Similar to how FIRST is computed, we build a digraph of non-terms with
/// edge u -> v iff FOLLOW(u) includes FOLLOW(v). We also let T[u] be the
/// union of all the FIRST sets + the terminals that should be included in
/// FOLLOW(u) due to the above reasoning.
/// The rest uses the same SCC + dp technique as FIRST.
pub fn followSet(symbol_spec: sym.SymbolSpec, productions: cfg.CfgProductions, nullable: std.DynamicBitSetUnmanaged, first_set: DpBasedSets, allocator: std.mem.Allocator) std.mem.Allocator.Error!DpBasedSets {
    const graph: digraph.Digraph = try .empty(symbol_spec.nonterminals.count, allocator);
    defer graph.free(allocator);

    const T = try allocator.alloc(std.DynamicBitSetUnmanaged, symbol_spec.nonterminals.count);
    defer allocator.free(T);
    var i: u32 = 0;
    defer {
        while (i > 0) : (i -= 1) {
            T[i - 1].deinit(allocator);
        }
    }
    while (i < symbol_spec.nonterminals.count) : (i += 1) {
        T[i] = try std.DynamicBitSetUnmanaged.initEmpty(allocator, symbol_spec.terminals.count);
    }

    // Adjacency list of `graph`
    const adj = try allocator.alloc(std.ArrayList(u32), symbol_spec.nonterminals.count);
    defer allocator.free(adj);
    var j: u32 = 0;
    defer {
        while (j > 0) : (j -= 1) {
            adj[j - 1].deinit(allocator);
        }
    }
    while (j < symbol_spec.nonterminals.count) : (j += 1) {
        adj[j] = .empty;
    }

    // End of Input can follow entry nt by the augmented production
    T[symbol_spec.nonterminals.entry].set(symbol_spec.terminals.eoi);

    for (0..symbol_spec.nonterminals.count) |u| {
        for (productions.productionsOf(symbol_spec, @intCast(u))) |rhs| {
            if (rhs.len == 0) {
                // Empty production does not contribute; necessary to
                // avoid unsigned int overflow
                continue;
            }

            // For a single production, we have to work backwards to
            // ensure only one linear scan is done.
            var running: std.DynamicBitSetUnmanaged = try .initEmpty(allocator, symbol_spec.terminals.count);
            defer running.deinit(allocator);

            var k = rhs.len - 1;
            // A "blocking" symbol is a terminal or a non-nullable nonterminal
            var no_block = true; // If we haven't encountered any blocking symbol
            while (true) {
                const is_blocking = switch (rhs[k]) {
                    .terminal => true,
                    .nonterminal => |nt| !nullable.isSet(nt),
                };
                if (is_blocking) {
                    running.unsetAll();
                }
                switch (rhs[k]) {
                    .terminal => |tid| {
                        running.set(tid);
                    },
                    .nonterminal => |nt| {
                        running.setUnion(first_set.get(nt));
                        if (no_block) {
                            try adj[nt].append(allocator, @intCast(u));
                        }
                    },
                }
                if (is_blocking) {
                    no_block = false;
                }
                if (k > 0) {
                    const prev_symbol = rhs[k - 1];
                    switch (prev_symbol) {
                        .nonterminal => |nt| T[nt].setUnion(running),
                        .terminal => {},
                    }
                    k -= 1;
                } else {
                    break;
                }
            }
        }
    }

    // Update graph with adjacency list
    while (j > 0) : (j -= 1) {
        graph.succ[j - 1] = try adj[j - 1].toOwnedSlice(allocator);
    }

    const tarjan = try graph.tarjanScc(allocator);
    errdefer tarjan.free(allocator);

    const dp = try graph.reachDp(T.ptr, symbol_spec.terminals.count, tarjan, allocator);
    return .{
        .tarjan = tarjan,
        .dp = dp,
    };
}

pub const Action = union(enum) {
    shift: struct {
        /// State to transition to
        state: u32,
    },
    reduce: struct {
        /// Reducing to which nonterminal?
        nonterminal: u32,
        /// Number of symbols on RHS, i.e. number of states to pop
        num_items: u32,
    },
    accept,
    reject,
};

/// An LR(0) item -- a production with a dot.
/// **Always be careful if you are handling the augmented production.**
pub const Item = struct {
    /// Production ID. This is an index into `cfg.CfgProductions.productions`, or
    /// the augmented production "S' -> S $" if equal to `augmented_production`.
    production: u32,
    /// Dot position (before i-th symbol of rhs, or at the end if i = rhs.len)
    dot: u32,

    pub const augmented_production = std.math.maxInt(u32);

    /// Compare items in arbitrary order to allow item set equality/hashing.
    pub fn cmp(_: void, lhs: @This(), rhs: @This()) bool {
        return lhs.production < rhs.production or
            (lhs.production == rhs.production and lhs.dot < rhs.dot);
    }

    pub fn eql(self: @This(), other: @This()) bool {
        return self.production == other.production and self.dot == other.dot;
    }

    pub fn hash(self: @This()) u64 {
        const bits = (@as(u64, self.production) << 32) | self.dot;
        return std.hash.int(bits);
    }
};

/// To hash item sets, we sort them and combine the individual hashes in
/// order. Thus, this context assumes all keys are sorted.
pub const ItemSetHashContext = struct {
    pub fn hash(_: @This(), x: []Item) u64 {
        var hasher: std.hash.Wyhash = .init(0);
        for (x) |item| {
            const v = item.hash();
            hasher.update(std.mem.asBytes(&v));
        }
        return hasher.final();
    }
    pub fn eql(_: @This(), x: []Item, y: []Item) bool {
        if (x.len != y.len)
            return false;
        if (x.len == 0 or x.ptr == y.ptr)
            return true;
        for (x, y) |a, b|
            if (!a.eql(b))
                return false;
        return true;
    }
};

/// Compute all nonterminals that can immediately appear after the dot in
/// any given item in the `core_set`.
/// This essentially implicitly computes closure set of a core set of LR(0)
/// items:
///   closure = core_set U {nt -> . rhs | all nt -> rhs, return.isSet(nt)}.
/// Closure definition: initialize closure = core, then add in "X -> . alpha"
/// to the set if there is an item of the form "Y -> beta . X gamma".
/// Let `G` be `firstGraph(...)`. `tarjan` must be `G.tarjanScc(...)`.
/// `first_reachability` must be `G.reachability(tarjan, ...)`.
pub fn reachableNtsAfterDot(symbol_spec: sym.SymbolSpec, productions: cfg.CfgProductions, tarjan: digraph.TarjanSccResult, first_reachability: digraph.ReachDpResult, core_set: []const Item, allocator: std.mem.Allocator) std.mem.Allocator.Error!std.DynamicBitSetUnmanaged {
    var ans: std.DynamicBitSetUnmanaged = try .initEmpty(allocator, symbol_spec.nonterminals.count);
    errdefer ans.deinit(allocator);

    for (core_set) |item| {
        var nt: ?u32 = null;
        if (item.production == Item.augmented_production) { // S' -> S $
            @branchHint(.unlikely);
            if (item.dot == 0) {
                nt = symbol_spec.nonterminals.entry;
            }
        } else {
            const rhs = productions.productions[item.production];
            if (item.dot < rhs.len) {
                switch (rhs[item.dot]) {
                    .nonterminal => |x| nt = x,
                    .terminal => {},
                }
            }
        }
        if (nt) |x| {
            ans.setUnion(first_reachability.get(x, tarjan));
        }
    }

    return ans;
}

/// Describes neighbors of a state in DFA during generation of parse table.
/// Mapping from a u32 (either nonterminal id or terminal id) to a list of
/// core items in that neighbor state. See `lr0`.
const DfaNeighborMap = struct {
    mp: std.HashMapUnmanaged(u32, std.ArrayList(Item), std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage),

    pub const empty = @This(){ .mp = .empty };

    pub fn free(self: *@This(), allocator: std.mem.Allocator) void {
        var it = self.mp.valueIterator();
        while (it.next()) |x| {
            x.deinit(allocator);
        }
        self.mp.deinit(allocator);
    }

    /// Add an item to a neighbor state's core item set
    pub fn addCoreItem(self: *@This(), allocator: std.mem.Allocator, key: u32, item: Item) std.mem.Allocator.Error!void {
        const gop = try self.mp.getOrPut(allocator, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(allocator, item);
    }

    /// Called once after all calls to `addCoreItem`. I.e. as of this point,
    /// the full adjacency list has been determined and all neighbor's core
    /// sets are complete. This sorts the core sets so you can use them to
    /// query a hash table.
    ///
    /// Sorting should be sufficient as there should not be duplicates in any
    /// single neighbor's core item list. (Two identical rules will still be
    /// given different production IDs)
    pub fn finalize(self: @This()) void {
        var it = self.mp.valueIterator();
        while (it.next()) |core_items| {
            std.mem.sortUnstable(Item, core_items.items, {}, Item.cmp);
        }
    }
};

/// LR(0)/SLR parser generator *frontend*. In fact this function does not
/// distinguish between LR(0) and SLR at all -- it is up to the `backend` to
/// handle additional SLR logic. The frontend only gives the backend info on
/// what should be done at each state. The backend is responsible for
/// processing the info into a data structure, and providing a runtime.
///
/// Backend must implement the following methods (`self: *Backend` omitted):
/// ```
/// fn beginTableGen(symbol_spec: *const sym.SymbolSpec, productions: *const cfg.CfgProductions, states: *const std.ArrayList([]Item), allocator: std.mem.Allocator) E!void
/// fn beginState() E!void
/// fn acceptOnEoi() E!void
/// fn reduce(production: u32) E!void
/// fn goto(nt: u32, state: u32) E!void
/// fn shift(terminal: u32, state: u32) E!void
/// fn endTableGen() E!void
/// ```
/// where `E` is `Backend.Error || std.mem.Allocator.Error`.
/// `beginTableGen` is called once at beginning. `endTableGen` is called once
/// in the end. In the middle describes a sequence of 1 or more states,
/// labelled consecutively starting from 0. Each state description begins with
/// `beginState`. Then comes a number of calls to `acceptOnEoi` (accept if
/// the lookahead is EOI), `reduce` (reduce using a given production, if you
/// want SLR, backend should only reduce for lookahead in FOLLOW set), `goto`
/// (GOTO table a.k.a state to go to if a nonterminal is produced), and `shift`
/// (shift the given token and go to the given state). Conflict detection
/// is also backend's responsibility. If an error is encountered,
/// `backend.endTableGen` may not be called, in which case the caller should
/// still make sure any resources used by the backend is freed.
/// The entry state is always 0.
///
/// Guarantees for the method calls to `backend` for **a single state**:
/// - `acceptOnEoi` is called at most once
/// - Nonterminals in calls to `goto` are all distinct
/// - Terminals in calls to `shift` are all distinct
/// - Production IDs in calls to `reduce` are all distinct
pub fn lr0(symbol_spec: sym.SymbolSpec, productions: cfg.CfgProductions, tarjan: digraph.TarjanSccResult, first_reachability: digraph.ReachDpResult, comptime Backend: type, backend: *Backend, allocator: std.mem.Allocator) (Backend.Error || std.mem.Allocator.Error)!void {
    // States are never removed from `states_map`, so use arena for allocating
    // core item sets.
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Mapping from state label (0 indexed) to core set
    var states: std.ArrayList([]Item) = .empty;
    defer states.deinit(allocator);
    // Mapping from core set to state label
    var states_map: std.HashMapUnmanaged([]Item, u32, ItemSetHashContext, std.hash_map.default_max_load_percentage) = .empty;
    defer states_map.deinit(allocator);

    // Add the initial state (augmented entry production) labelled 0
    var entry_item = try arena_allocator.alloc(Item, 1);
    entry_item[0].production = Item.augmented_production;
    entry_item[0].dot = 0; // Dot at beginning of rhs
    try states_map.putNoClobber(allocator, entry_item, 0);
    try states.append(allocator, entry_item);

    try backend.beginTableGen(&symbol_spec, &productions, &states, allocator);

    // The "work list" always consists of states labelled from `state` to
    // `total_state-1` (inclusive). For each state in work list, we find the
    // closure and explore its neighbor states, adding new states to the work
    // list by incrementing `states.items.len`.
    var state: u32 = 0; // Current state we are working on
    while (state < states.items.len) : (state += 1) {
        const core_set = states.items[state];
        try backend.beginState();

        var neighbor_shift: DfaNeighborMap = .empty;
        defer neighbor_shift.free(allocator);
        var neighbor_goto: DfaNeighborMap = .empty;
        defer neighbor_goto.free(allocator);

        // Iterate through core set, which is a subset of closure
        for (core_set) |core_item| {
            if (core_item.production == Item.augmented_production) {
                @branchHint(.unlikely);
                // S' -> S $
                switch (core_item.dot) {
                    0 => {
                        try neighbor_goto.addCoreItem(allocator, symbol_spec.nonterminals.entry, Item{
                            .production = Item.augmented_production,
                            .dot = 1,
                        });
                    },
                    1 => {
                        try backend.acceptOnEoi();
                    },
                    // We never actually shift the EOI token. We accept.
                    else => unreachable,
                }
            } else {
                std.debug.assert(core_item.dot != 0);
                const rhs = productions.productions[core_item.production];
                if (core_item.dot == rhs.len) {
                    try backend.reduce(core_item.production);
                } else {
                    const neighbor_item: Item = .{
                        .production = core_item.production,
                        .dot = core_item.dot + 1,
                    };
                    switch (rhs[core_item.dot]) {
                        .terminal => |tid| try neighbor_shift.addCoreItem(allocator, tid, neighbor_item),
                        .nonterminal => |nt| try neighbor_goto.addCoreItem(allocator, nt, neighbor_item),
                    }
                }
            }
        }

        // Iterate through the rest of closure set, i.e. closure items that are
        // not in core set.
        var nts_after_dot = try reachableNtsAfterDot(symbol_spec, productions, tarjan, first_reachability, core_set, allocator);
        defer nts_after_dot.deinit(allocator);
        var nt_it = nts_after_dot.iterator(.{});
        while (nt_it.next()) |nt| {
            for (productions.production_pact[nt]..productions.productionEndIndexOf(symbol_spec, @intCast(nt))) |prod_id| {
                // Dot is at position 0
                const rhs = productions.productions[prod_id];
                if (rhs.len == 0) {
                    try backend.reduce(@as(u32, @intCast(prod_id)));
                } else {
                    const neighbor_item: Item = .{
                        .production = @intCast(prod_id),
                        .dot = 1,
                    };
                    switch (rhs[0]) {
                        .terminal => |tid| try neighbor_shift.addCoreItem(allocator, tid, neighbor_item),
                        .nonterminal => |nt2| try neighbor_goto.addCoreItem(allocator, nt2, neighbor_item),
                    }
                }
            }
        }

        for (0..2) |pass| {
            const neighbor = switch (pass) {
                0 => &neighbor_shift,
                1 => &neighbor_goto,
                else => unreachable,
            };

            neighbor.finalize();
            var it = neighbor.mp.iterator();
            while (it.next()) |entry| {
                const core_items = entry.value_ptr.items;
                const gop = try states_map.getOrPutAdapted(allocator, core_items, ItemSetHashContext{});
                if (!gop.found_existing) {
                    const arena_core_items = try arena_allocator.dupe(Item, core_items);
                    errdefer allocator.free(arena_core_items);
                    gop.key_ptr.* = arena_core_items;
                    gop.value_ptr.* = @intCast(states.items.len);
                    try states.append(allocator, arena_core_items);
                }
                const symbol = entry.key_ptr.*;
                const to_state = gop.value_ptr.*;
                switch (pass) {
                    0 => {
                        try backend.shift(symbol, to_state);
                    },
                    1 => {
                        try backend.goto(symbol, to_state);
                    },
                    else => unreachable,
                }
            }
        }
    }

    try backend.endTableGen();
}

/// Convenient data structure manager.
pub const DataStructures = struct {
    allocator: std.mem.Allocator,
    symbol_spec: sym.SymbolSpec,
    productions: cfg.CfgProductions,

    first_graph: ?digraph.Digraph = null,
    first_tarjan: ?digraph.TarjanSccResult = null,
    first_reachability: ?digraph.ReachDpResult = null,
    def_use: ?DefUse = null,
    nullable: ?std.DynamicBitSetUnmanaged = null,
    first_set: ?DpBasedSets = null,
    follow_set: ?DpBasedSets = null,

    pub fn deinit(self: *@This()) void {
        if (self.first_graph) |g| g.free(self.allocator);
        if (self.first_tarjan) |t| t.free(self.allocator);
        if (self.first_reachability) |r| r.free(self.allocator);
        if (self.def_use) |d| d.free(self.allocator);
        if (self.nullable) |*n| n.deinit(self.allocator);
        if (self.first_set) |f| f.free(self.allocator);
        if (self.follow_set) |f| f.free(self.allocator);
    }

    pub fn getFirstGraph(self: *@This()) std.mem.Allocator.Error!digraph.Digraph {
        if (self.first_graph) |f|
            return f;
        const f = try firstGraph(self.symbol_spec, self.productions, self.allocator);
        self.first_graph = f;
        return f;
    }

    pub fn getFirstTarjan(self: *@This()) std.mem.Allocator.Error!digraph.TarjanSccResult {
        if (self.first_tarjan) |t|
            return t;
        const t = try (try self.getFirstGraph()).tarjanScc(self.allocator);
        self.first_tarjan = t;
        return t;
    }

    pub fn getFirstReachability(self: *@This()) std.mem.Allocator.Error!digraph.ReachDpResult {
        if (self.first_reachability) |r|
            return r;
        const r = try (try self.getFirstGraph()).reachability(try self.getFirstTarjan(), self.allocator);
        self.first_reachability = r;
        return r;
    }

    pub fn getDefUse(self: *@This()) std.mem.Allocator.Error!DefUse {
        if (self.def_use) |du|
            return du;
        const du = try DefUse.fromCfg(self.symbol_spec, self.productions, self.allocator);
        self.def_use = du;
        return du;
    }

    pub fn getNullable(self: *@This()) std.mem.Allocator.Error!std.DynamicBitSetUnmanaged {
        if (self.nullable) |n|
            return n;
        const n = try nullableAnalysis(self.symbol_spec, self.productions, try self.getDefUse(), self.allocator);
        self.nullable = n;
        return n;
    }

    pub fn getFirstSet(self: *@This()) std.mem.Allocator.Error!DpBasedSets {
        if (self.first_set) |fs|
            return fs;
        const fs = try firstSet(self.symbol_spec, self.productions, try self.getNullable(), self.allocator);
        self.first_set = fs;
        return fs;
    }

    pub fn getFollowSet(self: *@This()) std.mem.Allocator.Error!DpBasedSets {
        if (self.follow_set) |fs|
            return fs;
        const fs = try followSet(self.symbol_spec, self.productions, try self.getNullable(), try self.getFirstSet(), self.allocator);
        self.follow_set = fs;
        return fs;
    }
};
