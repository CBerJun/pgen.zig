//! Displays information about complex LR internals in a user friendly way.

const std = @import("std");
const pgen_core = @import("pgen_core");

/// Dump various data in a CFG in a human readable way.
const CfgDumper = struct {
    symbol_spec: pgen_core.sym.SymbolSpec,
    productions: pgen_core.cfg.CfgProductions,
    /// Having the diagnostic gives more readable output.
    sym_diagnostic: ?pgen_core.sym.DiagnosticInfo,
    /// Length is `symbol_spec.terminals.literal.len`. See `writeToken`.
    literal_token_thresholds: [*]u32,
    /// Here user nt count means number of nts that have a display name!
    user_nt_count: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, symbol_spec: pgen_core.sym.SymbolSpec, productions: pgen_core.cfg.CfgProductions, sym_diagnostic: ?pgen_core.sym.DiagnosticInfo) std.mem.Allocator.Error!@This() {
        const user_nt_count = symbol_spec.nonterminals.node_forming_count + (if (sym_diagnostic) |sd| @as(u32, @intCast(sd.nodeless_nt_names.len)) else 0);
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
            .sym_diagnostic = sym_diagnostic,
            .literal_token_thresholds = literal_token_thresholds.ptr,
            .user_nt_count = user_nt_count,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.literal_token_thresholds[0..self.symbol_spec.terminals.literal.len]);
        self.* = undefined;
    }

    pub fn namelessNtCount(self: @This()) u32 {
        return self.symbol_spec.nonterminals.count - self.user_nt_count;
    }

    pub fn namelessNtId(self: @This(), nt: u32) ?u32 {
        return if (nt >= self.user_nt_count) nt - self.user_nt_count else null;
    }

    /// Write a single nonterminal in a user readable way.
    pub fn writeNt(self: @This(), writer: *std.Io.Writer, nt: u32) std.Io.Writer.Error!void {
        const nfc = self.symbol_spec.nonterminals.node_forming_count;
        try if (self.namelessNtId(nt)) |x| writer.print("#{}", .{x}) else writer.writeAll(if (nt < nfc) self.symbol_spec.nonterminals.names[nt] else self.sym_diagnostic.?.nodeless_nt_names[nt - nfc]);
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
};

/// Since we introduce aux nts into the grammar during EBNF-to-CFG stage,
/// we'll need to explain each aux nt's definition otherwise the information
/// is useless.
const NonterminalExplainer = struct {
    /// Borrowed.
    cd: *const CfgDumper,
    /// Whether or not to include each nt in explanation.
    /// Length is **the number of non-node-forming nts**.
    include: std.DynamicBitSetUnmanaged,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, cd: *const CfgDumper) std.mem.Allocator.Error!@This() {
        var include = try std.DynamicBitSetUnmanaged.initEmpty(allocator, cd.namelessNtCount());
        errdefer include.deinit(allocator);
        return .{
            .cd = cd,
            .include = include,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.include.deinit(self.allocator);
        self.* = undefined;
    }

    /// Add an nt to explanation, and all nts that it relies on recursively.
    pub fn addNt(self: *@This(), nt: u32) std.mem.Allocator.Error!void {
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(self.allocator);
        try stack.append(self.allocator, nt);
        while (stack.pop()) |u| {
            if (self.cd.namelessNtId(u)) |slot| {
                if (!self.include.isSet(slot)) {
                    self.include.set(slot);
                    var it = self.cd.productions.of(self.cd.symbol_spec, u);
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

    pub fn writeAndAddAction(self: *@This(), writer: *std.Io.Writer, action: pgen_core.backends.Action) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
        switch (action) {
            .shift => try writer.writeAll("shift"),
            .reduce => |prod_id| {
                try writer.writeAll("reduce by ");
                const rule = self.cd.productions.get(prod_id);
                try self.cd.writeProduction(writer, rule);
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
        while (it.next()) |x| {
            var it2 = self.cd.productions.of(self.cd.symbol_spec, @intCast(x + self.cd.user_nt_count));
            while (it2.next()) |rule| {
                try writer.writeAll("  ");
                try self.cd.writeProduction(writer, rule);
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
    sym_diagnostic: ?pgen_core.sym.DiagnosticInfo,
    report: pgen_core.backends.ReportedConflict(Item),
) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    var cfg_dumper = try CfgDumper.init(scrap_allocator, symbol_spec, productions, sym_diagnostic);
    defer cfg_dumper.deinit();
    var nt_explain = try NonterminalExplainer.init(scrap_allocator, &cfg_dumper);
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
                    try cfg_dumper.writeNt(writer, symbol_spec.nonterminals.entry);
                    try writer.writeAll("' ->");
                    if (core_item.dot == 0)
                        try writer.writeAll(" .");
                    try writer.writeByte(' ');
                    try cfg_dumper.writeNt(writer, symbol_spec.nonterminals.entry);
                    if (core_item.dot == 1)
                        try writer.writeAll(" .");
                    try writer.writeByte(' ');
                    try cfg_dumper.writeToken(writer, symbol_spec.terminals.eoi);
                    break :blk;
                }
                const rule = productions.get(core_item.production);
                try cfg_dumper.writeNt(writer, rule.lhs);
                try writer.writeAll(" ->");
                for (rule.rhs, 0..) |symbol, i| {
                    if (i == core_item.dot)
                        try writer.writeAll(" .");
                    try writer.writeByte(' ');
                    try cfg_dumper.writeSymbol(writer, symbol);
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
    if (report.lookahead) |lookahead| {
        try writer.writeAll("and lookahead: ");
        try cfg_dumper.writeToken(writer, lookahead);
        try writer.writeByte('\n');
    }
    try writer.writeAll("Action 1: ");
    try nt_explain.writeAndAddAction(writer, report.action1);
    try writer.writeByte('\n');
    try writer.writeAll("Action 2: ");
    try nt_explain.writeAndAddAction(writer, report.action2);
    try writer.writeByte('\n');
    try nt_explain.writeAuxNtExplanation(writer);
}

pub fn cfg(
    scrap_allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    symbol_spec: pgen_core.sym.SymbolSpec,
    productions: pgen_core.cfg.CfgProductions,
    sym_diagnostic: ?pgen_core.sym.DiagnosticInfo,
) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    try writer.print("CFG dump (T={}, NT={}/{}, P={}, E={})\n", .{
        symbol_spec.terminals.count,
        symbol_spec.nonterminals.count,
        symbol_spec.nonterminals.node_forming_count,
        productions.count,
        symbol_spec.nonterminals.entry,
    });
    try writer.writeAll("  Nonterminals (node forming):\n");
    for (0..symbol_spec.nonterminals.node_forming_count) |nt| {
        try writer.print("    {s}: {}\n", .{ symbol_spec.nonterminals.names[nt], nt });
    }
    if (sym_diagnostic) |sd| {
        try writer.writeAll("  Nonterminals (user nodeless):\n");
        for (sd.nodeless_nt_names, symbol_spec.nonterminals.node_forming_count..) |name, nt| {
            try writer.print("    {s}: {}\n", .{ name, nt });
        }
    }
    var cfg_dumper = try CfgDumper.init(scrap_allocator, symbol_spec, productions, sym_diagnostic);
    defer cfg_dumper.deinit();
    try writer.writeAll("  Productions:\n");
    for (0..productions.count) |prod_id| {
        try writer.print("    [{}] ", .{prod_id});
        try cfg_dumper.writeProduction(writer, productions.get(@intCast(prod_id)));
        try writer.writeByte('\n');
    }
}
