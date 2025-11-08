const std = @import("std");
const config = @import("config.zig");
const service_mod = @import("service.zig");
const service_manager = @import("service_manager.zig");

const Service = service_mod.Service;
const ServiceState = service_mod.ServiceState;
const ServiceManager = service_manager.ServiceManager;
const RestartPolicy = config.RestartPolicy;

/// Determine if a service should be restarted based on its policy and exit status
pub fn shouldRestart(policy: RestartPolicy, exit_code: ?i32) bool {
    return switch (policy) {
        .always => true,
        .on_failure => blk: {
            // Restart if exit code is non-zero
            if (exit_code) |code| {
                break :blk code != 0;
            }
            // If we don't have an exit code (e.g., killed by signal), consider it a failure
            break :blk true;
        },
        .never => false,
    };
}

/// Handle a service exit event
pub fn handleServiceExit(
    manager: *ServiceManager,
    pid: std.posix.pid_t,
    exit_code: ?i32,
    signal: ?u8,
) !bool {
    // Find the service by PID
    const service = manager.getServiceByPid(pid) orelse {
        std.debug.print("Warning: Received exit for unknown PID {d}\n", .{pid});
        return false;
    };

    const service_name = service.config.name;

    // Update service state based on exit
    if (signal) |sig| {
        try manager.markSignaled(pid, sig);
        std.debug.print("[{s}] Service killed by signal {d}\n", .{ service_name, sig });
    } else if (exit_code) |code| {
        try manager.markExited(pid, code);
        if (code == 0) {
            std.debug.print("[{s}] Service exited successfully (code 0)\n", .{service_name});
        } else {
            std.debug.print("[{s}] Service exited with error (code {d})\n", .{ service_name, code });
        }
    } else {
        try manager.markExited(pid, -1);
        std.debug.print("[{s}] Service exited with unknown status\n", .{service_name});
    }

    // Check if we should restart
    const should_restart = shouldRestart(service.config.restart, exit_code);

    if (should_restart) {
        std.debug.print("[{s}] Restart policy: {s} - will restart\n", .{
            service_name,
            service.config.restart.toString(),
        });

        // Increment restart counter
        try manager.incrementRestartCount(service_name);

        const restart_count = service.info.restart_count;
        std.debug.print("[{s}] Restart count: {d}\n", .{ service_name, restart_count });

        return true; // Signal that restart is needed
    } else {
        std.debug.print("[{s}] Restart policy: {s} - will not restart\n", .{
            service_name,
            service.config.restart.toString(),
        });

        return false; // No restart needed
    }
}

/// Log service lifecycle event
pub fn logLifecycleEvent(service_name: []const u8, event: LifecycleEvent) void {
    switch (event) {
        .starting => std.debug.print("[{s}] Starting service...\n", .{service_name}),
        .started => |pid| std.debug.print("[{s}] Service started (PID {d})\n", .{ service_name, pid }),
        .stopping => std.debug.print("[{s}] Stopping service...\n", .{service_name}),
        .stopped => std.debug.print("[{s}] Service stopped\n", .{service_name}),
        .restarting => |count| std.debug.print("[{s}] Restarting service (restart #{d})...\n", .{ service_name, count }),
        .failed => |err_msg| std.debug.print("[{s}] Service failed: {s}\n", .{ service_name, err_msg }),
    }
}

/// Lifecycle events for logging
pub const LifecycleEvent = union(enum) {
    starting: void,
    started: std.posix.pid_t,
    stopping: void,
    stopped: void,
    restarting: u32,
    failed: []const u8,
};

// Tests
test "shouldRestart - always policy" {
    // Always policy should always return true
    try std.testing.expect(shouldRestart(.always, 0));
    try std.testing.expect(shouldRestart(.always, 1));
    try std.testing.expect(shouldRestart(.always, 127));
    try std.testing.expect(shouldRestart(.always, null));
}

test "shouldRestart - on_failure policy" {
    // Should restart on non-zero exit
    try std.testing.expect(shouldRestart(.on_failure, 1));
    try std.testing.expect(shouldRestart(.on_failure, 127));

    // Should NOT restart on zero exit
    try std.testing.expect(!shouldRestart(.on_failure, 0));

    // Should restart if no exit code (signal termination)
    try std.testing.expect(shouldRestart(.on_failure, null));
}

test "shouldRestart - never policy" {
    // Never policy should never return true
    try std.testing.expect(!shouldRestart(.never, 0));
    try std.testing.expect(!shouldRestart(.never, 1));
    try std.testing.expect(!shouldRestart(.never, 127));
    try std.testing.expect(!shouldRestart(.never, null));
}

test "handleServiceExit - exit with code 0, always restart" {
    var manager = ServiceManager.init(std.testing.allocator);
    defer manager.deinit();

    // Register a service
    const allocator = std.testing.allocator;
    const name = try allocator.dupe(u8, "test-service");
    const cmd = try allocator.alloc([]const u8, 1);
    cmd[0] = try allocator.dupe(u8, "/bin/echo");

    var service_config = config.ServiceConfig{
        .name = name,
        .command = cmd,
        .user = null,
        .group = null,
        .working_dir = null,
        .env = null,
        .restart = .always,
    };
    defer service_config.deinit(allocator);

    try manager.registerService(service_config);
    try manager.markStarted("test-service", 1234);

    // Handle exit with code 0
    const should_restart = try handleServiceExit(&manager, 1234, 0, null);

    try std.testing.expect(should_restart);

    // Service should be in exited state
    const service = manager.getServiceByName("test-service").?;
    try std.testing.expectEqual(ServiceState.exited, service.info.state);
    try std.testing.expectEqual(@as(i32, 0), service.info.exit_code.?);
    try std.testing.expectEqual(@as(u32, 1), service.info.restart_count);
}

test "handleServiceExit - exit with code 1, on_failure restart" {
    var manager = ServiceManager.init(std.testing.allocator);
    defer manager.deinit();

    const allocator = std.testing.allocator;
    const name = try allocator.dupe(u8, "test-service");
    const cmd = try allocator.alloc([]const u8, 1);
    cmd[0] = try allocator.dupe(u8, "/bin/echo");

    var service_config = config.ServiceConfig{
        .name = name,
        .command = cmd,
        .user = null,
        .group = null,
        .working_dir = null,
        .env = null,
        .restart = .on_failure,
    };
    defer service_config.deinit(allocator);

    try manager.registerService(service_config);
    try manager.markStarted("test-service", 1234);

    // Handle exit with code 1 (failure)
    const should_restart = try handleServiceExit(&manager, 1234, 1, null);

    try std.testing.expect(should_restart);

    const service = manager.getServiceByName("test-service").?;
    try std.testing.expectEqual(ServiceState.exited, service.info.state);
    try std.testing.expectEqual(@as(i32, 1), service.info.exit_code.?);
    try std.testing.expectEqual(@as(u32, 1), service.info.restart_count);
}

test "handleServiceExit - exit with code 0, on_failure restart" {
    var manager = ServiceManager.init(std.testing.allocator);
    defer manager.deinit();

    const allocator = std.testing.allocator;
    const name = try allocator.dupe(u8, "test-service");
    const cmd = try allocator.alloc([]const u8, 1);
    cmd[0] = try allocator.dupe(u8, "/bin/echo");

    var service_config = config.ServiceConfig{
        .name = name,
        .command = cmd,
        .user = null,
        .group = null,
        .working_dir = null,
        .env = null,
        .restart = .on_failure,
    };
    defer service_config.deinit(allocator);

    try manager.registerService(service_config);
    try manager.markStarted("test-service", 1234);

    // Handle exit with code 0 (success) - should NOT restart
    const should_restart = try handleServiceExit(&manager, 1234, 0, null);

    try std.testing.expect(!should_restart);

    const service = manager.getServiceByName("test-service").?;
    try std.testing.expectEqual(ServiceState.exited, service.info.state);
    try std.testing.expectEqual(@as(i32, 0), service.info.exit_code.?);
    try std.testing.expectEqual(@as(u32, 0), service.info.restart_count); // No restart, counter not incremented
}

test "handleServiceExit - exit with code 0, never restart" {
    var manager = ServiceManager.init(std.testing.allocator);
    defer manager.deinit();

    const allocator = std.testing.allocator;
    const name = try allocator.dupe(u8, "test-service");
    const cmd = try allocator.alloc([]const u8, 1);
    cmd[0] = try allocator.dupe(u8, "/bin/echo");

    var service_config = config.ServiceConfig{
        .name = name,
        .command = cmd,
        .user = null,
        .group = null,
        .working_dir = null,
        .env = null,
        .restart = .never,
    };
    defer service_config.deinit(allocator);

    try manager.registerService(service_config);
    try manager.markStarted("test-service", 1234);

    // Handle exit - should NOT restart
    const should_restart = try handleServiceExit(&manager, 1234, 0, null);

    try std.testing.expect(!should_restart);

    const service = manager.getServiceByName("test-service").?;
    try std.testing.expectEqual(ServiceState.exited, service.info.state);
    try std.testing.expectEqual(@as(u32, 0), service.info.restart_count);
}

test "handleServiceExit - killed by signal, always restart" {
    var manager = ServiceManager.init(std.testing.allocator);
    defer manager.deinit();

    const allocator = std.testing.allocator;
    const name = try allocator.dupe(u8, "test-service");
    const cmd = try allocator.alloc([]const u8, 1);
    cmd[0] = try allocator.dupe(u8, "/bin/echo");

    var service_config = config.ServiceConfig{
        .name = name,
        .command = cmd,
        .user = null,
        .group = null,
        .working_dir = null,
        .env = null,
        .restart = .always,
    };
    defer service_config.deinit(allocator);

    try manager.registerService(service_config);
    try manager.markStarted("test-service", 1234);

    // Handle signal termination (SIGTERM = 15)
    const should_restart = try handleServiceExit(&manager, 1234, null, 15);

    try std.testing.expect(should_restart);

    const service = manager.getServiceByName("test-service").?;
    try std.testing.expectEqual(ServiceState.exited, service.info.state);
    try std.testing.expectEqual(@as(u8, 15), service.info.exit_signal.?);
    try std.testing.expectEqual(@as(u32, 1), service.info.restart_count);
}

test "logLifecycleEvent" {
    // Just verify these don't crash
    logLifecycleEvent("test-service", .starting);
    logLifecycleEvent("test-service", .{ .started = 1234 });
    logLifecycleEvent("test-service", .stopping);
    logLifecycleEvent("test-service", .stopped);
    logLifecycleEvent("test-service", .{ .restarting = 3 });
    logLifecycleEvent("test-service", .{ .failed = "test error" });
}
