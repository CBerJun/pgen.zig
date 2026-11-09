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
    /// e.g. a>b; b>c; c>a.
    pub fn retrieve(self: *@This()) (error{InconsistentRank} || std.mem.Allocator.Error)!GraphScanRRResolver {
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
        return GraphScanRRResolver.init(graph, top_order.ptr, self.allocator);
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
    /// Allocator for `graph`.
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

/// The final conflict resolver interface
pub const Resolver = struct {
    // All fields are owned
    sr: ShiftReduceMap,
    /// null means no reduce-reduce rule available
    rr: ?GraphScanRRResolver, // May become a generic type in the future
    relabeling: ?NtRelabeling,
    /// This is the allocator used for potential labelling; `sr` and `rr` can
    /// have separate ones.
    relabeling_allocator: std.mem.Allocator,

    /// Temp allocation is needed during graph traversal.
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
            return rr.query(self.nt(nonterminals[0]), self.nt(nonterminals[1]));
        return null;
    }
};
