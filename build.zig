const std = @import("std");

pub fn build(b: *std.Build) void {
    // Default to Linux so `zig build` cross-compiles from macOS for syntax checking.
    // Tests still require `make docker-test` (can't run Linux binaries on macOS).
    const target = b.standardTargetOptions(.{
        .default_target = .{ .os_tag = .linux },
    });
    const optimize = b.standardOptimizeOption(.{});

    const yaml_dep = b.dependency("yaml", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zei",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "yaml", .module = yaml_dep.module("yaml") },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zei");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "yaml", .module = yaml_dep.module("yaml") },
            },
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
