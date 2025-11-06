const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options
    const target = b.standardTargetOptions(.{});

    // Standard optimization options
    const optimize = b.standardOptimizeOption(.{});

    // Add YAML dependency
    const yaml = b.dependency("yaml", .{
        .target = target,
        .optimize = optimize,
    });

    // Create the executable
    const exe = b.addExecutable(.{
        .name = "zei",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Enable static linking for container use
    exe.linkage = .static;

    // Add YAML module to executable
    exe.root_module.addImport("yaml", yaml.module("yaml"));

    // Install the executable
    b.installArtifact(exe);

    // Create a run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // Forward command-line arguments to the executable
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Create a run step that can be invoked with `zig build run`
    const run_step = b.step("run", "Run the zei init system");
    run_step.dependOn(&run_cmd.step);

    // Create test executable
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add YAML module to tests
    unit_tests.root_module.addImport("yaml", yaml.module("yaml"));

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Create a test step that can be invoked with `zig build test`
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
