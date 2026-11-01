//! The driver combines all the steps of compilation and exposes a simple
//! interface for invocation.

const std = @import("std");
const pgen_core = @import("pgen_core");
const psr = @import("pgen_meta_parser");
const Tokenizer = @import("./tokenizer.zig").Tokenizer;
const cst2ast = @import("./cst2ast.zig");
const explain = @import("./explain.zig");

/// Supported LR family algorithms
pub const Algorithm = enum {
    lr0,
    slr,
};

pub const Driver = struct {
    allocator: std.mem.Allocator,
    input: *std.Io.Reader,
    stderr: *std.Io.Writer,
    output: *std.Io.Writer,
    config: Config,

    /// OOM or IO error; errors related to the grammar itself is made human
    /// readable thru `stderr`.
    pub const Error = std.mem.Allocator.Error || std.Io.Writer.Error || error{ GrammarError, ReadFailed };

    pub const Config = struct {
        algorithm: Algorithm = .slr,
        cst_owns_token: bool = false,
        token_extra: []const []const u8 = &.{},
        dump_cfg: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, input: *std.Io.Reader, stderr: *std.Io.Writer, output: *std.Io.Writer, config: Config) @This() {
        return .{
            .allocator = allocator,
            .input = input,
            .stderr = stderr,
            .output = output,
            .config = config,
        };
    }

    /// You must deinit the returned node.
    fn goCst(self: @This(), aggregator: *pgen_core.diagnostic.Aggregator) Error!psr.CstNode {
        var tokenizer: Tokenizer = .{
            .reader = self.input,
            .payload_allocator = self.allocator,
            .scrap_allocator = self.allocator,
            .diagnostic_aggregator = aggregator,
        };
        var parser = try psr.Parser.init(self.allocator);
        defer parser.deinit(self.allocator);
        while (tokenizer.nextToken() catch |err| return switch (err) {
            error.InvalidSyntax => blk: {
                try aggregator.printDiagnostics(self.stderr);
                break :blk error.GrammarError;
            },
            else => |e| e,
        }) |token| {
            parser.feed(self.allocator, token) catch |err| {
                token.deinit(self.allocator);
                return switch (err) {
                    error.PgenParseError => blk: {
                        // TODO: more diagnostic after pgen itself supports it
                        const loc = tokenizer.current_loc;
                        try self.stderr.print("parse failed near line {} column {}\n", .{
                            // 0-indexed to 1-indexed
                            loc.ln + 1, loc.col + 1,
                        });
                        break :blk error.GrammarError;
                    },
                    else => |e| e,
                };
            };
            if (token.tag == .@"$") {
                // The EOI token does not end up in the CST and needs to be freed
                // separately.
                token.deinit(self.allocator);
            }
        }
        return parser.retrieve();
    }

    pub fn go(self: @This()) Error!void {
        errdefer self.stderr.flush() catch {};
        // Prepare diagnostic aggregator
        var aggregator: pgen_core.diagnostic.Aggregator = .withLogging(self.allocator);
        defer aggregator.deinit();
        var cfg_managed, var symbol_spec, var sym_diagnostic = blk: {
            var cst = try self.goCst(&aggregator);
            defer cst.deinit(self.allocator);
            var ast = cst2ast.EbnfManaged.fromCst(cst, self.allocator, self.allocator, &aggregator) catch |err| return switch (err) {
                error.Cst2AstSemanticError => blk2: {
                    try aggregator.printDiagnostics(self.stderr);
                    break :blk2 error.GrammarError;
                },
                else => |e| e,
            };
            defer ast.deinit();
            var sym_diagnostic = ast.ownedSymDiagnostic();
            const cfg_managed = try pgen_core.ast2cfg.CfgManaged.fromAst(
                ast.symbol_spec,
                ast.productions,
                &sym_diagnostic,
                &ast.pool,
                self.allocator,
                self.allocator,
            );
            // We must retain symbol_spec because CFG's is derived from the AST's.
            break :blk .{ cfg_managed, ast.ownedSymbolSpec(), sym_diagnostic };
        };
        defer symbol_spec.deinit(self.allocator);
        defer sym_diagnostic.deinit();
        defer cfg_managed.deinit();

        if (self.config.dump_cfg)
            try dumpCfg(self.stderr, cfg_managed.symbol_spec, cfg_managed.productions);

        var ds: pgen_core.lr0.DataStructures = .{
            .allocator = self.allocator,
            .symbol_spec = cfg_managed.symbol_spec,
            .productions = cfg_managed.productions,
        };
        defer ds.deinit();
        const tarjan = try ds.getFirstTarjan();
        const first_reachability = try ds.getFirstReachability();
        const zig_emitter: pgen_core.backends.ZigEmitter = .{
            .out = self.output,
            .token_extra = self.config.token_extra,
            .cst_owns_token = self.config.cst_owns_token,
            // TODO: node_count_bits support
        };
        switch (self.config.algorithm) {
            // Trick to force `algo` to be comptime available.
            inline else => |algo| {
                var backend = if (algo == .lr0) pgen_core.backends.Lr0ZigSwitchBackend{
                    .emitter = zig_emitter,
                } else blk: {
                    const follow_set = try ds.getFollowSet();
                    break :blk pgen_core.backends.SlrBackend(
                        pgen_core.backends.ZigSwitchActionHandler(void),
                        pgen_core.backends.ZigSwitchGotoHandler,
                    ){
                        .emitter = zig_emitter,
                        .follow_sets = &follow_set,
                        .action_handler = .{
                            .symbol_spec = &cfg_managed.symbol_spec,
                            .productions = &cfg_managed.productions,
                            .conflict_resolver = {},
                        },
                        .goto_handler = .{},
                    };
                };
                defer backend.free();
                pgen_core.lr0.lr0(
                    cfg_managed.symbol_spec,
                    cfg_managed.productions,
                    tarjan,
                    first_reachability,
                    @TypeOf(backend),
                    &backend,
                    self.allocator,
                ) catch |err| return switch (err) {
                    error.LrConflict => blk: {
                        try self.stderr.writeAll("table gen conflict: grammar is ambiguous or not compatible with the selected algorithm\n");
                        if (algo == .slr) {
                            const cr = backend.conflict_report.?;
                            try explain.conflict(
                                self.allocator,
                                pgen_core.lr0.Item,
                                self.stderr,
                                cfg_managed.symbol_spec,
                                cfg_managed.productions,
                                sym_diagnostic,
                                cr,
                            );
                        } else {
                            // TODO
                            try self.stderr.writeAll("LR(0) currently does not have conflict report; sorry");
                        }
                        break :blk error.GrammarError;
                    },
                    else => |e| e,
                };
            },
        }
        try self.output.flush();
    }
};

fn dumpCfg(out: *std.Io.Writer, symbol_spec: pgen_core.sym.SymbolSpec, productions: pgen_core.cfg.CfgProductions) std.Io.Writer.Error!void {
    try out.print("CFG dump (T={}, NT={}/{}, P={}, E=NT{})\n", .{
        symbol_spec.terminals.count,
        symbol_spec.nonterminals.count,
        symbol_spec.nonterminals.node_forming_count,
        productions.count,
        symbol_spec.nonterminals.entry,
    });
    for (0..symbol_spec.nonterminals.node_forming_count) |nt| {
        try out.print("  NT{}: {s}\n", .{ nt, symbol_spec.nonterminals.names[nt] });
    }
    for (0..productions.count) |prod| {
        try out.print("  Prod({}) NT{}:", .{ prod, productions.lhs[prod] });
        for (productions.rhs[prod]) |sym| {
            try switch (sym) {
                .terminal => |t| out.print(" T{}", .{t}),
                .nonterminal => |nt| out.print(" NT{}", .{nt}),
            };
        }
        try out.writeByte('\n');
    }
    try out.writeAll("Pact:");
    for (productions.pact[0..symbol_spec.nonterminals.count]) |pact| {
        try out.print(" {}", .{pact});
    }
    try out.writeByte('\n');
}
