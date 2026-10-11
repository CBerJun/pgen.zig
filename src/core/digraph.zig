//! Directed graph and related algorithms

const std = @import("std");

/// Directed graph with integer nodes labelled from 0 to n-1
/// (n is number of vertices) stored using adjacency list.
pub const Digraph = struct {
    /// Number of vertices
    n: u32,
    /// Adjacency list. Length `n`. Slice memory is considered to be
    /// owned by this object.
    succ: [*][]u32,

    /// Free adjacency list
    pub fn free(self: @This(), allocator: std.mem.Allocator) void {
        const succ_slice = self.succ[0..self.n];
        for (succ_slice) |neighbors| {
            allocator.free(neighbors);
        }
        allocator.free(succ_slice);
    }

    /// Create a graph with given size, alloc adjacency list, but adjacency list
    /// slices are undefined
    pub fn withSize(size: u32, allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        return @This(){
            .n = size,
            .succ = (try allocator.alloc([]u32, size)).ptr,
        };
    }

    /// Create an empty graph with given size
    pub fn empty(size: u32, allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        const ans = try withSize(size, allocator);
        for (ans.succ[0..size]) |*neighbors| {
            neighbors.* = &.{};
        }
        return ans;
    }

    /// Tarjan's SCC algorithm
    pub fn tarjanScc(self: @This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!TarjanSccResult {
        // Temporary data structures
        var timer: u32 = 0; // DFS order timer
        var unclaimed_nodes: std.ArrayList(u32) = .empty; // Stack of unclaimed nodes
        defer unclaimed_nodes.deinit(allocator);
        var dfn = try allocator.alloc(u32, self.n); // DFS order for each node
        defer allocator.free(dfn);
        var low = try allocator.alloc(u32, self.n); // Low link
        defer allocator.free(low);
        // Data structures to be returned
        var perm_len: u32 = 0; // Current filled length of `perm`
        const perm = try allocator.alloc(u32, self.n);
        errdefer allocator.free(perm);
        var sccs: std.ArrayList(u32) = .empty; // Keeps indices in `perm`
        errdefer sccs.deinit(allocator);
        var owner = try allocator.alloc(u32, self.n); // In which SCC is each node?
        errdefer allocator.free(owner);

        const sentinel = std.math.maxInt(u32);
        @memset(dfn, sentinel);
        @memset(owner, sentinel);

        for (0..self.n) |u| {
            if (dfn[u] != sentinel) { // Already visited
                continue;
            }

            const DfsFrame = struct {
                /// Node visited
                node: u32,
                /// Index of next neighbor to process
                neighbor: u32,
                /// Was edge between `node` and its previous neighbor a tree edge?
                /// Doesn't matter if `neighbor` is 0
                prev_tree: bool,
            };
            var dfs_stack: std.ArrayList(DfsFrame) = .empty;
            defer dfs_stack.deinit(allocator);

            try dfs_stack.append(allocator, .{
                .node = @intCast(u),
                .neighbor = 0,
                .prev_tree = undefined,
            });

            while (dfs_stack.items.len > 0) {
                var frame = &dfs_stack.items[dfs_stack.items.len - 1];
                const succ = self.succ[frame.node];
                if (frame.neighbor == 0) { // Just entered
                    dfn[frame.node] = timer;
                    low[frame.node] = timer;
                    timer += 1;
                    try unclaimed_nodes.append(allocator, frame.node);
                } else { // Wrap up last neighbor's stuff, if needed
                    if (frame.prev_tree) {
                        low[frame.node] = @min(low[frame.node], low[succ[frame.neighbor - 1]]);
                    }
                }
                if (frame.neighbor == succ.len) { // Exiting
                    if (low[frame.node] == dfn[frame.node]) {
                        // We are at root of an SCC
                        var i = unclaimed_nodes.items.len - 1;
                        while (unclaimed_nodes.items[i] != frame.node) {
                            i -= 1;
                        }
                        const sz = unclaimed_nodes.items.len - i; // Size of SCC
                        const members = perm[perm_len .. perm_len + sz];
                        @memcpy(members, unclaimed_nodes.items[i..]);
                        unclaimed_nodes.items.len = i;
                        const scc_id: u32 = @intCast(sccs.items.len);
                        for (members) |v| {
                            owner[v] = scc_id;
                        }
                        try sccs.append(allocator, perm_len);
                        perm_len += @intCast(sz);
                    }
                    _ = dfs_stack.pop();
                } else { // Process next neighbor
                    const v = succ[frame.neighbor];
                    frame.neighbor += 1;
                    if (dfn[v] == sentinel) { // Unvisited (tree edge)
                        frame.prev_tree = true;
                        try dfs_stack.append(allocator, .{
                            .node = v,
                            .neighbor = 0,
                            .prev_tree = undefined,
                        });
                    } else { // Visited (back edge / cross edge)
                        frame.prev_tree = false;
                        if (owner[v] == sentinel) { // Unclaimed node
                            low[frame.node] = @min(low[frame.node], dfn[v]);
                        }
                    }
                }
            }
        }

        return .{
            .n = self.n,
            .perm = perm.ptr,
            .sccs = try sccs.toOwnedSlice(allocator),
            .owner = owner.ptr,
        };
    }

    /// Given a digraph G and a set T[i] for each node i, this precomputes
    /// for each i, the set R[i] defined as
    ///     R[i] := union(T[j] for all nodes j reachable from i in G)
    /// `tarjan` must be returned by `self.tarjanScc()`. T[i] and R[i] are
    /// bitsets limited to `bit_length` bits.
    pub fn reachDp(self: @This(), T: [*]const std.DynamicBitSetUnmanaged, bit_length: u32, tarjan: TarjanSccResult, allocator: std.mem.Allocator) std.mem.Allocator.Error!ReachDpResult {
        const num_sccs: u32 = @intCast(tarjan.sccs.len);
        const result: ReachDpResult = try .init(num_sccs, bit_length, allocator);
        errdefer result.free(allocator);
        for (0..num_sccs) |scc_id| { // Reverse topological order
            var successor_sccs: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer successor_sccs.deinit(allocator);
            const ans = &result.bitsets[scc_id]; // Answer for this SCC
            for (tarjan.membersOf(@intCast(scc_id))) |u| {
                ans.setUnion(T[u]);
                for (self.succ[u]) |v| {
                    try successor_sccs.put(allocator, tarjan.owner[v], {});
                }
            }
            var it = successor_sccs.keyIterator();
            while (it.next()) |succ_scc| {
                ans.setUnion(result.bitsets[succ_scc.*]);
            }
        }
        return result;
    }

    /// Precompute the set of nodes reachable from each node. In fact,
    /// this is just `reachDp` but with `bit_length = self.n` and
    /// `T[i] = <bitset with i-th bit set>`.
    pub fn reachability(self: @This(), tarjan: TarjanSccResult, allocator: std.mem.Allocator) std.mem.Allocator.Error!ReachDpResult {
        const num_sccs: u32 = @intCast(tarjan.sccs.len);
        const result: ReachDpResult = try .init(num_sccs, self.n, allocator);
        errdefer result.free(allocator);
        for (0..num_sccs) |scc_id| { // Reverse topological order
            var successor_sccs: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer successor_sccs.deinit(allocator);
            const ans = &result.bitsets[scc_id]; // Answer for this SCC
            for (tarjan.membersOf(@intCast(scc_id))) |u| {
                ans.set(u);
                for (self.succ[u]) |v| {
                    try successor_sccs.put(allocator, tarjan.owner[v], {});
                }
            }
            var it = successor_sccs.keyIterator();
            while (it.next()) |succ_scc| {
                ans.setUnion(result.bitsets[succ_scc.*]);
            }
        }
        return result;
    }
};

/// See `Digraph.reachDp`.
pub const ReachDpResult = struct {
    bitsets: []std.DynamicBitSetUnmanaged,

    /// Initialize to all empty sets
    pub fn init(num_sccs: u32, bit_length: u32, allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        const bitsets = try allocator.alloc(std.DynamicBitSetUnmanaged, num_sccs);
        errdefer allocator.free(bitsets);
        var i: u32 = 0;
        errdefer {
            while (i > 0) : (i -= 1) {
                bitsets[i - 1].deinit(allocator);
            }
        }
        while (i < num_sccs) : (i += 1) {
            bitsets[i] = try std.DynamicBitSetUnmanaged.initEmpty(allocator, bit_length);
        }
        return @This(){ .bitsets = bitsets };
    }

    pub fn free(self: @This(), allocator: std.mem.Allocator) void {
        for (self.bitsets) |*bitset| {
            bitset.deinit(allocator);
        }
        allocator.free(self.bitsets);
    }

    /// Get result set for a node; the correct `tarjan` must be passed in
    pub fn get(self: @This(), u: u32, tarjan: TarjanSccResult) std.DynamicBitSetUnmanaged {
        return self.bitsets[tarjan.owner[u]];
    }
};

pub const TarjanSccResult = struct {
    /// Number of nodes in original graph
    n: u32,
    /// A permutation of vertices. Length `n`.
    perm: [*]u32,
    /// All SCCs; each element stores the starting index in `perm`
    /// of this SCC's nodes. The SCCs are in reverse topological order
    /// (of the condensation graph).
    sccs: []u32,
    /// In which SCC is each node in? Each element is an index corresponding
    /// to `sccs`. Length `n`.
    owner: [*]u32,

    pub fn free(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.perm[0..self.n]);
        allocator.free(self.owner[0..self.n]);
        allocator.free(self.sccs);
    }

    /// Get member nodes of the SCC indexed at `scc_id`
    pub fn membersOf(self: @This(), scc_id: u32) []u32 {
        const end = if (scc_id + 1 == self.sccs.len) self.n else self.sccs[scc_id + 1];
        return self.perm[self.sccs[scc_id]..end];
    }
};
