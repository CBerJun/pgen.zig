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
        dump_states: bool = false,
        // `.graph_scan` should work fine in most cases when there aren't too
        // many queries.
        rr_resolver_tag: pgen_core.conflict_resolver.RRResolverTag = .graph_scan,
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
        var cfg_managed, var symbol_spec, var sym_diagnostic, const conflict_resolver = blk: {
            var cst = try self.goCst(&aggregator);
            defer cst.deinit(self.allocator);
            var ast = cst2ast.EbnfManaged.fromCst(cst, self.allocator, self.allocator, &aggregator, self.config.rr_resolver_tag) catch |err| return switch (err) {
                error.Cst2AstSemanticError => blk2: {
                    try aggregator.printDiagnostics(self.stderr);
                    break :blk2 error.GrammarError;
                },
                else => |e| e,
            };
            defer ast.deinit();
            var sym_diagnostic = ast.ownedSymDiagnostic();
            const conflict_resolver = ast.ownedConflictResolver();
            var conflict_resolver_var: pgen_core.conflict_resolver.Resolver = if (conflict_resolver) |x| x else undefined;
            const cfg_managed = try pgen_core.ast2cfg.CfgManaged.fromAst(
                ast.symbol_spec,
                ast.productions,
                &sym_diagnostic,
                if (conflict_resolver) |_| &conflict_resolver_var else null,
                &ast.pool,
                self.allocator,
                self.allocator,
            );
            // We must retain symbol_spec because CFG's is derived from the AST's.
            break :blk .{
                cfg_managed,
                ast.ownedSymbolSpec(),
                sym_diagnostic,
                if (conflict_resolver) |_| conflict_resolver_var else null,
            };
        };
        defer symbol_spec.deinit(self.allocator);
        defer sym_diagnostic.deinit();
        defer {
            if (conflict_resolver) |c| {
                var conflict_resolver_var = c;
                conflict_resolver_var.deinit();
            }
        }
        defer cfg_managed.deinit();

        if (self.config.dump_cfg)
            try explain.cfg(self.allocator, self.stderr, cfg_managed.symbol_spec, cfg_managed.productions, sym_diagnostic);

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
        const has_cr_runtime = conflict_resolver != null;
        switch (self.config.algorithm) {
            // Trick to force `algo` to be comptime available.
            inline else => |algo| outer: {
                if (algo == .lr0 and has_cr_runtime) {
                    try self.stderr.writeAll("LR(0) currently does not support conflict resolution\n");
                    return error.GrammarError;
                }
                switch (has_cr_runtime) {
                    // Well, the trick again.
                    inline else => |has_cr| break :outer {
                        const cr_passed = if (has_cr) conflict_resolver.? else {};
                        var backend = if (algo == .lr0) pgen_core.backends.Lr0SwitchBackend{
                            .emitter = zig_emitter,
                        } else blk: {
                            const follow_set = try ds.getFollowSet();
                            break :blk pgen_core.backends.SlrBackend(
                                pgen_core.backends.SwitchActionHandler(@TypeOf(cr_passed)),
                                pgen_core.backends.SwitchGotoHandler,
                            ){
                                .emitter = zig_emitter,
                                .follow_sets = &follow_set,
                                .goto_handler = .{},
                                .conflict_resolver = cr_passed,
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
                            self.config.dump_states,
                        ) catch |err| return switch (err) {
                            error.LrConflict => blk: {
                                // TODO: suggest the priority/precedence declarations
                                try self.stderr.writeAll(
                                    \\table gen conflict: grammar is ambiguous or not compatible with the selected algorithm
                                    \\you might be able to resolve conflicts caused by ambiguous grammar using precedence or priority declaration
                                    \\
                                );
                                // Both LR(0) and SLR backends have `conflict_report`.
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
                                break :blk error.GrammarError;
                            },
                            else => |e| e,
                        };
                    },
                }
            },
        }
        try self.output.flush();
    }
};
