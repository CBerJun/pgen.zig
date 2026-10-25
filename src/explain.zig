//! Displays information about complex LR internals in a user friendly way.

const std = @import("std");
const pgen_core = @import("pgen_core");

/// Since we introduce aux nts into the grammar during EBNF-to-CFG stage,
/// we'll need to explain each aux nt's definition otherwise the information
/// is useless.
const NonterminalExplainer = struct {
    symbol_spec: pgen_core.sym.SymbolSpec,
    productions: pgen_core.cfg.CfgProductions,
    /// Whether or not to include each nt in explanation.
    /// Length is **the number of non-node-forming nts**.
    include: std.DynamicBitSetUnmanaged,
    /// Length is `symbol_spec.terminals.literal.len`. See `writeToken`.
    literal_token_thresholds: [*]u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, symbol_spec: pgen_core.sym.SymbolSpec, productions: pgen_core.cfg.CfgProductions) std.mem.Allocator.Error!@This() {
        // TODO: nodeless nt names should be used instead of treating them like
        // aux nts.
        var include = try std.DynamicBitSetUnmanaged.initEmpty(allocator, symbol_spec.nonterminals.count - symbol_spec.nonterminals.node_forming_count);
        errdefer include.deinit(allocator);
        var literal_token_thresholds = try allocator.alloc(u32, symbol_spec.terminals.literal.len);
        errdefer allocator.free(literal_token_thresholds);
        var i: u32 = 0;
        for (symbol_spec.terminals.literal, 0..) |lc, j| {
            literal_token_thresholds[j] = i;
            i += @intCast(lc.literals.len);
        }
        return .{
            .symbol_spec = symbol_spec,
            .productions = productions,
            .include = include,
            .literal_token_thresholds = literal_token_thresholds.ptr,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.include.deinit(self.allocator);
        self.allocator.free(self.literal_token_thresholds[0..self.symbol_spec.terminals.literal.len]);
        self.* = undefined;
    }

    fn slotOf(self: @This(), nt: u32) ?u32 {
        const nfc = self.symbol_spec.nonterminals.node_forming_count;
        return if (nt >= nfc) nt - nfc else null;
    }

    /// Add an nt to explanation, and all nts that it relies on recursively.
    pub fn addNt(self: *@This(), nt: u32) std.mem.Allocator.Error!void {
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(self.allocator);
        try stack.append(self.allocator, nt);
        while (stack.pop()) |u| {
            if (self.slotOf(u)) |slot| {
                if (!self.include.isSet(slot)) {
                    self.include.set(slot);
                    var it = self.productions.of(self.symbol_spec, u);
                    while (it.next()) |rule| {
                        for (rule.rhs) |symbol| {
                            switch (symbol) {
                                .nonterminal => |v| try stack.append(self.allocator, v),
                                .terminal => {},
                            }
                        }
                    }
                }
            }
        }
    }

    /// Write a single nonterminal in a user readable way.
    pub fn writeNt(self: @This(), writer: *std.Io.Writer, nt: u32) std.Io.Writer.Error!void {
        try if (self.slotOf(nt)) |slot| writer.print("#{}", .{slot}) else writer.writeAll(self.symbol_spec.nonterminals.names[nt]);
    }

    /// Write a single terminal in a user readable way. This takes a non-O(1)
    /// amount of time (logarithmic time to the number of literal suffixes).
    pub fn writeToken(self: @This(), writer: *std.Io.Writer, tid: u32) std.Io.Writer.Error!void {
        const terminals = self.symbol_spec.terminals;
        if (tid == terminals.eoi) {
            return writer.writeByte('$');
        }
        const named_threshold = terminals.eoi - @as(u32, @intCast(terminals.named.len));
        if (tid >= named_threshold) {
            return writer.writeAll(terminals.named[tid - named_threshold]);
        }
        // Otherwise it's a literal token. Do a binary search to find out which
        // suffix it is. (First threshold that `tid` is less than)
        var lo: u32 = 0;
        var hi: u32 = @intCast(terminals.literal.len);
        // [lo, hi] inclusive candidate range
        while (lo < hi) {
            const mid = lo + ((hi - lo) >> 1);
            if (tid < self.literal_token_thresholds[mid]) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        std.debug.assert(lo > 0);
        // The correct suffix is at index `lo - 1`.
        const lc = terminals.literal[lo - 1];
        const in_lc_index = tid - self.literal_token_thresholds[lo - 1];
        try writer.writeByte('"');
        for (lc.literals[in_lc_index]) |ch| {
            switch (ch) {
                '\\', '"' => try writer.print("\\{c}", .{ch}),
                else => try writer.writeByte(ch),
            }
        }
        try writer.writeByte('"');
        try writer.writeAll(lc.suffix);
    }

    pub fn writeSymbol(self: @This(), writer: *std.Io.Writer, symbol: pgen_core.cfg.Symbol) std.Io.Writer.Error!void {
        return switch (symbol) {
            .nonterminal => |nt2| self.writeNt(writer, nt2),
            .terminal => |t| self.writeToken(writer, t),
        };
    }

    /// Write a single production.
    pub fn writeProduction(self: @This(), writer: *std.Io.Writer, rule: pgen_core.cfg.CfgProductions.Rule) std.Io.Writer.Error!void {
        try self.writeNt(writer, rule.lhs);
        try writer.writeAll(" ->");
        for (rule.rhs) |symbol| {
            try writer.writeByte(' ');
            try self.writeSymbol(writer, symbol);
        }
        if (rule.rhs.len == 0) {
            try writer.writeAll(" epsilon");
        }
    }

    pub fn writeAndAddAction(self: *@This(), writer: *std.Io.Writer, action: pgen_core.backends.Action) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
        switch (action) {
            .shift => try writer.writeAll("shift"),
            .reduce => |prod_id| {
                try writer.writeAll("reduce by ");
                const rule = self.productions.get(prod_id);
                try self.writeProduction(writer, rule);
                try self.addRule(rule);
            },
        }
    }

    /// Add all nts used in a production rule.
    pub fn addRule(self: *@This(), rule: pgen_core.cfg.CfgProductions.Rule) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
        try self.addNt(rule.lhs);
        for (rule.rhs) |symbol| {
            switch (symbol) {
                .nonterminal => |nt| try self.addNt(nt),
                .terminal => {},
            }
        }
    }

    /// Write the explanation for aux nts.
    pub fn writeAuxNtExplanation(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.include.count() == 0) {
            return;
        }
        try writer.writeAll("Auxiliary CFG nonterminals:\n");
        var it = self.include.iterator(.{});
        while (it.next()) |slot| {
            var it2 = self.productions.of(self.symbol_spec, @intCast(slot + self.symbol_spec.nonterminals.node_forming_count));
            while (it2.next()) |rule| {
                try writer.writeAll("  ");
                try self.writeProduction(writer, rule);
                try writer.writeByte('\n');
            }
        }
    }
};

pub fn conflict(
    scrap_allocator: std.mem.Allocator,
    comptime Item: type,
    writer: *std.Io.Writer,
    symbol_spec: pgen_core.sym.SymbolSpec,
    productions: pgen_core.cfg.CfgProductions,
    report: pgen_core.backends.ReportedConflict(Item),
) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    var nt_explain = try NonterminalExplainer.init(scrap_allocator, symbol_spec, productions);
    defer nt_explain.deinit();
    try writer.writeAll("Conflict at state with core set:\n");
    for (report.core_set) |core_item| {
        try writer.writeAll("  ");
        switch (Item) {
            pgen_core.lr0.Item => blk: {
                if (core_item.production == Item.augmented_production) {
                    @branchHint(.unlikely);
                    // Augmented production: S' -> S $
                    std.debug.assert(core_item.dot <= 1); // Remember we never shift the EOI token
                    try nt_explain.writeNt(writer, symbol_spec.nonterminals.entry);
                    try writer.writeAll("' ->");
                    if (core_item.dot == 0)
                        try writer.writeAll(" .");
                    try writer.writeByte(' ');
                    try nt_explain.writeNt(writer, symbol_spec.nonterminals.entry);
                    if (core_item.dot == 1)
                        try writer.writeAll(" .");
                    try writer.writeByte(' ');
                    try nt_explain.writeToken(writer, symbol_spec.terminals.eoi);
                    break :blk;
                }
                const rule = productions.get(core_item.production);
                try nt_explain.writeNt(writer, rule.lhs);
                try writer.writeAll(" ->");
                for (rule.rhs, 0..) |symbol, i| {
                    if (i == core_item.dot)
                        try writer.writeAll(" .");
                    try writer.writeByte(' ');
                    try nt_explain.writeSymbol(writer, symbol);
                }
                if (rule.rhs.len == core_item.dot)
                    try writer.writeAll(" .");
                try nt_explain.addRule(rule);
            },
            // Currently only LR(0) item exists.
            else => unreachable,
        }
        try writer.writeByte('\n');
    }
    try writer.writeAll("and lookahead: ");
    try nt_explain.writeToken(writer, report.lookahead);
    try writer.writeByte('\n');
    try writer.writeAll("Action 1: ");
    try nt_explain.writeAndAddAction(writer, report.action1);
    try writer.writeByte('\n');
    try writer.writeAll("Action 2: ");
    try nt_explain.writeAndAddAction(writer, report.action2);
    try writer.writeByte('\n');
    try nt_explain.writeAuxNtExplanation(writer);
}
