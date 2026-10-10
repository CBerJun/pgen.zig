const std = @import("std");

pub fn build(b: *std.Build) void {
    // --- Config
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Compile core for host
    // Interestingly, to bootstrap pgen.zig we need to compile the core twice,
    // once for the host and once for the target. Though sometimes the host and
    // the target are the same.
    const core_mod_host = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const core_host_import: std.Build.Module.Import = .{ .name = "pgen_core", .module = core_mod_host };

    // --- Generate meta cfg
    const generate_meta_cfg_exe = b.addExecutable(.{
        .name = "generate_meta_cfg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bootstrap/generate_meta_cfg.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_generate_meta_cfg = b.addRunArtifact(generate_meta_cfg_exe);
    const meta_cfg = run_generate_meta_cfg.addOutputFileArg("meta_cfg.zig");
    const meta_cfg_mod = b.createModule(.{
        .root_source_file = meta_cfg,
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{core_host_import},
    });

    // --- Generate meta parser
    const generate_meta_parser_exe = b.addExecutable(.{
        .name = "generate_meta_parser",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bootstrap/generate_meta_parser.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{
                core_host_import,
                .{ .name = "pgen_meta_cfg", .module = meta_cfg_mod },
            },
        }),
    });
    const run_generate_meta_parser = b.addRunArtifact(generate_meta_parser_exe);
    const meta_parser = run_generate_meta_parser.addOutputFileArg("meta_parser.zig");

    // --- Compile core the second time (for target)
    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_target_import: std.Build.Module.Import = .{ .name = "pgen_core", .module = core_mod };

    // --- Compile meta parser for target
    const meta_parser_mod = b.createModule(.{
        .root_source_file = meta_parser,
        .target = target,
        .optimize = optimize,
        .imports = &.{core_target_import},
    });

    // --- The actual module compiled for target platform
    const mod = b.addModule("pgen", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            core_target_import,
            .{ .name = "pgen_meta_parser", .module = meta_parser_mod },
        },
    });
    const exe = b.addExecutable(.{
        .name = "pgenzig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pgen", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    // --- Run directly or unit tests
    const run_step = b.step("run", "Run pgenzig CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // --- Build debug targets
    const run_generate_meta_cfg_step = b.step("gen-meta-cfg", "Generate meta CFG (debug)");
    run_generate_meta_cfg_step.dependOn(&run_generate_meta_cfg.step);
}
