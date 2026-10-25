//! Convert EBNF AST to CFG.

// Internal details:
// The trivial way is to add an auxiliary nonterminal for every used AST node
// that is not already a nonterminal or terminal; but we can definitely
// optimize away some of these auxiliary nonterminals (aux nt). Example:
//
// ```text
// a: X Y | Z X
// b: X Y | Y
// ```
//
// Without optimization, we'd create auxiliary nonterminals for "X Y", "Z X",
// "X Y | Z X" and "X Y | Y", when only the one for "X Y" is somewhat
// necessary (otherwise we must repeat "X Y" twice in CFG).
//
// There are mainly two types of nodes which allow optimization *on its children*:
// `.zero_or_more` and `.choose`. A `.zero_or_more` having a `.concat` operand
// allows the `.concat` to introduce no aux nt. Any children of a `.choose`
// does not require an aux nt. Of course, a `.zero_or_more` may be nested in
// a `.choose` in which case we can optimize away `.zero_or_more`'s operand at
// the same time. We don't handle recursive `.choose` since the AST interning
// should have normalized (flattened) it.
//
// The entire right-sand-side expression of a production can also be optimized.
//
// We do 2 passes. In pass 1, determine how many times each interned AST node
// gets used (on the right hand side of an EBNF production). In pass 2, we
// actually convert, making sure not to introduce aux nts for nodes that have
// only 1 use, AND meet the above condition. (If an expression has 2+ uses,
// it's better to give it an aux so that we don't repeat work.)

const std = @import("std");
const cfg = @import("./cfg.zig");
const ast = @import("./ast.zig");
const sym = @import("./sym.zig");
const diagnostic = @import("./diagnostic.zig");

/// Managed CFG form with an arena allocator owning all memory of `productions`.
/// The `symbol_spec` is *derived* from the given symbol spec and is considered
/// to be borrowed/shared.
pub const CfgManaged = struct {
    symbol_spec: sym.SymbolSpec,
    productions: cfg.CfgProductions,
    arena: *std.heap.ArenaAllocator,
    /// Owner of `arena`.
    allocator: std.mem.Allocator,

    pub fn fromAst(symbol_spec: sym.SymbolSpec, productions: ast.EbnfProductions, pool: *ast.ExprPool, allocator: std.mem.Allocator, scrap_allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        var arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = .init(allocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }
        const new_symbol_spec, const cfg_productions = try astToCfg(symbol_spec, productions, pool, arena.allocator(), scrap_allocator);
        return .{
            .symbol_spec = new_symbol_spec,
            .productions = cfg_productions,
            .arena = arena,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.* = undefined;
    }
};

/// Converts AST to CFG.
const AstToCfg = struct {
    symbol_spec: sym.SymbolSpec,
    productions: ast.EbnfProductions,
    pool: *ast.ExprPool,

    allocator: std.mem.Allocator,
    scrap_allocator: std.mem.Allocator,
    epoch: u32,
    aux_nt: u32,
    pm: ProductionsManager,
    /// Stack for pass 2.
    stack: std.ArrayList(Frame),

    /// Some rules about stack and frame:
    /// 1. `.terminal` and `.nonterminal` are never visited.
    /// 2. Each unique `ast.Expr` is visited at most once. That is,
    /// the `Frame{.expr = E, .i = 0, .target = anything}` can only appear
    /// once in stack throughout the conversion.
    const Frame = struct {
        expr: *const ast.Expr,
        i: usize,
        /// Target nonterminal to receive this expression.
        target: u32,
    };

    pub fn init(symbol_spec: sym.SymbolSpec, productions: ast.EbnfProductions, pool: *ast.ExprPool, allocator: std.mem.Allocator, scrap_allocator: std.mem.Allocator) @This() {
        return .{
            .symbol_spec = symbol_spec,
            .productions = productions,
            .pool = pool,
            .allocator = allocator,
            .scrap_allocator = scrap_allocator,
            .epoch = pool.obtainEpoch(),
            .aux_nt = symbol_spec.nonterminals.count,
            .pm = .{ .allocator = allocator },
            .stack = .empty,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.pm.deinit();
        self.stack.deinit(self.scrap_allocator);
    }

    /// Pass 1: count number of uses of each expression (just a DFS)
    pub fn pass1(self: *@This()) std.mem.Allocator.Error!void {
        var stack: std.ArrayList(struct {
            expr: *const ast.Expr,
            i: usize,
        }) = .empty;
        defer stack.deinit(self.scrap_allocator);
        for (self.productions[0..self.symbol_spec.nonterminals.count]) |rhs| {
            try stack.append(self.scrap_allocator, .{ .expr = rhs, .i = 0 });
            while (stack.pop()) |frame| {
                const entry = self.pool.getEntry(frame.expr);
                if (entry.epoch != self.epoch) { // Stale result from another call, re-init
                    entry.uses = 0;
                    entry.epoch = self.epoch;
                }
                if (frame.i == 0)
                    // First time visiting
                    entry.uses += 1;
                switch (frame.expr.*) {
                    .nonterminal, .terminal, .epsilon => {},
                    .zero_or_more, .one_or_more => |sub_expr| {
                        try stack.append(self.scrap_allocator, .{ .expr = sub_expr, .i = 0 });
                    },
                    .concat, .choose => |sub_exprs| {
                        if (frame.i + 1 < sub_exprs.len) // Prep for next child
                            try stack.append(self.scrap_allocator, .{ .expr = frame.expr, .i = frame.i + 1 });
                        try stack.append(self.scrap_allocator, .{ .expr = sub_exprs[frame.i], .i = 0 });
                    },
                }
            }
        }
    }

    /// Pass 2: actually convert
    pub fn pass2(self: *@This()) std.mem.Allocator.Error!void {
        for (0..self.symbol_spec.nonterminals.count) |lhs| {
            try self.processEbnfProduction(@intCast(lhs), self.productions[lhs]);
        }
    }

    fn oneUse(self: *@This(), node: *const ast.Expr) bool {
        // `uses` could be 0, but that also indicates we shouldn't optimize
        return self.pool.getEntry(node).uses == 1;
    }

    /// Expect `target` already assigned to in the result `pm` after visiting.
    fn push(self: *@This(), node: *const ast.Expr, target: u32) std.mem.Allocator.Error!void {
        return switch (node.*) {
            .terminal => |t| self.pm.add(target, &.{.{ .terminal = t }}),
            .nonterminal => |nt| self.pm.add(target, &.{.{ .nonterminal = nt }}),
            else => self.stack.append(self.scrap_allocator, .{ .expr = node, .i = 0, .target = target }),
        };
    }

    /// Expect `getSymbol(target)` to be available after visiting.
    fn pushWithAux(self: *@This(), node: *const ast.Expr) std.mem.Allocator.Error!void {
        return switch (node.*) {
            .terminal, .nonterminal => {},
            else => {
                // `uses` gets set to 0 as a way to indicate `converted_nt` is already set.
                const entry = self.pool.getEntry(node);
                if (entry.uses == 0)
                    return;
                entry.uses = 0;
                entry.converted_nt = self.aux_nt;
                try self.stack.append(self.scrap_allocator, .{ .expr = node, .i = 0, .target = entry.converted_nt });
                self.aux_nt += 1;
            },
        };
    }

    /// Get converted symbol of an expression assuming it's either a `.terminal`,
    /// or its `converted_nt` is set.
    fn getSymbol(self: *@This(), interned_expr: *const ast.Expr) cfg.Symbol {
        return switch (interned_expr.*) {
            .terminal => |t| .{ .terminal = t },
            .nonterminal => |nt| .{ .nonterminal = nt },
            else => blk: {
                const entry = self.pool.getEntry(interned_expr);
                std.debug.assert(entry.uses == 0);
                break :blk .{ .nonterminal = entry.converted_nt };
            },
        };
    }

    /// `getSymbol(rhs)` must be available.
    fn addProductionByAux(self: *@This(), lhs: u32, rhs: *const ast.Expr) std.mem.Allocator.Error!void {
        return self.pm.add(lhs, &.{self.getSymbol(rhs)});
    }

    fn pushNextStage(self: *@This(), frame: Frame) std.mem.Allocator.Error!void {
        return self.stack.append(self.scrap_allocator, .{ .expr = frame.expr, .i = frame.i + 1, .target = frame.target });
    }

    fn processEbnfProduction(self: *@This(), lhs: u32, rhs: *const ast.Expr) std.mem.Allocator.Error!void {
        if (rhs.* == .epsilon) {
            try self.pm.add(lhs, &.{});
            return;
        }
        const rhs_1use = self.oneUse(rhs);
        // The initial frame, only directly assign (optimize) if `rhs_1use`.
        try if (rhs_1use) self.push(rhs, lhs) else self.pushWithAux(rhs);
        while (self.stack.pop()) |frame| {
            const entry = self.pool.getEntry(frame.expr);
            std.debug.assert(entry.epoch == self.epoch);
            switch (entry.expr) {
                .epsilon => try self.pm.add(frame.target, &.{}),
                // We never push them onto stack.
                .terminal, .nonterminal => unreachable,
                .one_or_more => |opr| {
                    // No need to special case `opr == .epsilon`, since
                    // AST should've converted that to just `.epsilon`.
                    if (frame.i == 0) {
                        // Entering: parse subexpression into nt
                        try self.pushNextStage(frame);
                        try self.pushWithAux(opr);
                    } else {
                        std.debug.assert(frame.i == 1);
                        // Exiting: add productions
                        const opr_nt = self.getSymbol(opr);
                        // L: X+ => L: X and L: L X.
                        try self.pm.add(frame.target, &.{opr_nt});
                        try self.pm.add(frame.target, &.{ .{ .nonterminal = frame.target }, opr_nt });
                    }
                },
                .concat => |operands| {
                    if (frame.i < operands.len) {
                        // Still has subnode to be converted: convert one
                        // No need to special case `operands[frame.i] == .epsilon`, since
                        // AST should've removed that from `operands`.
                        try self.pushNextStage(frame);
                        try self.pushWithAux(operands[frame.i]);
                    } else {
                        std.debug.assert(frame.i == operands.len);
                        // Exiting: combine everything to create productions
                        const x = try self.allocator.alloc(cfg.Symbol, operands.len);
                        errdefer self.allocator.free(x);
                        for (operands, 0..) |opr, i|
                            x[i] = self.getSymbol(opr);
                        try self.pm.addSlice(frame.target, x);
                    }
                },
                .zero_or_more => |opr| {
                    // `uses` could be 0, but that also indicates we shouldn't
                    // optimize :)
                    if (opr.* == .concat and self.oneUse(opr)) {
                        // Optimizable: no new aux nt for operand.
                        if (frame.i < opr.concat.len) {
                            // Still has subnode to be converted: convert one
                            // Note we don't introduce a frame for the `.concat` node.
                            // No need to special case `opr.concat[frame.i] == .epsilon`, since
                            // AST should've removed that from `opr.concat`.
                            try self.pushNextStage(frame);
                            try self.pushWithAux(opr.concat[frame.i]);
                        } else {
                            std.debug.assert(frame.i == opr.concat.len);
                            // Exiting: combine everything to create productions
                            // L: (A B C)* => L: epsilon and L: L A B C.
                            try self.pm.add(frame.target, &.{});
                            const x = try self.allocator.alloc(cfg.Symbol, opr.concat.len + 1);
                            errdefer self.allocator.free(x);
                            x[0] = .{ .nonterminal = frame.target };
                            for (opr.concat, 1..) |sub_opr, i|
                                x[i] = self.getSymbol(sub_opr);
                            try self.pm.addSlice(frame.target, x);
                        }
                    } else {
                        // Normal non-optimized route.
                        if (frame.i == 0) {
                            // Entering: new aux nt for operand
                            // No need to special case `opr == .epsilon`, since
                            // AST should've converted that into just `.epsilon`.
                            try self.pushNextStage(frame);
                            try self.pushWithAux(opr);
                        } else {
                            std.debug.assert(frame.i == 1);
                            // Exiting: add productions
                            // L: X* => L: epsilon and L: L X.
                            try self.pm.add(frame.target, &.{});
                            try self.pm.add(frame.target, &.{ .{ .nonterminal = frame.target }, self.getSymbol(opr) });
                        }
                    }
                },
                .choose => |operands| {
                    if (frame.i > 0) {
                        // Cleanup previously visited node.
                        // If previous subnode is not directly assigned, need to
                        // add production.
                        const sub_expr = operands[frame.i - 1];
                        if (sub_expr.* != .epsilon and !self.oneUse(sub_expr))
                            try self.addProductionByAux(frame.target, sub_expr);
                    }
                    if (frame.i < operands.len) {
                        // Still has subnode to be converted: convert one
                        // Directly assign if it has only 1 use.
                        try self.pushNextStage(frame);
                        const sub_expr = operands[frame.i];
                        if (sub_expr.* == .epsilon) {
                            try self.pm.add(frame.target, &.{});
                        } else if (self.oneUse(sub_expr)) {
                            // Direct assign
                            try self.push(sub_expr, frame.target);
                        } else {
                            try self.pushWithAux(sub_expr);
                        }
                    } else {
                        std.debug.assert(frame.i == operands.len);
                        // Exiting: we are done
                    }
                },
            }
        }
        if (!rhs_1use)
            try self.addProductionByAux(lhs, rhs);
    }

    /// Lastly, sort production list and generate the pact representation.
    pub fn getResult(self: *@This()) std.mem.Allocator.Error!struct { sym.SymbolSpec, cfg.CfgProductions } {
        const productions = try self.pm.productions.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(productions);
        const total_productions: u32 = @intCast(productions.len);
        const production_lhs = try self.pm.production_lhs.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(production_lhs);
        std.debug.assert(total_productions == production_lhs.len);
        const production_pact = try self.allocator.alloc(u32, self.aux_nt);
        errdefer self.allocator.free(production_pact);
        // Now onto sorting
        const SortContext = struct {
            production_lhs: [*]u32,
            productions: [*][]cfg.Symbol,

            pub fn swap(this: @This(), i: usize, j: usize) void {
                std.mem.swap(u32, &this.production_lhs[i], &this.production_lhs[j]);
                std.mem.swap([]cfg.Symbol, &this.productions[i], &this.productions[j]);
            }
            pub fn lessThan(this: @This(), i: usize, j: usize) bool {
                return this.production_lhs[i] < this.production_lhs[j];
            }
        };
        std.sort.pdqContext(0, total_productions, SortContext{
            .production_lhs = production_lhs.ptr,
            .productions = productions.ptr,
        });
        // Now build pact by a single traversal of `production_lhs`.
        var prev_nt: u32 = std.math.maxInt(u32);
        for (production_lhs, 0..) |nt, i| {
            if (prev_nt != nt) {
                @memset(production_pact[prev_nt +% 1 .. nt + 1], @intCast(i));
                prev_nt = nt;
            }
        }

        return .{ sym.SymbolSpec{
            .terminals = self.symbol_spec.terminals,
            .nonterminals = .{
                .entry = self.symbol_spec.nonterminals.entry,
                .count = self.aux_nt,
                .node_forming_count = self.symbol_spec.nonterminals.node_forming_count,
                .names = self.symbol_spec.nonterminals.names,
            },
        }, cfg.CfgProductions{
            .total_productions = total_productions,
            .productions = productions.ptr,
            .production_lhs = production_lhs.ptr,
            .production_pact = production_pact.ptr,
        } };
    }
};

/// Represent production list being built.
const ProductionsManager = struct {
    allocator: std.mem.Allocator,
    productions: std.ArrayList([]cfg.Symbol) = .empty,
    production_lhs: std.ArrayList(u32) = .empty,

    pub fn deinit(self: *@This()) void {
        for (self.productions.items) |production|
            self.allocator.free(production);
        self.productions.deinit(self.allocator);
        self.production_lhs.deinit(self.allocator);
        self.* = undefined;
    }

    /// `rhs` is intended to be a static array.
    pub fn add(self: *@This(), lhs: u32, rhs: []const cfg.Symbol) std.mem.Allocator.Error!void {
        const slice = try self.allocator.dupe(cfg.Symbol, rhs);
        errdefer self.allocator.free(slice);
        try self.addSlice(lhs, slice);
    }

    /// `rhs` must be owned by `self.allocator`.
    pub fn addSlice(self: *@This(), lhs: u32, rhs: []cfg.Symbol) std.mem.Allocator.Error!void {
        try self.production_lhs.append(self.allocator, lhs);
        errdefer _ = self.production_lhs.pop();
        try self.productions.append(self.allocator, rhs);
    }
};

/// This mutates states in the `pool`'s entries, so it is not safe for
/// concurrent use.
pub fn astToCfg(symbol_spec: sym.SymbolSpec, productions: ast.EbnfProductions, pool: *ast.ExprPool, allocator: std.mem.Allocator, scrap_allocator: std.mem.Allocator) std.mem.Allocator.Error!struct { sym.SymbolSpec, cfg.CfgProductions } {
    var ast2cfg: AstToCfg = .init(symbol_spec, productions, pool, allocator, scrap_allocator);
    defer ast2cfg.deinit();
    try ast2cfg.pass1();
    try ast2cfg.pass2();
    return ast2cfg.getResult();
}
