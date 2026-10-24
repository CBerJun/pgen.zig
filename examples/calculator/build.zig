const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The parser generator must target the host.
    const pgen = b.dependency("pgen", .{
        .target = b.graph.host,
        .optimize = optimize,
    });
    const pgen_cli = pgen.artifact("pgenzig");
    const run_pgen = b.addRunArtifact(pgen_cli);
    run_pgen.addArg("-o");
    const parser_src = run_pgen.addOutputFileArg("parser.zig");
    run_pgen.addArg("-token-extra");
    run_pgen.addArg(
        \\/// The number read of an INTEGER token, otherwise undefined.
        \\num: i32,
        \\
        \\pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        \\    // No dynamic memory to free.
        \\    _ = self;
        \\    _ = allocator;
        \\}
    );
    run_pgen.addFileArg(b.path("src/grammar.txt"));
    const parser_mod = b.createModule(.{
        .root_source_file = parser_src,
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "pgen_calculator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "parser", .module = parser_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
