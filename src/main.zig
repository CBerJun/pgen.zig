const pgen = @import("pgen");
const std = @import("std");

fn displayDpSets(cfg: pgen.Cfg, sets: pgen.lr0.DpBasedSets) !void {
    for (0..cfg.nonterminals.count) |i| {
        std.debug.print("{}:", .{i});
        for (0..cfg.terminals.count) |j| {
            if (sets.get(@intCast(i)).isSet(j)) {
                std.debug.print(" {}", .{j});
            }
        }
        std.debug.print("\n", .{});
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Graph test:
    // const g: pgen.digraph.Digraph = try .empty(5, allocator);
    // defer g.free(allocator);
    // g.succ[0] = try allocator.alloc(u32, 2);
    // g.succ[0][0] = 1;
    // g.succ[0][1] = 2;
    // g.succ[1] = try allocator.alloc(u32, 1);
    // g.succ[1][0] = 0;

    const meta_cfg = pgen.meta_cfg;
    const g = try pgen.lr0.firstGraph(meta_cfg, allocator);
    defer g.free(allocator);

    const tarjan = try g.tarjanScc(allocator);
    defer tarjan.free(allocator);
    const reachability = try g.reachability(tarjan, allocator);
    defer reachability.free(allocator);
    for (0..g.n) |j| {
        const bs = reachability.get(@intCast(j), tarjan);
        for (0..g.n) |i| {
            std.debug.print("{}", .{@as(u16, @intFromBool(bs.isSet(i)))});
        }
        std.debug.print("\n", .{});
    }

    const def_use = try pgen.lr0.DefUse.fromCfg(meta_cfg, allocator);
    defer def_use.free(allocator);
    var nullable = try pgen.lr0.nullableAnalysis(meta_cfg, def_use, allocator);
    defer nullable.deinit(allocator);

    std.debug.print("nullable: ", .{});
    for (0..meta_cfg.nonterminals.count) |i| {
        std.debug.print("{}", .{@as(u16, @intFromBool(nullable.isSet(i)))});
    }
    std.debug.print("\n", .{});

    const first_set = try pgen.lr0.firstSet(meta_cfg, nullable, allocator);
    defer first_set.free(allocator);

    std.debug.print("first:\n", .{});
    try displayDpSets(meta_cfg, first_set);

    const follow_set = try pgen.lr0.followSet(meta_cfg, nullable, first_set, allocator);
    defer follow_set.free(allocator);

    std.debug.print("follow:\n", .{});
    try displayDpSets(meta_cfg, follow_set);

    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    // var backend: pgen.backends.Lr0ZigSwitchBackend = .{
    //     .emitter = .{
    //         .out = stdout,
    //     },
    // };
    var backend: pgen.backends.SlrBackend(
        pgen.backends.ZigSwitchActionHandler(void),
        pgen.backends.ZigSwitchGotoHandler,
    ) = .{
        .emitter = .{
            .out = stdout,
            .token_extra = &.{
                "payload: union {",
                "    word: []const u8,",
                "    str: struct {",
                "        content: []const u8,",
                "        suffix: []const u8,",
                "    },",
                "    none: void,",
                "},",
                "loc: Loc,",
                "",
                "/// `ln` and `col` are 0-indexed.",
                "pub const Loc = struct {ln: usize, col: usize};",
                "",
                "pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {",
                "    defer self.* = undefined;",
                "    switch (self.tag) {",
                "        .named.WORD => allocator.free(self.payload.word),",
                "        .named.STRING => {",
                "            allocator.free(self.payload.str.content);",
                "            if (self.payload.str.suffix.len > 0) allocator.free(self.payload.str.suffix);",
                "        },",
                "        else => {},",
                "    }",
                "}",
            },
            .cst_owns_token = true,
            // pgen will not work if anything exceeds u32 range since we
            // extensively use u32 type in source code (e.g. terminal count).
            .node_count_bits = 32,
        },
        .follow_sets = &follow_set,
        .action_handler = .{
            .grammar = &meta_cfg,
            .conflict_resolver = void{},
        },
        .goto_handler = .{},
    };
    defer backend.free();
    try pgen.lr0.lr0(meta_cfg, tarjan, reachability, @TypeOf(backend), &backend, allocator);

    // try pgen.makeZigRuntimeCommon(meta_cfg, .{}, stdout);
    try stdout.flush();
}
