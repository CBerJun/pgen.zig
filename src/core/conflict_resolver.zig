//! Conflict resolution (precedence/priority block) representation.
//!
//! cst2ast calls this to resolve the conflict resolution declarations.
//! Idea is to turn user declarations (binary relations) into a query-able
//! conflict resolver (choosing between actions / reporting no resolution).

const std = @import("std");
const digraph = @import("./digraph.zig");

/// A shift-reduce conflict resolver entry, nonterminal (lhs of reduce) + terminal
pub const ShiftReduceKey = struct {
    nt: u32,
    t: u32,
};

/// Hash context for `ShiftReduceKey`
pub const ShiftReduceHashContext = struct {
    pub fn eql(_: @This(), x: ShiftReduceKey, y: ShiftReduceKey) bool {
        return x.nt == y.nt and x.t == y.t;
    }
    pub fn hash(_: @This(), x: ShiftReduceKey) u64 {
        return std.hash.int((@as(u64, x.nt) << 32) | x.t);
    }
};

pub const ShiftReduceDecision = enum { shift, reduce };

/// Map that can be queried to resolve shift-reduce conflicts
pub const ShiftReduceMap = std.HashMap(ShiftReduceKey, ShiftReduceDecision, ShiftReduceHashContext, std.hash_map.default_max_load_percentage);

pub const ShiftReduceBuilder = struct {
    allocator: std.mem.Allocator,
    map: ShiftReduceMap,
    /// If `map` has been `retrieve`d.
    map_transferred: bool,

    /// Represents a semantically invalid conflict resolution configuration
    pub const Error = error{
        /// A duplicate (nonterminal, terminal) pair
        DuplicatePair,
    };

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .allocator = allocator,
            .map = .init(allocator),
            .map_transferred = false,
        };
    }

    pub fn retrieve(self: *@This()) ShiftReduceMap {
        std.debug.assert(!self.map_transferred);
        self.map_transferred = true;
        defer self.map = undefined;
        return self.map;
    }

    pub fn deinit(self: *@This()) void {
        if (!self.map_transferred) {
            self.map.deinit();
        }
        self.* = undefined;
    }

    pub fn addRule(self: *@This(), nt: u32, t: u32, rel: ShiftReduceDecision) (Error || std.mem.Allocator.Error)!void {
        const key: ShiftReduceKey = .{ .nt = nt, .t = t };
        const gop = try self.map.getOrPut(key);
        if (gop.found_existing) {
            // It doesn't make sense to have duplicates even if the old `rel`
            // matches with the new, since each rule has its own single
            // statement (ending in semicolon).
            return Error.DuplicatePair;
        }
        gop.value_ptr.* = rel;
    }
};

pub const RRResolverTag = enum {
    /// `GraphScanRRResolver`
    graph_scan,
    /// `DpRRResolver`
    dp,
};

/// The reduce-reduce priority is more complicated since we're basically given
/// a bunch of irreflexive, transitive relations, and we need answer online
/// queries about the relation between two elements (<, >, or unknown). This
/// obviously boils down to a DAG reachability problem.
/// Since we don't anticipate frequent queries, for now we just use the naive
/// algorithm with no preprocessing, O(V+E) time per query.
pub const ReduceReduceBuilder = struct {
    allocator: std.mem.Allocator,
    /// Adjacency of graph in which there is an edge u -> v iff u > v.
    succ: []std.ArrayList(u32),
    /// If `succ` ownership has been successfully transferred
    succ_transferred: bool,
    /// See `retrieve`; set on error, owned, set to empty slice when transferred
    cycle_nodes: []u32,

    pub fn init(num_nt: u32, allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        const succ = try allocator.alloc(std.ArrayList(u32), num_nt);
        @memset(succ, .empty);
        return .{
            .allocator = allocator,
            .succ = succ,
            .succ_transferred = false,
            .cycle_nodes = &.{},
        };
    }

    pub fn deinit(self: *@This()) void {
        if (!self.succ_transferred) {
            for (self.succ) |*al| {
                al.deinit(self.allocator);
            }
            self.allocator.free(self.succ);
        }
        self.allocator.free(self.cycle_nodes);
        self.* = undefined;
    }

    /// Return `IdenticalOperands` if `lhs == rhs`.
    pub fn addGreaterThan(self: *@This(), lhs: u32, rhs: u32) (error{IdenticalOperands} || std.mem.Allocator.Error)!void {
        if (lhs == rhs) {
            return error.IdenticalOperands;
        }
        // We could allow duplicate declarations (as long as they're consistent)
        // because there is use case like:
        //   a > b > c > d
        //   x > b > c > y
        // Is quite readable.
        try self.succ[lhs].append(self.allocator, rhs);
    }

    /// Return `InconsistentRank` if rank between nonterminals is inconsistent
    /// e.g. a>b; b>c; c>a. `T` is the resolver implementation.
    pub fn retrieve(self: *@This(), resolver: RRResolverTag) (error{InconsistentRank} || std.mem.Allocator.Error)!RRResolverOwned {
        // Use `empty` not `withSize` so that on error cleanup works correctly
        var graph = try digraph.Digraph.empty(@intCast(self.succ.len), self.allocator);
        errdefer graph.free(self.allocator);
        for (self.succ, 0..) |*al, i| {
            graph.succ[i] = try al.toOwnedSlice(self.allocator);
        }
        self.allocator.free(self.succ);
        self.succ = undefined;
        self.succ_transferred = true;
        // Check for cycles in the digraph, and topological sort
        const top_order = try self.allocator.alloc(u32, graph.n);
        defer self.allocator.free(top_order);
        const degree = try self.allocator.alloc(u32, graph.n);
        defer self.allocator.free(degree);
        if ((try graph.topologicalSort(self.allocator, top_order.ptr, degree.ptr)) < graph.n) {
            // Cycle detected, find an example cycle
            self.cycle_nodes = try graph.exampleCycle(self.allocator, degree.ptr);
            return error.InconsistentRank;
        }
        switch (resolver) {
            // Trick to force comptime expansion
            inline else => |r| {
                const T = switch (r) {
                    .graph_scan => GraphScanRRResolver,
                    .dp => DpRRResolver,
                };
                const impl = try T.init(graph, top_order.ptr, self.allocator);
                return RRResolverOwned.fromImplementation(T, impl, self.allocator);
            },
        }
    }
};

/// Resolve reduce-reduce resolution queries using a graph search (linear
/// preprocessing time/memory). Suitable when there isn't too many queries.
pub const GraphScanRRResolver = struct {
    /// Owned graph
    graph: digraph.Digraph,
    /// An owned array, the index of each node in a topological order
    /// (so if top_rank[i] = j, then topological_order[j] = i).
    top_rank: [*]u32,
    /// Allocator for `graph`. Also used for other purposes.
    allocator: std.mem.Allocator,

    /// `graph` is transferred, `top_order` borrowed
    pub fn init(graph: digraph.Digraph, top_order: [*]u32, allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        // Precompute `top_rank` from `top_order`
        var top_rank = try allocator.alloc(u32, graph.n);
        errdefer allocator.free(top_rank);
        for (0..graph.n) |i| {
            top_rank[top_order[i]] = @intCast(i);
        }
        return .{ .graph = graph, .top_rank = top_rank.ptr, .allocator = allocator };
    }

    pub fn deinit(self: *@This()) void {
        self.graph.free(self.allocator);
        self.allocator.free(self.top_rank[0..self.graph.n]);
        self.* = undefined;
    }

    /// Return the one with a greater priority, or null if order is unspecified
    pub fn query(self: @This(), x0: u32, x1: u32) std.mem.Allocator.Error!?u1 {
        // x0 > x1 iff there is a path from x0 to x1 (vice versa)
        // If neither holds, return null
        if (x0 == x1) {
            return null;
        }
        // The topological sort saves us from searching both directions.
        if (self.top_rank[x0] > self.top_rank[x1]) {
            // No path exist from `x0` to `x1`.
            return if (try self.graph.pathExists(self.allocator, x1, x0)) 1 else null;
        } else {
            // No path exist from `x1` to `x0`.
            std.debug.assert(self.top_rank[x0] < self.top_rank[x1]);
            return if (try self.graph.pathExists(self.allocator, x0, x1)) 0 else null;
        }
    }

    pub const vtable = RRResolver.VTable.fromImplementation(@This());
    pub const owned_vtable = RRResolverOwned.VTable.fromImplementation(@This());
};

/// Resolve reduce-reduce resolution queries using a bitset based DP approach.
/// Preprocessing takes O(n^2/w) where n is number of nonterminals and w is
/// size of machine word (bitset optimization factor). Preprocessing table also
/// needs that much memory. Query is O(1).
/// This should be used when reduce-reduce queries are very frequent and there
/// are not many nonterminals involved.
pub const DpRRResolver = struct {
    /// Since the `graph` tend to have many single vertices (nonterminals that
    /// are not involved in `priority` block at all), this is an optimization
    /// that maps nonterminal ID/vertex ID in `graph` into bitset index; or
    /// `unrelated_nonterminal` if the nonterminal has no relevance in reduce-
    /// reduce lookup.
    vertex_map: []u32,
    /// The lookup table, both indices are ID mapped after `vertex_map`.
    /// [u][v] is set if from `u` you can reach `v`. So [u][u] is always set!
    lookup: []std.DynamicBitSetUnmanaged,
    /// Allocator for `graph`. Also used for other purposes.
    allocator: std.mem.Allocator,

    pub const unrelated_nonterminal = std.math.maxInt(u32);

    /// `graph` is transferred, `top_order` borrowed
    pub fn init(graph: digraph.Digraph, top_order: [*]u32, allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        // `graph` no longer needed once precomputed `lookup`.
        defer graph.free(allocator);
        // Find nonterminals that are related to reduce-reduce resolution
        var vertex_map = try allocator.alloc(u32, graph.n);
        errdefer allocator.free(vertex_map);
        // First store whether a vertex is relevant in `vertex_map`.
        @memset(vertex_map, 0);
        for (0..graph.n) |u| {
            if (graph.succ[u].len > 0) {
                vertex_map[u] = 1; // u has out edge
            }
            for (graph.succ[u]) |v| {
                vertex_map[v] = 1; // v has in edge
            }
        }
        // Assign IDs to the relevant nts now
        var n: u32 = 0;
        for (vertex_map) |*x| {
            if (x.* == 0) {
                x.* = @This().unrelated_nonterminal;
            } else {
                std.debug.assert(x.* == 1);
                x.* = n;
                n += 1;
            }
        }
        // `n` is now the number of relevant nts; `vertex_map` populated
        var lookup_i: u32 = 0;
        var lookup = try allocator.alloc(std.DynamicBitSetUnmanaged, n);
        errdefer {
            for (0..lookup_i) |i| {
                lookup[i].deinit(allocator);
            }
            allocator.free(lookup);
        }
        while (lookup_i < n) : (lookup_i += 1) {
            lookup[lookup_i] = try std.DynamicBitSetUnmanaged.initEmpty(allocator, n);
        }
        // Now we just do `Digraph.reachability` except that we are already
        // dealing with an acyclic graph, so no Tarjan SCC needed.
        {
            var i: u32 = graph.n;
            while (i > 0) { // Reverse topological order
                i -= 1;
                const nt = top_order[i];
                // Remember to apply the map!
                const u = vertex_map[nt];
                if (u == @This().unrelated_nonterminal) continue;
                lookup[u].set(u);
                for (graph.succ[nt]) |nt_v| {
                    const v = vertex_map[nt_v];
                    std.debug.assert(v != @This().unrelated_nonterminal);
                    lookup[u].setUnion(lookup[v]);
                }
            }
        }
        return .{
            .vertex_map = vertex_map,
            .lookup = lookup,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.vertex_map);
        for (self.lookup) |*bs| {
            bs.deinit(self.allocator);
        }
        self.allocator.free(self.lookup);
        self.* = undefined;
    }

    /// Return the one with a greater priority, or null if order is unspecified.
    /// Return is declared as error union to conform to the public interface.
    pub fn query(self: @This(), x0: u32, x1: u32) std.mem.Allocator.Error!?u1 {
        if (x0 == x1) // lookup[u][u] is always set
            return null;
        // Unrelated nt cannot be compared with any other nt
        const u = self.vertex_map[x0];
        if (u == @This().unrelated_nonterminal)
            return null;
        const v = self.vertex_map[x1];
        if (v == @This().unrelated_nonterminal)
            return null;
        if (self.lookup[u].isSet(v))
            return 0;
        if (self.lookup[v].isSet(u))
            return 1;
        return null;
    }

    pub const vtable = RRResolver.VTable.fromImplementation(@This());
    pub const owned_vtable = RRResolverOwned.VTable.fromImplementation(@This());
};

/// Since ast2cfg relabels nonterminals as part of optimization, `Resolver`
/// may keep this as a "filter" on the upcoming queries.
pub const NtRelabeling = struct {
    // The semantic is as follows:
    // Say incoming nt is u, then the relabelled nt is:
    // - if u < base, then u
    // - if u >= base, then u - psa[u-base]
    // `psa.len + base` must be equal to total nonterminal count.
    base: u32,
    /// Owned
    psa: []u32,

    pub fn map(self: @This(), nt: u32) u32 {
        return nt - (if (nt < self.base) 0 else self.psa[nt - self.base]);
    }

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.psa);
    }
};

/// Polymorphic reduce-reduce resolver wrapper.
pub const RRResolver = struct {
    /// Pointer to implementation states; may be undefined.
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Query which nt has a greater priority, or null if order is unspecified
        query: *const fn (*anyopaque, u32, u32) std.mem.Allocator.Error!?u1,

        pub fn fromImplementation(comptime T: type) @This() {
            return .{
                .query = struct {
                    pub fn query(self: *anyopaque, x0: u32, x1: u32) std.mem.Allocator.Error!?u1 {
                        return @as(*T, @ptrCast(@alignCast(self))).query(x0, x1);
                    }
                }.query,
            };
        }
    };

    pub fn query(self: @This(), x0: u32, x1: u32) std.mem.Allocator.Error!?u1 {
        return self.vtable.query(self.context, x0, x1);
    }
};

/// A `RRResolver` and its implementation owned by this type-erased object
pub const RRResolverOwned = struct {
    /// Type-erased pointer to the underlying implementation. Allocated so
    /// that its address is stable.
    context: *anyopaque,
    vtable: *const VTable,
    resolver_vtable: *const RRResolver.VTable,
    /// Owns the the memory location pointed to by `context`, but not necessarily
    /// sub-objects owned by `context`.
    allocator: std.mem.Allocator,

    pub const VTable = struct {
        deinit: *const fn (*anyopaque) void,
        /// `std.mem.Allocator.destroy` called on this type. (That function
        /// requires the pointed-to-type's size & alignment be known)
        destroy: *const fn (*anyopaque, std.mem.Allocator) void,

        pub fn fromImplementation(comptime T: type) @This() {
            return .{
                .deinit = struct {
                    pub fn deinit(self: *anyopaque) void {
                        return @as(*T, @ptrCast(@alignCast(self))).deinit();
                    }
                }.deinit,
                .destroy = struct {
                    pub fn destroy(self: *anyopaque, allocator: std.mem.Allocator) void {
                        allocator.destroy(@as(*T, @ptrCast(@alignCast(self))));
                    }
                }.destroy,
            };
        }
    };

    pub fn deinit(self: *@This()) void {
        self.vtable.deinit(self.context);
        self.vtable.destroy(self.context, self.allocator);
        self.* = undefined;
    }

    pub fn interface(self: @This()) RRResolver {
        return .{ .context = self.context, .vtable = self.resolver_vtable };
    }

    pub fn fromImplementation(comptime T: type, impl: T, allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        const stable_ptr = try allocator.create(T);
        errdefer allocator.destroy(stable_ptr);
        stable_ptr.* = impl;
        return .{
            .context = stable_ptr,
            .vtable = &T.owned_vtable,
            .resolver_vtable = &T.vtable,
            .allocator = allocator,
        };
    }
};

/// The final conflict resolver interface
pub const Resolver = struct {
    // All fields are owned
    sr: ShiftReduceMap,
    /// null means no reduce-reduce rule available
    rr: ?RRResolverOwned,
    relabeling: ?NtRelabeling,
    /// This is the allocator used for potential labelling; `sr` and `rr` can
    /// have separate ones.
    relabeling_allocator: std.mem.Allocator,

    /// Temp allocation may be needed during e.g. graph traversal.
    pub const Error = std.mem.Allocator.Error;

    pub fn deinit(self: *@This()) void {
        self.sr.deinit();
        if (self.rr) |rr| {
            var rr_var = rr;
            rr_var.deinit();
        }
        if (self.relabeling) |r| {
            r.deinit(self.relabeling_allocator);
        }
        self.* = undefined;
    }

    /// Potentially relabelled nt
    fn nt(self: @This(), x: u32) u32 {
        if (self.relabeling) |r| {
            return r.map(x);
        }
        return x;
    }

    pub fn resolveShiftReduce(self: *@This(), terminal: u32, nonterminal: u32) Error!?ShiftReduceDecision {
        const key: ShiftReduceKey = .{ .nt = self.nt(nonterminal), .t = terminal };
        return self.sr.get(key);
    }
    pub fn resolveReduceReduce(self: *@This(), nonterminals: [2]u32) Error!?u1 {
        if (self.rr) |rr|
            return rr.interface().query(self.nt(nonterminals[0]), self.nt(nonterminals[1]));
        return null;
    }
};
