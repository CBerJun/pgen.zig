//! Generates the meta CFG. Manual translation of meta_grammar.txt into
//! a Zig `Cfg` object.
const std = @import("std");

/// Nonterminals. All of these are node-forming for our purpose.
const Nt = enum(u8) {
    grammar,
    token_decl,
    production,
    rhs_atom,
    rhs_term,
    rhs_factor,
    rhs,
    nonterminal_qualifier,
    _,
};

/// Keywords. Correspond to "" (no suffix) in meta_grammar.txt.
const Sym = enum(u8) {
    @";",
    @"[",
    @"]",
    @"{",
    @"}",
    @"(",
    @")",
    @"*",
    @":",
    @"|",
    @"+",
};
/// Keywords. Correspond to ""k suffix in meta_grammar.txt.
const Keyword = enum(u8) {
    epsilon,
    tokens,
    entry,
    nodeless,
};
/// Named terminals.
const Terminal = enum(u8) {
    STRING,
    WORD,
};

const total_sym = enumSize(Sym);
const total_literal_tokens = total_sym + enumSize(Keyword);
const eoi = total_literal_tokens + enumSize(Terminal);
const total_tokens = eoi + 1;

fn enumSize(comptime T: anytype) usize {
    return std.meta.fields(T).len;
}

// A possible thing on the right hand side of a production.
const Atom = union(enum) {
    nt: Nt,
    sym: Sym,
    keyword: Keyword,
    terminal: Terminal,

    fn toStr(self: Atom, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try switch (self) {
            .nt => |nt| w.print(".{{.nonterminal = {}}}", .{@intFromEnum(nt)}),
            .sym => |sym| w.print(".{{.terminal = {}}}", .{@intFromEnum(sym)}),
            .keyword => |kw| w.print(".{{.terminal = {}}}", .{@intFromEnum(kw) + total_sym}),
            .terminal => |t| w.print(".{{.terminal = {}}}", .{@intFromEnum(t) + total_literal_tokens}),
        };
    }
};

/// Make production making easier. Instead of writing .{.nt = X}, just write X.
/// And similar for other values (`Sym`, `Keyword`, `Terminal`).
inline fn atomList(allocator: std.mem.Allocator, args: anytype) std.mem.Allocator.Error![]Atom {
    var ans = try allocator.alloc(Atom, args.len);
    inline for (0.., args) |i, arg| {
        ans[i] = switch (@TypeOf(arg)) {
            Nt => .{ .nt = arg },
            Sym => .{ .sym = arg },
            Keyword => .{ .keyword = arg },
            Terminal => .{ .terminal = arg },
            else => unreachable,
        };
    }
    return ans;
}

const ProductionManager = struct {
    l: std.ArrayListUnmanaged(std.ArrayListUnmanaged([]Atom)),
    allocator: std.mem.Allocator,
    n_prods: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        var ans: @This() = .{
            .allocator = allocator,
            .l = .empty,
        };
        try ans.l.resize(allocator, enumSize(Nt));
        @memset(ans.l.items, .empty);
        return ans;
    }

    pub fn deinit(self: *@This()) void {
        for (self.l.items) |*inner| {
            for (inner.items) |rhs| {
                self.allocator.free(rhs);
            }
            inner.deinit(self.allocator);
        }
        self.l.deinit(self.allocator);
        self.* = undefined;
    }

    pub inline fn prod(self: *@This(), nt: Nt, rhs: anytype) std.mem.Allocator.Error!void {
        try self.l.items[@intFromEnum(nt)].append(self.allocator, try atomList(self.allocator, rhs));
        self.n_prods += 1;
    }
};

const AuxNtManager = struct {
    pm: *ProductionManager,
    cur: usize = enumSize(Nt),

    pub fn newAux(self: *@This()) std.mem.Allocator.Error!Nt {
        (try self.pm.l.addOne(self.pm.allocator)).* = .empty;
        defer self.cur += 1;
        return @enumFromInt(self.cur);
    }
};

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var arg_it = try init.minimal.args.iterateAllocator(allocator);
    defer arg_it.deinit();
    std.debug.assert(arg_it.skip());
    const out_file_name = arg_it.next() orelse fatal("expected one argument (out file)", .{});
    const file = try std.Io.Dir.cwd().createFile(init.io, out_file_name, .{});
    defer file.close(init.io);

    var out_buffer: [512]u8 = undefined;
    var out_writer = file.writer(init.io, &out_buffer);
    const writer = &out_writer.interface;

    // --- Production list
    var pm: ProductionManager = try .init(allocator);
    defer pm.deinit();
    var aux_manager: AuxNtManager = .{ .pm = &pm };
    try buildProductions(&pm, &aux_manager);

    // --- Post processing of productions
    const total_nts = aux_manager.cur;

    // --- Write output
    try writer.writeAll(
        \\const cfg = @import("pgen_core").cfg;
        \\pub const meta_cfg: cfg.Cfg = .{
        \\.terminals = .{
        \\.literal = &[_]cfg.LiteralCollection{
    );
    try writeLiteralCollection(writer, "", Sym);
    try writeLiteralCollection(writer, "k", Keyword);
    try writer.writeAll(
        \\},
        \\.named = &[_][]const u8{
    );
    try writeEnumNames(writer, Terminal);
    try writer.print(
        \\}},
        \\.count = {},
        \\.eoi = {},
        \\}},
        \\.nonterminals = .{{
        \\.entry = {},
        \\.names = &[_][]const u8{{
    , .{ total_tokens, eoi, @intFromEnum(Nt.grammar) }); // End .terminals
    try writeEnumNames(writer, Nt);
    try writer.print(
        \\}},
        \\.node_forming_count = {},
        \\.count = {},
        \\}},
        \\.total_productions = {},
        \\.production_lhs = &[_]u32{{
    , .{ enumSize(Nt), total_nts, pm.n_prods }); // End .nonterminals
    for (pm.l.items, 0..) |all_rhs, i| {
        for (0..all_rhs.items.len) |_| {
            try writer.print("{},", .{i});
        }
    }
    try writer.writeAll(
        \\},
        \\.production_pact = &[_]u32{
    );
    {
        var i: u32 = 0;
        for (pm.l.items) |all_rhs| {
            try writer.print("{},", .{i});
            i += @intCast(all_rhs.items.len);
        }
    }
    try writer.writeAll(
        \\},
        \\.productions = &[_][]const cfg.Symbol{
    );
    for (pm.l.items) |all_rhs| {
        for (all_rhs.items) |rhs| {
            try writer.writeAll("&[_]cfg.Symbol{");
            for (rhs) |atom| {
                try atom.toStr(writer);
                try writer.writeByte(',');
            }
            try writer.writeAll("},");
        }
    }
    try writer.writeAll("}};"); // End .productions, meta_cfg

    try writer.flush();
}

/// All the productions of the meta grammar.
fn buildProductions(pm: *ProductionManager, aux_manager: *AuxNtManager) !void {
    const token_decl_list = try aux_manager.newAux();
    const production_list = try aux_manager.newAux();
    try pm.prod(.grammar, .{
        Keyword.tokens, Sym.@"{",      token_decl_list, Sym.@"}",
        Keyword.entry,  Terminal.WORD, Sym.@";",        production_list,
    });
    try pm.prod(token_decl_list, .{Nt.token_decl});
    try pm.prod(token_decl_list, .{ token_decl_list, Nt.token_decl });
    try pm.prod(.token_decl, .{ Terminal.WORD, Sym.@";" });
    try pm.prod(.token_decl, .{ Terminal.STRING, Sym.@";" });
    try pm.prod(.production, .{ Nt.nonterminal_qualifier, Terminal.WORD, Sym.@":", Nt.rhs, Sym.@";" });
    try pm.prod(.nonterminal_qualifier, .{});
    try pm.prod(.nonterminal_qualifier, .{Keyword.nodeless});

    try pm.prod(.rhs_atom, .{Terminal.WORD});
    try pm.prod(.rhs_atom, .{Terminal.STRING});
    try pm.prod(.rhs_atom, .{ Sym.@"(", Nt.rhs, Sym.@")" });
    try pm.prod(.rhs_atom, .{ Sym.@"[", Nt.rhs, Sym.@"]" });
    try pm.prod(.rhs_term, .{Nt.rhs_atom});
    try pm.prod(.rhs_term, .{ Nt.rhs_atom, Sym.@"*" });
    try pm.prod(.rhs_term, .{ Nt.rhs_atom, Sym.@"+" });

    const rhs_term_list = try aux_manager.newAux();
    try pm.prod(rhs_term_list, .{Nt.rhs_term});
    try pm.prod(rhs_term_list, .{ rhs_term_list, Nt.rhs_term });
    try pm.prod(.rhs_factor, .{rhs_term_list});
    try pm.prod(.rhs_factor, .{Keyword.epsilon});

    const alternatives = try aux_manager.newAux();
    try pm.prod(alternatives, .{});
    try pm.prod(alternatives, .{ alternatives, Sym.@"|", Nt.rhs_factor });
    try pm.prod(.rhs, .{ Nt.rhs_factor, alternatives });
}

fn writeLiteralCollection(writer: *std.Io.Writer, comptime suffix: []const u8, comptime T: anytype) std.Io.Writer.Error!void {
    try writer.writeAll(".{.suffix = \"");
    try std.zig.stringEscape(suffix, writer);
    try writer.writeAll("\", .literals = &[_][]const u8{");
    try writeEnumNames(writer, T);
    try writer.writeAll("}},");
}

fn writeEnumNames(writer: *std.Io.Writer, comptime T: anytype) std.Io.Writer.Error!void {
    for (std.enums.values(T)) |t| {
        try writer.writeAll("\"");
        try std.zig.stringEscape(@tagName(t), writer);
        try writer.writeAll("\",");
    }
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(1);
}
