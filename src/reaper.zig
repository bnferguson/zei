const std = @import("std");
const os = std.os;
const linux = std.os.linux;
const posix = std.posix;

const service_manager = @import("service_manager.zig");
const monitor = @import("monitor.zig");

const ServiceManager = service_manager.ServiceManager;

/// Information about a reaped process
pub const ReapedProcess = struct {
    pid: posix.pid_t,
    exit_code: ?i32,
    signal: ?u8,
    was_managed: bool,

    /// Parse wait status into exit code or signal
    pub fn fromWaitStatus(pid: posix.pid_t, status: u32, was_managed: bool) ReapedProcess {
        var exit_code: ?i32 = null;
        var signal: ?u8 = null;

        // Check if process exited normally
        if (linux.W.IFEXITED(status)) {
            exit_code = linux.W.EXITSTATUS(status);
        }
        // Check if process was terminated by signal
        else if (linux.W.IFSIGNALED(status)) {
            signal = @intCast(linux.W.TERMSIG(status));
        }

        return ReapedProcess{
            .pid = pid,
            .exit_code = exit_code,
            .signal = signal,
            .was_managed = was_managed,
        };
    }
};

/// Result of a reaping operation
pub const ReapResult = struct {
    processes: []ReapedProcess,
    restarts_needed: std.ArrayList([]const u8),
};

/// Set up signal handling for SIGCHLD
pub fn setupReaper() !void {
    // We'll use signalfd or manual signal handling in the event loop
    // For now, just ensure SIGCHLD isn't ignored
    var sa = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.NOCLDSTOP | posix.SA.RESTART,
    };

    try posix.sigaction(posix.SIG.CHLD, &sa, null);
}

/// Reap all exited child processes
/// This should be called when SIGCHLD is received or periodically
pub fn reapProcesses(
    allocator: std.mem.Allocator,
    manager: *ServiceManager,
) !ReapResult {
    var reaped_list: std.ArrayList(ReapedProcess) = .empty;
    errdefer reaped_list.deinit(allocator);

    var restarts_needed: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (restarts_needed.items) |name| {
            allocator.free(name);
        }
        restarts_needed.deinit(allocator);
    }

    // Reap all available child processes in a loop
    while (true) {
        var status: u32 = 0;

        // Use WNOHANG to not block
        const pid = linux.waitpid(-1, &status, linux.W.NOHANG);

        if (pid < 0) {
            // No more children or error
            const err = linux.getErrno(@as(usize, @bitCast(@as(isize, pid))));
            if (err == .CHILD) {
                // No child processes, this is normal
                break;
            } else if (err == .INTR) {
                // Interrupted by signal, try again
                continue;
            } else {
                // Some other error
                std.debug.print("waitpid error: {}\n", .{err});
                break;
            }
        } else if (pid == 0) {
            // No more processes to reap right now
            break;
        }

        // We reaped a process
        const was_managed = manager.hasPid(pid);
        const reaped = ReapedProcess.fromWaitStatus(pid, status, was_managed);

        if (was_managed) {
            // This is one of our managed services
            std.debug.print("Reaped managed process PID {d}\n", .{pid});

            // Handle the exit and check if restart is needed
            const should_restart = monitor.handleServiceExit(
                manager,
                pid,
                reaped.exit_code,
                reaped.signal,
            ) catch |err| {
                std.debug.print("Error handling service exit for PID {d}: {}\n", .{ pid, err });
                false;
            };

            if (should_restart) {
                // Get the service name before we lose the reference
                const service = manager.getServiceByName(getServiceNameByPid(manager, pid) orelse "") orelse continue;
                const name = try allocator.dupe(u8, service.config.name);
                try restarts_needed.append(allocator, name);
            }
        } else {
            // Orphaned process or unknown
            std.debug.print("Reaped orphaned process PID {d}\n", .{pid});
            logOrphanedProcess(reaped);
        }

        try reaped_list.append(allocator, reaped);
    }

    return ReapResult{
        .processes = try reaped_list.toOwnedSlice(allocator),
        .restarts_needed = restarts_needed,
    };
}

/// Get service name by PID (helper for reaping)
fn getServiceNameByPid(manager: *ServiceManager, pid: posix.pid_t) ?[]const u8 {
    const service = manager.getServiceByPid(pid) orelse return null;
    return service.config.name;
}

/// Log information about an orphaned process
fn logOrphanedProcess(reaped: ReapedProcess) void {
    if (reaped.exit_code) |code| {
        std.debug.print("Orphaned process {d} exited with code {d}\n", .{ reaped.pid, code });
    } else if (reaped.signal) |sig| {
        std.debug.print("Orphaned process {d} killed by signal {d}\n", .{ reaped.pid, sig });
    } else {
        std.debug.print("Orphaned process {d} exited with unknown status\n", .{reaped.pid});
    }
}

/// Free ReapResult resources
pub fn freeReapResult(allocator: std.mem.Allocator, result: ReapResult) void {
    allocator.free(result.processes);
    for (result.restarts_needed.items) |name| {
        allocator.free(name);
    }
    result.restarts_needed.deinit(allocator);
}

// Tests
test "ReapedProcess.fromWaitStatus - normal exit" {
    // Simulate exit status with code 0
    const status = linux.W.EXITCODE(0, 0);
    const reaped = ReapedProcess.fromWaitStatus(1234, status, true);

    try std.testing.expectEqual(@as(posix.pid_t, 1234), reaped.pid);
    try std.testing.expectEqual(@as(i32, 0), reaped.exit_code.?);
    try std.testing.expect(reaped.signal == null);
    try std.testing.expect(reaped.was_managed);
}

test "ReapedProcess.fromWaitStatus - error exit" {
    // Simulate exit status with code 1
    const status = linux.W.EXITCODE(1, 0);
    const reaped = ReapedProcess.fromWaitStatus(1234, status, true);

    try std.testing.expectEqual(@as(posix.pid_t, 1234), reaped.pid);
    try std.testing.expectEqual(@as(i32, 1), reaped.exit_code.?);
    try std.testing.expect(reaped.signal == null);
    try std.testing.expect(reaped.was_managed);
}

test "ReapedProcess.fromWaitStatus - signal termination" {
    // Simulate termination by SIGTERM (15)
    // W.TERMSIG extracts the signal, we need to create a status with signal
    const status: u32 = 15; // Simplified - signal in lower bits
    const reaped = ReapedProcess.fromWaitStatus(1234, status, false);

    try std.testing.expectEqual(@as(posix.pid_t, 1234), reaped.pid);
    try std.testing.expect(!reaped.was_managed);
}

test "setupReaper" {
    // Just verify it doesn't crash
    try setupReaper();
}

test "reapProcesses - no children" {
    var manager = ServiceManager.init(std.testing.allocator);
    defer manager.deinit();

    const result = try reapProcesses(std.testing.allocator, &manager);
    defer freeReapResult(std.testing.allocator, result);

    // Should have reaped 0 processes (no children running)
    try std.testing.expectEqual(@as(usize, 0), result.processes.len);
    try std.testing.expectEqual(@as(usize, 0), result.restarts_needed.items.len);
}

test "reapProcesses - with child process" {
    const allocator = std.testing.allocator;
    var manager = ServiceManager.init(allocator);
    defer manager.deinit();

    // Create a service config
    const name = try allocator.dupe(u8, "test-service");
    const cmd = try allocator.alloc([]const u8, 2);
    cmd[0] = try allocator.dupe(u8, "/bin/sh");
    cmd[1] = try allocator.dupe(u8, "-c");
    defer allocator.free(cmd[0]);
    defer allocator.free(cmd[1]);

    const config_mod = @import("config.zig");
    const service_config = config_mod.ServiceConfig{
        .name = name,
        .command = cmd,
        .user = null,
        .group = null,
        .working_dir = null,
        .env = null,
        .restart = .always,
    };

    try manager.registerService(service_config);

    // Fork a child process that exits immediately
    const pid = try posix.fork();
    if (pid == 0) {
        // Child - exit immediately
        os.exit(0);
    }

    // Parent - register the PID
    try manager.markStarted("test-service", pid);

    // Give child time to exit
    std.time.sleep(100 * std.time.ns_per_ms);

    // Reap processes
    const result = try reapProcesses(allocator, &manager);
    defer freeReapResult(allocator, result);

    // Should have reaped 1 process
    try std.testing.expectEqual(@as(usize, 1), result.processes.len);
    try std.testing.expectEqual(pid, result.processes[0].pid);
    try std.testing.expect(result.processes[0].was_managed);

    // Should want to restart (policy is .always)
    try std.testing.expectEqual(@as(usize, 1), result.restarts_needed.items.len);
}

test "reapProcesses - orphaned process" {
    const allocator = std.testing.allocator;
    var manager = ServiceManager.init(allocator);
    defer manager.deinit();

    // Fork an unmanaged child process
    const pid = try posix.fork();
    if (pid == 0) {
        // Child - exit immediately
        os.exit(42);
    }

    // Don't register this PID with the manager (orphan)

    // Give child time to exit
    std.time.sleep(100 * std.time.ns_per_ms);

    // Reap processes
    const result = try reapProcesses(allocator, &manager);
    defer freeReapResult(allocator, result);

    // Should have reaped the orphan
    try std.testing.expectEqual(@as(usize, 1), result.processes.len);
    try std.testing.expectEqual(pid, result.processes[0].pid);
    try std.testing.expect(!result.processes[0].was_managed);

    // Should not want any restarts (orphan)
    try std.testing.expectEqual(@as(usize, 0), result.restarts_needed.items.len);
}

test "logOrphanedProcess" {
    // Test various exit scenarios
    const exit_process = ReapedProcess{
        .pid = 1234,
        .exit_code = 42,
        .signal = null,
        .was_managed = false,
    };
    logOrphanedProcess(exit_process);

    const signal_process = ReapedProcess{
        .pid = 1235,
        .exit_code = null,
        .signal = 9,
        .was_managed = false,
    };
    logOrphanedProcess(signal_process);

    const unknown_process = ReapedProcess{
        .pid = 1236,
        .exit_code = null,
        .signal = null,
        .was_managed = false,
    };
    logOrphanedProcess(unknown_process);
}
