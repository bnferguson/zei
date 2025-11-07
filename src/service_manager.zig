const std = @import("std");
const config = @import("config.zig");
const service_mod = @import("service.zig");

const Service = service_mod.Service;
const ServiceState = service_mod.ServiceState;
const ServiceInfo = service_mod.ServiceInfo;

/// Manages all services and their runtime state
pub const ServiceManager = struct {
    allocator: std.mem.Allocator,
    services: std.StringHashMap(Service),
    pid_to_name: std.AutoHashMap(std.os.pid_t, []const u8),

    /// Initialize a new service manager
    pub fn init(allocator: std.mem.Allocator) ServiceManager {
        return ServiceManager{
            .allocator = allocator,
            .services = std.StringHashMap(Service).init(allocator),
            .pid_to_name = std.AutoHashMap(std.os.pid_t, []const u8).init(allocator),
        };
    }

    /// Clean up all resources
    pub fn deinit(self: *ServiceManager) void {
        var it = self.services.iterator();
        while (it.next()) |entry| {
            var service = entry.value_ptr;
            service.deinit(self.allocator);
        }
        self.services.deinit();
        self.pid_to_name.deinit();
    }

    /// Register a new service from configuration
    pub fn registerService(self: *ServiceManager, service_config: config.ServiceConfig) !void {
        const service = Service.init(service_config);
        try self.services.put(service.config.name, service);
    }

    /// Get service by name
    pub fn getServiceByName(self: *ServiceManager, name: []const u8) ?*Service {
        return self.services.getPtr(name);
    }

    /// Get service by PID
    pub fn getServiceByPid(self: *ServiceManager, pid: std.os.pid_t) ?*Service {
        const name = self.pid_to_name.get(pid) orelse return null;
        return self.services.getPtr(name);
    }

    /// Update service state
    pub fn updateState(self: *ServiceManager, name: []const u8, new_state: ServiceState) !void {
        const service = self.services.getPtr(name) orelse return error.ServiceNotFound;
        service.info.state = new_state;
    }

    /// Update service state by PID
    pub fn updateStateByPid(self: *ServiceManager, pid: std.os.pid_t, new_state: ServiceState) !void {
        const service = self.getServiceByPid(pid) orelse return error.ServiceNotFound;
        service.info.state = new_state;
    }

    /// Mark service as started with given PID
    pub fn markStarted(self: *ServiceManager, name: []const u8, pid: std.os.pid_t) !void {
        const service = self.services.getPtr(name) orelse return error.ServiceNotFound;
        service.info.markStarted(pid);

        // Track PID -> name mapping
        try self.pid_to_name.put(pid, service.config.name);
    }

    /// Mark service as exited
    pub fn markExited(self: *ServiceManager, pid: std.os.pid_t, exit_code: i32) !void {
        const service = self.getServiceByPid(pid) orelse return error.ServiceNotFound;
        service.info.markExited(exit_code);

        // Remove PID mapping
        _ = self.pid_to_name.remove(pid);
    }

    /// Mark service as signaled (killed by signal)
    pub fn markSignaled(self: *ServiceManager, pid: std.os.pid_t, signal: u8) !void {
        const service = self.getServiceByPid(pid) orelse return error.ServiceNotFound;
        service.info.markSignaled(signal);

        // Remove PID mapping
        _ = self.pid_to_name.remove(pid);
    }

    /// Mark service as failed
    pub fn markFailed(self: *ServiceManager, name: []const u8) !void {
        const service = self.services.getPtr(name) orelse return error.ServiceNotFound;
        service.info.markFailed();

        // Remove PID mapping if exists
        if (service.info.pid != 0) {
            _ = self.pid_to_name.remove(service.info.pid);
        }
    }

    /// Increment restart count for a service
    pub fn incrementRestartCount(self: *ServiceManager, name: []const u8) !void {
        const service = self.services.getPtr(name) orelse return error.ServiceNotFound;
        service.info.incrementRestarts();
    }

    /// Get all running services
    pub fn getAllRunningServices(self: *ServiceManager, allocator: std.mem.Allocator) ![]const *Service {
        var running_list = std.ArrayList(*Service).init(allocator);
        errdefer running_list.deinit(allocator);

        var it = self.services.iterator();
        while (it.next()) |entry| {
            const service = entry.value_ptr;
            if (service.info.isRunning()) {
                try running_list.append(service);
            }
        }

        return running_list.toOwnedSlice();
    }

    /// Get all services regardless of state
    pub fn getAllServices(self: *ServiceManager, allocator: std.mem.Allocator) ![]const *Service {
        var service_list = std.ArrayList(*Service).init(allocator);
        errdefer service_list.deinit(allocator);

        var it = self.services.iterator();
        while (it.next()) |entry| {
            try service_list.append(entry.value_ptr);
        }

        return service_list.toOwnedSlice();
    }

    /// Get count of services in a specific state
    pub fn countByState(self: *ServiceManager, state: ServiceState) usize {
        var stateCount: usize = 0;
        var it = self.services.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.info.state == state) {
                stateCount += 1;
            }
        }
        return count;
    }

    /// Get total number of registered services
    pub fn count(self: *ServiceManager) usize {
        return self.services.count();
    }

    /// Check if a service exists by name
    pub fn hasService(self: *ServiceManager, name: []const u8) bool {
        return self.services.contains(name);
    }

    /// Check if a PID is tracked
    pub fn hasPid(self: *ServiceManager, pid: std.os.pid_t) bool {
        return self.pid_to_name.contains(pid);
    }
};

// Tests
test "ServiceManager initialization" {
    var manager = ServiceManager.init(std.testing.allocator);
    defer manager.deinit();

    try std.testing.expectEqual(@as(usize, 0), manager.count());
}

test "ServiceManager register service" {
    var manager = ServiceManager.init(std.testing.allocator);
    defer manager.deinit();

    const allocator = std.testing.allocator;

    // Create a simple service config
    const name = try allocator.dupe(u8, "test-service");
    const cmd = try allocator.alloc([]const u8, 1);
    cmd[0] = try allocator.dupe(u8, "/bin/echo");

    const service_config = config.ServiceConfig{
        .name = name,
        .command = cmd,
        .user = null,
        .group = null,
        .working_dir = null,
        .env = null,
        .restart = .always,
    };

    try manager.registerService(service_config);

    try std.testing.expectEqual(@as(usize, 1), manager.count());
    try std.testing.expect(manager.hasService("test-service"));
}

test "ServiceManager get service by name" {
    var manager = ServiceManager.init(std.testing.allocator);
    defer manager.deinit();

    const allocator = std.testing.allocator;

    const name = try allocator.dupe(u8, "test-service");
    const cmd = try allocator.alloc([]const u8, 1);
    cmd[0] = try allocator.dupe(u8, "/bin/echo");

    const service_config = config.ServiceConfig{
        .name = name,
        .command = cmd,
        .user = null,
        .group = null,
        .working_dir = null,
        .env = null,
        .restart = .always,
    };

    try manager.registerService(service_config);

    const service = manager.getServiceByName("test-service");
    try std.testing.expect(service != null);
    try std.testing.expectEqualStrings("test-service", service.?.config.name);
}

test "ServiceManager mark started and get by PID" {
    var manager = ServiceManager.init(std.testing.allocator);
    defer manager.deinit();

    const allocator = std.testing.allocator;

    const name = try allocator.dupe(u8, "test-service");
    const cmd = try allocator.alloc([]const u8, 1);
    cmd[0] = try allocator.dupe(u8, "/bin/echo");

    const service_config = config.ServiceConfig{
        .name = name,
        .command = cmd,
        .user = null,
        .group = null,
        .working_dir = null,
        .env = null,
        .restart = .always,
    };

    try manager.registerService(service_config);

    // Mark as started
    try manager.markStarted("test-service", 1234);

    // Should be able to get by PID
    try std.testing.expect(manager.hasPid(1234));

    const service = manager.getServiceByPid(1234);
    try std.testing.expect(service != null);
    try std.testing.expectEqualStrings("test-service", service.?.config.name);
    try std.testing.expectEqual(@as(std.os.pid_t, 1234), service.?.info.pid);
    try std.testing.expectEqual(ServiceState.running, service.?.info.state);
}

test "ServiceManager mark exited" {
    var manager = ServiceManager.init(std.testing.allocator);
    defer manager.deinit();

    const allocator = std.testing.allocator;

    const name = try allocator.dupe(u8, "test-service");
    const cmd = try allocator.alloc([]const u8, 1);
    cmd[0] = try allocator.dupe(u8, "/bin/echo");

    const service_config = config.ServiceConfig{
        .name = name,
        .command = cmd,
        .user = null,
        .group = null,
        .working_dir = null,
        .env = null,
        .restart = .always,
    };

    try manager.registerService(service_config);
    try manager.markStarted("test-service", 1234);

    // Mark as exited
    try manager.markExited(1234, 42);

    // PID should no longer be tracked
    try std.testing.expect(!manager.hasPid(1234));

    // Service should be in exited state
    const service = manager.getServiceByName("test-service");
    try std.testing.expect(service != null);
    try std.testing.expectEqual(ServiceState.exited, service.?.info.state);
    try std.testing.expectEqual(@as(i32, 42), service.?.info.exit_code.?);
}

test "ServiceManager restart counting" {
    var manager = ServiceManager.init(std.testing.allocator);
    defer manager.deinit();

    const allocator = std.testing.allocator;

    const name = try allocator.dupe(u8, "test-service");
    const cmd = try allocator.alloc([]const u8, 1);
    cmd[0] = try allocator.dupe(u8, "/bin/echo");

    const service_config = config.ServiceConfig{
        .name = name,
        .command = cmd,
        .user = null,
        .group = null,
        .working_dir = null,
        .env = null,
        .restart = .always,
    };

    try manager.registerService(service_config);

    const service = manager.getServiceByName("test-service").?;
    try std.testing.expectEqual(@as(u32, 0), service.info.restart_count);

    try manager.incrementRestartCount("test-service");
    try std.testing.expectEqual(@as(u32, 1), service.info.restart_count);

    try manager.incrementRestartCount("test-service");
    try std.testing.expectEqual(@as(u32, 2), service.info.restart_count);
}

test "ServiceManager get all running services" {
    var manager = ServiceManager.init(std.testing.allocator);
    defer manager.deinit();

    const allocator = std.testing.allocator;

    // Register multiple services
    for (0..3) |i| {
        const name = try std.fmt.allocPrint(allocator, "service-{d}", .{i});
        const cmd = try allocator.alloc([]const u8, 1);
        cmd[0] = try allocator.dupe(u8, "/bin/echo");

        const service_config = config.ServiceConfig{
            .name = name,
            .command = cmd,
            .user = null,
            .group = null,
            .working_dir = null,
            .env = null,
            .restart = .always,
        };

        try manager.registerService(service_config);
    }

    // Start some services
    try manager.markStarted("service-0", 1000);
    try manager.markStarted("service-1", 1001);
    // service-2 remains stopped

    const running = try manager.getAllRunningServices(allocator);
    defer allocator.free(running);

    try std.testing.expectEqual(@as(usize, 2), running.len);
}

test "ServiceManager count by state" {
    var manager = ServiceManager.init(std.testing.allocator);
    defer manager.deinit();

    const allocator = std.testing.allocator;

    // Register services
    for (0..5) |i| {
        const name = try std.fmt.allocPrint(allocator, "service-{d}", .{i});
        const cmd = try allocator.alloc([]const u8, 1);
        cmd[0] = try allocator.dupe(u8, "/bin/echo");

        const service_config = config.ServiceConfig{
            .name = name,
            .command = cmd,
            .user = null,
            .group = null,
            .working_dir = null,
            .env = null,
            .restart = .always,
        };

        try manager.registerService(service_config);
    }

    // Initially all stopped
    try std.testing.expectEqual(@as(usize, 5), manager.countByState(.stopped));
    try std.testing.expectEqual(@as(usize, 0), manager.countByState(.running));

    // Start some services
    try manager.markStarted("service-0", 1000);
    try manager.markStarted("service-1", 1001);
    try manager.markStarted("service-2", 1002);

    try std.testing.expectEqual(@as(usize, 2), manager.countByState(.stopped));
    try std.testing.expectEqual(@as(usize, 3), manager.countByState(.running));
}
