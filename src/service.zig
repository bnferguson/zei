const std = @import("std");
const config = @import("config.zig");

/// Current state of a service
pub const ServiceState = enum {
    stopped,    // Service is not running
    starting,   // Service is being started
    running,    // Service is running normally
    stopping,   // Service is being stopped
    failed,     // Service failed to start or crashed
    exited,     // Service exited (may restart based on policy)

    pub fn toString(self: ServiceState) []const u8 {
        return switch (self) {
            .stopped => "stopped",
            .starting => "starting",
            .running => "running",
            .stopping => "stopping",
            .failed => "failed",
            .exited => "exited",
        };
    }
};

/// Runtime information about a service
pub const ServiceInfo = struct {
    /// Process ID (0 if not running)
    pid: std.posix.pid_t,

    /// Current state
    state: ServiceState,

    /// Time when service was started (Unix timestamp)
    start_time: i64,

    /// Number of times this service has been restarted
    restart_count: u32,

    /// Exit code from last termination (null if still running)
    exit_code: ?i32,

    /// Exit signal if terminated by signal (null if exited normally)
    exit_signal: ?u8,

    pub fn init() ServiceInfo {
        return ServiceInfo{
            .pid = 0,
            .state = .stopped,
            .start_time = 0,
            .restart_count = 0,
            .exit_code = null,
            .exit_signal = null,
        };
    }

    /// Mark service as started with given PID
    pub fn markStarted(self: *ServiceInfo, pid: std.posix.pid_t) void {
        self.pid = pid;
        self.state = .running;
        self.start_time = std.time.timestamp();
        self.exit_code = null;
        self.exit_signal = null;
    }

    /// Mark service as exited with exit code
    pub fn markExited(self: *ServiceInfo, exit_code: i32) void {
        self.pid = 0;
        self.state = .exited;
        self.exit_code = exit_code;
        self.exit_signal = null;
    }

    /// Mark service as killed by signal
    pub fn markSignaled(self: *ServiceInfo, signal: u8) void {
        self.pid = 0;
        self.state = .exited;
        self.exit_code = null;
        self.exit_signal = signal;
    }

    /// Mark service as failed
    pub fn markFailed(self: *ServiceInfo) void {
        self.pid = 0;
        self.state = .failed;
    }

    /// Increment restart counter
    pub fn incrementRestarts(self: *ServiceInfo) void {
        self.restart_count += 1;
    }

    /// Get uptime in seconds (0 if not running)
    pub fn getUptime(self: *ServiceInfo) i64 {
        if (self.state != .running or self.start_time == 0) {
            return 0;
        }
        return std.time.timestamp() - self.start_time;
    }

    /// Check if service is currently running
    pub fn isRunning(self: *ServiceInfo) bool {
        return self.state == .running and self.pid != 0;
    }
};

/// Combined service configuration and runtime info
pub const Service = struct {
    config: config.ServiceConfig,
    info: ServiceInfo,

    pub fn init(service_config: config.ServiceConfig) Service {
        return Service{
            .config = service_config,
            .info = ServiceInfo.init(),
        };
    }

    pub fn deinit(self: *Service, allocator: std.mem.Allocator) void {
        self.config.deinit(allocator);
    }
};

// Tests
test "ServiceState.toString" {
    try std.testing.expectEqualStrings("stopped", ServiceState.stopped.toString());
    try std.testing.expectEqualStrings("starting", ServiceState.starting.toString());
    try std.testing.expectEqualStrings("running", ServiceState.running.toString());
    try std.testing.expectEqualStrings("stopping", ServiceState.stopping.toString());
    try std.testing.expectEqualStrings("failed", ServiceState.failed.toString());
    try std.testing.expectEqualStrings("exited", ServiceState.exited.toString());
}

test "ServiceInfo initialization" {
    var info = ServiceInfo.init();
    try std.testing.expectEqual(@as(std.posix.pid_t, 0), info.pid);
    try std.testing.expectEqual(ServiceState.stopped, info.state);
    try std.testing.expectEqual(@as(i64, 0), info.start_time);
    try std.testing.expectEqual(@as(u32, 0), info.restart_count);
    try std.testing.expect(info.exit_code == null);
    try std.testing.expect(info.exit_signal == null);
    try std.testing.expect(!info.isRunning());
}

test "ServiceInfo mark started" {
    var info = ServiceInfo.init();

    info.markStarted(1234);

    try std.testing.expectEqual(@as(std.posix.pid_t, 1234), info.pid);
    try std.testing.expectEqual(ServiceState.running, info.state);
    try std.testing.expect(info.start_time > 0);
    try std.testing.expect(info.exit_code == null);
    try std.testing.expect(info.isRunning());
}

test "ServiceInfo mark exited" {
    var info = ServiceInfo.init();
    info.markStarted(1234);

    info.markExited(42);

    try std.testing.expectEqual(@as(std.posix.pid_t, 0), info.pid);
    try std.testing.expectEqual(ServiceState.exited, info.state);
    try std.testing.expectEqual(@as(i32, 42), info.exit_code.?);
    try std.testing.expect(info.exit_signal == null);
    try std.testing.expect(!info.isRunning());
}

test "ServiceInfo mark signaled" {
    var info = ServiceInfo.init();
    info.markStarted(1234);

    info.markSignaled(9); // SIGKILL

    try std.testing.expectEqual(@as(std.posix.pid_t, 0), info.pid);
    try std.testing.expectEqual(ServiceState.exited, info.state);
    try std.testing.expect(info.exit_code == null);
    try std.testing.expectEqual(@as(u8, 9), info.exit_signal.?);
    try std.testing.expect(!info.isRunning());
}

test "ServiceInfo restart counting" {
    var info = ServiceInfo.init();

    try std.testing.expectEqual(@as(u32, 0), info.restart_count);

    info.incrementRestarts();
    try std.testing.expectEqual(@as(u32, 1), info.restart_count);

    info.incrementRestarts();
    try std.testing.expectEqual(@as(u32, 2), info.restart_count);
}

test "ServiceInfo uptime calculation" {
    var info = ServiceInfo.init();

    // Not running - uptime should be 0
    try std.testing.expectEqual(@as(i64, 0), info.getUptime());

    // Mark as started
    info.markStarted(1234);

    // Sleep briefly to accumulate some uptime
    std.time.sleep(100 * std.time.ns_per_ms); // 100ms

    // Should have some uptime now
    const uptime = info.getUptime();
    try std.testing.expect(uptime >= 0);
}
