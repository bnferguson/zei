const std = @import("std");
const config = @import("config.zig");
const posix = std.posix;

pub const ServiceState = enum {
    stopped,
    starting,
    running,
    stopping,
    failed,

    pub fn label(self: ServiceState) [:0]const u8 {
        return @tagName(self);
    }
};

/// How a child process exited.
pub const ExitInfo = union(enum) {
    /// Normal termination with an exit code (0 = success).
    exited: u8,
    /// Killed by a signal.
    signaled: u32,

    pub fn isSuccess(self: ExitInfo) bool {
        return switch (self) {
            .exited => |code| code == 0,
            .signaled => false,
        };
    }
};

/// Per-service runtime status. Owned by the daemon, one per configured service.
pub const ServiceStatus = struct {
    name: []const u8,
    state: ServiceState,
    pid: ?posix.pid_t,
    exit_info: ?ExitInfo,
    restart_count: u32,
    started_at: ?i64,

    pub fn init(name: []const u8) ServiceStatus {
        return .{
            .name = name,
            .state = .stopped,
            .pid = null,
            .exit_info = null,
            .restart_count = 0,
            .started_at = null,
        };
    }

    /// Record that the service process has been spawned.
    pub fn recordStarted(self: *ServiceStatus, pid: posix.pid_t) void {
        std.debug.assert(self.state == .stopped or self.state == .starting or self.state == .failed);
        self.state = .running;
        self.pid = pid;
        self.exit_info = null;
        self.started_at = std.time.timestamp();
    }

    /// Mark the service as starting (before spawn attempt).
    pub fn recordStarting(self: *ServiceStatus) void {
        std.debug.assert(self.state == .stopped or self.state == .failed);
        self.state = .starting;
    }

    /// Mark the service as stopping (graceful shutdown in progress).
    pub fn recordStopping(self: *ServiceStatus) void {
        std.debug.assert(self.state == .running);
        self.state = .stopping;
    }

    /// Record that the process has exited. Transitions to .stopped by default;
    /// the caller may upgrade to .failed after evaluating the restart decision.
    pub fn recordExited(self: *ServiceStatus, info: ExitInfo) void {
        std.debug.assert(self.state == .running or self.state == .stopping);
        self.exit_info = info;
        self.pid = null;
        self.state = .stopped;
    }

    /// Mark the service as failed (e.g., after exhausting restart attempts).
    pub fn recordFailed(self: *ServiceStatus) void {
        std.debug.assert(self.state == .stopped);
        self.state = .failed;
    }

    /// Elapsed seconds since the service started, or null if not started.
    pub fn uptime(self: *const ServiceStatus) ?i64 {
        const started = self.started_at orelse return null;
        const now = std.time.timestamp();
        return now - started;
    }
};

/// What the daemon should do after a service exits.
pub const RestartDecision = enum {
    /// Restart the service after its configured delay.
    restart,
    /// Service is done; mark it stopped.
    stop,
    /// Max restarts exceeded; mark it failed.
    exhausted,
    /// Oneshot with interval: schedule the next run after the interval.
    schedule,
};

/// Decide what to do after a service exits.
///
/// Pure function — reads config and status, returns a decision. The caller
/// is responsible for acting on the decision (incrementing restart_count,
/// setting state, sleeping for delay, etc.).
pub fn evaluateRestart(
    svc: *const config.Service,
    status: *const ServiceStatus,
    exit_info: ExitInfo,
) RestartDecision {
    std.debug.assert(std.mem.eql(u8, svc.name, status.name));

    // Oneshot services have their own lifecycle.
    if (svc.oneshot) {
        if (svc.intervalNs() != null) return .schedule;
        return .stop;
    }

    // If the daemon is shutting down (stopping state), never restart.
    if (status.state == .stopping) return .stop;

    const should_restart = switch (svc.restart) {
        .always => true,
        .@"on-failure" => !exit_info.isSuccess(),
        .never => false,
    };

    if (!should_restart) return .stop;

    // Check max restart limit. max_restarts <= 0 means unlimited.
    if (svc.max_restarts > 0) {
        if (status.restart_count >= @as(u32, @intCast(svc.max_restarts))) {
            return .exhausted;
        }
    }

    return .restart;
}

// -- Tests --

fn testService(overrides: struct {
    restart: config.RestartPolicy = .never,
    max_restarts: i64 = 0,
    oneshot: bool = false,
    interval: ?[]const u8 = null,
}) config.Service {
    return .{
        .name = "test-svc",
        .command = &.{"/bin/true"},
        .restart = overrides.restart,
        .max_restarts = overrides.max_restarts,
        .oneshot = overrides.oneshot,
        .interval = overrides.interval,
    };
}

// -- ServiceStatus tests --

test "ServiceStatus.init starts in stopped state" {
    const status = ServiceStatus.init("echo");
    try std.testing.expectEqual(ServiceState.stopped, status.state);
    try std.testing.expect(status.pid == null);
    try std.testing.expect(status.exit_info == null);
    try std.testing.expectEqual(@as(u32, 0), status.restart_count);
    try std.testing.expect(status.started_at == null);
}

test "ServiceStatus transitions: stopped -> starting -> running -> exited" {
    var status = ServiceStatus.init("echo");

    status.recordStarting();
    try std.testing.expectEqual(ServiceState.starting, status.state);

    status.recordStarted(42);
    try std.testing.expectEqual(ServiceState.running, status.state);
    try std.testing.expectEqual(@as(posix.pid_t, 42), status.pid.?);
    try std.testing.expect(status.started_at != null);

    status.recordExited(.{ .exited = 0 });
    try std.testing.expectEqual(ServiceState.stopped, status.state);
    try std.testing.expect(status.pid == null);
    try std.testing.expect(status.exit_info != null);
    try std.testing.expect(status.exit_info.?.isSuccess());
}

test "ServiceStatus.recordFailed transitions stopped -> failed" {
    var status = ServiceStatus.init("flaky");
    status.recordStarted(10);
    status.recordExited(.{ .exited = 1 });
    try std.testing.expectEqual(ServiceState.stopped, status.state);

    status.recordFailed();
    try std.testing.expectEqual(ServiceState.failed, status.state);
}

test "ServiceStatus transitions: running -> stopping -> exited" {
    var status = ServiceStatus.init("web");
    status.recordStarted(100);

    status.recordStopping();
    try std.testing.expectEqual(ServiceState.stopping, status.state);

    status.recordExited(.{ .signaled = 15 });
    try std.testing.expect(status.pid == null);
    try std.testing.expectEqual(ServiceState.stopped, status.state);
}

// -- ExitInfo tests --

test "ExitInfo.isSuccess for zero exit code" {
    const info: ExitInfo = .{ .exited = 0 };
    try std.testing.expect(info.isSuccess());
}

test "ExitInfo.isSuccess false for non-zero exit code" {
    const info: ExitInfo = .{ .exited = 1 };
    try std.testing.expect(!info.isSuccess());
}

test "ExitInfo.isSuccess false for signal death" {
    const info: ExitInfo = .{ .signaled = 9 };
    try std.testing.expect(!info.isSuccess());
}

// -- evaluateRestart tests: restart=always --

test "restart=always: restart on success" {
    const svc = testService(.{ .restart = .always });
    const status = ServiceStatus.init("test-svc");
    const decision = evaluateRestart(&svc, &status, .{ .exited = 0 });
    try std.testing.expectEqual(RestartDecision.restart, decision);
}

test "restart=always: restart on failure" {
    const svc = testService(.{ .restart = .always });
    const status = ServiceStatus.init("test-svc");
    const decision = evaluateRestart(&svc, &status, .{ .exited = 1 });
    try std.testing.expectEqual(RestartDecision.restart, decision);
}

test "restart=always: restart on signal death" {
    const svc = testService(.{ .restart = .always });
    const status = ServiceStatus.init("test-svc");
    const decision = evaluateRestart(&svc, &status, .{ .signaled = 9 });
    try std.testing.expectEqual(RestartDecision.restart, decision);
}

// -- evaluateRestart tests: restart=on-failure --

test "restart=on-failure: stop on success" {
    const svc = testService(.{ .restart = .@"on-failure" });
    const status = ServiceStatus.init("test-svc");
    const decision = evaluateRestart(&svc, &status, .{ .exited = 0 });
    try std.testing.expectEqual(RestartDecision.stop, decision);
}

test "restart=on-failure: restart on non-zero exit" {
    const svc = testService(.{ .restart = .@"on-failure" });
    const status = ServiceStatus.init("test-svc");
    const decision = evaluateRestart(&svc, &status, .{ .exited = 42 });
    try std.testing.expectEqual(RestartDecision.restart, decision);
}

test "restart=on-failure: restart on signal death" {
    const svc = testService(.{ .restart = .@"on-failure" });
    const status = ServiceStatus.init("test-svc");
    const decision = evaluateRestart(&svc, &status, .{ .signaled = 11 });
    try std.testing.expectEqual(RestartDecision.restart, decision);
}

// -- evaluateRestart tests: restart=never --

test "restart=never: stop on success" {
    const svc = testService(.{});
    const status = ServiceStatus.init("test-svc");
    const decision = evaluateRestart(&svc, &status, .{ .exited = 0 });
    try std.testing.expectEqual(RestartDecision.stop, decision);
}

test "restart=never: stop on failure" {
    const svc = testService(.{});
    const status = ServiceStatus.init("test-svc");
    const decision = evaluateRestart(&svc, &status, .{ .exited = 1 });
    try std.testing.expectEqual(RestartDecision.stop, decision);
}

// -- evaluateRestart tests: max_restarts --

test "max_restarts: exhausted when limit reached" {
    const svc = testService(.{ .restart = .always, .max_restarts = 3 });
    var status = ServiceStatus.init("test-svc");
    status.restart_count = 3;
    const decision = evaluateRestart(&svc, &status, .{ .exited = 1 });
    try std.testing.expectEqual(RestartDecision.exhausted, decision);
}

test "max_restarts: restart when under limit" {
    const svc = testService(.{ .restart = .always, .max_restarts = 3 });
    var status = ServiceStatus.init("test-svc");
    status.restart_count = 2;
    const decision = evaluateRestart(&svc, &status, .{ .exited = 1 });
    try std.testing.expectEqual(RestartDecision.restart, decision);
}

test "max_restarts: zero means unlimited" {
    const svc = testService(.{ .restart = .always, .max_restarts = 0 });
    var status = ServiceStatus.init("test-svc");
    status.restart_count = 999;
    const decision = evaluateRestart(&svc, &status, .{ .exited = 1 });
    try std.testing.expectEqual(RestartDecision.restart, decision);
}

// -- evaluateRestart tests: stopping state --

test "stopping state: never restart regardless of policy" {
    const svc = testService(.{ .restart = .always });
    var status = ServiceStatus.init("test-svc");
    status.recordStarted(1);
    status.recordStopping();
    const decision = evaluateRestart(&svc, &status, .{ .exited = 0 });
    try std.testing.expectEqual(RestartDecision.stop, decision);
}

// -- evaluateRestart tests: oneshot --

test "oneshot without interval: stop" {
    const svc = testService(.{ .oneshot = true });
    const status = ServiceStatus.init("test-svc");
    const decision = evaluateRestart(&svc, &status, .{ .exited = 0 });
    try std.testing.expectEqual(RestartDecision.stop, decision);
}

test "oneshot with interval: schedule" {
    const svc = testService(.{ .oneshot = true, .interval = "30s" });
    const status = ServiceStatus.init("test-svc");
    const decision = evaluateRestart(&svc, &status, .{ .exited = 0 });
    try std.testing.expectEqual(RestartDecision.schedule, decision);
}

test "oneshot with interval: schedule even on failure" {
    const svc = testService(.{ .oneshot = true, .interval = "1m" });
    const status = ServiceStatus.init("test-svc");
    const decision = evaluateRestart(&svc, &status, .{ .exited = 1 });
    try std.testing.expectEqual(RestartDecision.schedule, decision);
}

// -- ServiceState.label tests --

test "ServiceState.label returns correct strings" {
    try std.testing.expectEqualStrings("stopped", ServiceState.stopped.label());
    try std.testing.expectEqualStrings("running", ServiceState.running.label());
    try std.testing.expectEqualStrings("failed", ServiceState.failed.label());
}
