const std = @import("std");

pub fn build(b: *std.Build) void {
    // --- Config
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const demo = b.option(bool, "enable-demo", "install demo bridge rather than CLI") orelse false;

    // --- Compile core for host
    // Interestingly, to bootstrap pgen.zig we need to compile the core twice,
    // once for the host and once for the target. Though sometimes the host and
    // the target are the same.
    const host_optimize: std.builtin.OptimizeMode = .Debug;
    const core_mod_host = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = b.graph.host,
        .optimize = host_optimize,
    });
    const core_host_import: std.Build.Module.Import = .{ .name = "pgen_core", .module = core_mod_host };

    // --- Generate meta cfg
    const generate_meta_cfg_exe = b.addExecutable(.{
        .name = "generate_meta_cfg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bootstrap/generate_meta_cfg.zig"),
            .target = b.graph.host,
            .optimize = host_optimize,
        }),
    });
    const run_generate_meta_cfg = b.addRunArtifact(generate_meta_cfg_exe);
    const meta_cfg = run_generate_meta_cfg.addOutputFileArg("meta_cfg.zig");
    const meta_cfg_mod = b.createModule(.{
        .root_source_file = meta_cfg,
        .target = b.graph.host,
        .optimize = host_optimize,
        .imports = &.{core_host_import},
    });

    // --- Generate meta parser
    const generate_meta_parser_exe = b.addExecutable(.{
        .name = "generate_meta_parser",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bootstrap/generate_meta_parser.zig"),
            .target = b.graph.host,
            .optimize = host_optimize,
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
    if (!demo) {
        // CLI does not work on wasm32-freestanding.
        b.installArtifact(exe);
    }

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

    // --- Web playground/demo
    // You must target wasm32-freestanding.
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const demo_bridge = b.addExecutable(.{
        .name = "pgen-bridge",
        .root_module = b.createModule(.{
            .root_source_file = b.path("demo/bridge.zig"),
            .target = wasm_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pgen", .module = mod },
            },
        }),
    });
    demo_bridge.entry = .disabled; // No entry symbol
    demo_bridge.rdynamic = true; // For `export fn` to be exported in WASM automatically
    if (demo) {
        b.installArtifact(demo_bridge);
    }
}
