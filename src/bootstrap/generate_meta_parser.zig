//! Generates the meta parser.
const std = @import("std");
const pgen_core = @import("pgen_core");
const Cfg = pgen_core.cfg.Cfg;
const meta_cfg: Cfg = @import("pgen_meta_cfg").meta_cfg;

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

    var ds: pgen_core.lr0.DataStructures = .{ .allocator = allocator, .grammar = meta_cfg };
    defer ds.deinit();

    const follow_set = try ds.getFollowSet();
    const tarjan = try ds.getFirstTarjan();
    const reachability = try ds.getFirstReachability();

    var out_buffer: [512]u8 = undefined;
    var out_writer = file.writer(init.io, &out_buffer);
    const writer = &out_writer.interface;

    // var backend: pgen.backends.Lr0ZigSwitchBackend = .{
    //     .emitter = .{
    //         .out = writer,
    //     },
    // };
    var backend: pgen_core.backends.SlrBackend(
        pgen_core.backends.ZigSwitchActionHandler(void),
        pgen_core.backends.ZigSwitchGotoHandler,
    ) = .{
        .emitter = .{
            .out = writer,
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
                "pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {",
                "    switch (self.tag) {",
                "        .WORD => allocator.free(self.payload.word),",
                "        .STRING => {",
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
            .conflict_resolver = {},
        },
        .goto_handler = .{},
    };
    defer backend.free();
    try pgen_core.lr0.lr0(meta_cfg, tarjan, reachability, @TypeOf(backend), &backend, allocator);
    try writer.flush();
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(1);
}
