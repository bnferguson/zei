const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;

const config = @import("config.zig");
const service_mod = @import("service.zig");
const service_manager = @import("service_manager.zig");
const process = @import("process.zig");
const privilege = @import("privilege.zig");
const monitor = @import("monitor.zig");
const reaper = @import("reaper.zig");

const ServiceManager = service_manager.ServiceManager;
const Config = config.Config;

const VERSION = "0.1.0-mvp";

/// Global flag for shutdown
var shutdown_requested: bool = false;

pub fn main() !void {
    // Set up allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Parse options
    var config_path: ?[]const u8 = null;
    var show_help = false;
    var show_version = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            show_version = true;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: {s} requires a value\n", .{arg});
                return error.MissingConfigPath;
            }
            i += 1;
            config_path = args[i];
        } else {
            std.debug.print("Error: Unknown argument '{s}'\n", .{arg});
            return error.UnknownArgument;
        }
    }

    // Handle --version
    if (show_version) {
        std.debug.print("zei version {s}\n", .{VERSION});
        return;
    }

    // Handle --help
    if (show_help) {
        printHelp();
        return;
    }

    // Require config file
    if (config_path == null) {
        std.debug.print("Error: Configuration file required\n\n", .{});
        printHelp();
        return error.NoConfigFile;
    }

    // Run the init system
    try runInitSystem(allocator, config_path.?);
}

fn runInitSystem(allocator: std.mem.Allocator, config_path: []const u8) !void {
    // Print startup banner
    std.debug.print("====================================\n", .{});
    std.debug.print("zei v{s} - Zig Privilege Escalating Init\n", .{VERSION});
    std.debug.print("====================================\n", .{});
    std.debug.print("Configuration: {s}\n", .{config_path});
    std.debug.print("PID: {d}\n", .{linux.getpid()});

    // Check if running as PID 1
    const pid = linux.getpid();
    if (pid == 1) {
        std.debug.print("Status: Running as PID 1 (init process)\n", .{});
    } else {
        std.debug.print("Status: Running as PID {d} (development mode)\n", .{pid});
    }
    std.debug.print("====================================\n\n", .{});

    // Verify privilege escalation setup
    privilege.verifySetuidConfiguration() catch |err| {
        std.debug.print("Warning: Privilege configuration check failed: {}\n", .{err});
    };

    // Load configuration
    std.debug.print("[init] Loading configuration from {s}...\n", .{config_path});
    var cfg = config.parseConfigFile(allocator, config_path) catch |err| {
        std.debug.print("Error: Failed to parse configuration: {}\n", .{err});
        return err;
    };
    defer cfg.deinit();
    std.debug.print("[init] Loaded {d} service(s)\n\n", .{cfg.services.len});

    // Initialize service manager
    std.debug.print("[init] Initializing service manager...\n", .{});
    var manager = ServiceManager.init(allocator);
    defer manager.deinit();

    // Register all services
    for (cfg.services) |service_config| {
        try manager.registerService(service_config);
        std.debug.print("[init] Registered service: {s}\n", .{service_config.name});
    }
    std.debug.print("\n", .{});

    // Set up signal handling
    std.debug.print("[init] Setting up signal handlers...\n", .{});
    setupSignalHandlers();
    try reaper.setupReaper();
    std.debug.print("[init] Signal handlers ready\n\n", .{});

    // Start all services
    std.debug.print("[init] Starting all services...\n", .{});
    try startAllServices(allocator, &manager);
    std.debug.print("[init] All services started\n\n", .{});

    // Enter main event loop
    std.debug.print("[init] Entering main event loop\n", .{});
    std.debug.print("[init] Press Ctrl+C to initiate shutdown\n\n", .{});

    try mainEventLoop(allocator, &manager);

    // Shutdown
    std.debug.print("\n[init] Shutting down...\n", .{});
    try shutdownAllServices(&manager);
    std.debug.print("[init] Shutdown complete\n", .{});
}

fn startAllServices(allocator: std.mem.Allocator, manager: *ServiceManager) !void {
    const services = try manager.getAllServices(allocator);
    defer allocator.free(services);

    for (services) |service| {
        try startService(allocator, manager, service.config.name);
    }
}

fn startService(allocator: std.mem.Allocator, manager: *ServiceManager, service_name: []const u8) !void {
    const service = manager.getServiceByName(service_name) orelse return error.ServiceNotFound;

    monitor.logLifecycleEvent(service_name, .starting);

    // Update state to starting
    try manager.updateState(service_name, .starting);

    // Spawn the process
    const result = process.spawnProcess(allocator, &service.config) catch |err| {
        std.debug.print("[{s}] Failed to spawn: {}\n", .{ service_name, err });
        try manager.markFailed(service_name);
        monitor.logLifecycleEvent(service_name, .{ .failed = "spawn failed" });
        return err;
    };

    // Mark as started
    try manager.markStarted(service_name, result.pid);
    monitor.logLifecycleEvent(service_name, .{ .started = result.pid });

    // Note: pipes are left open for potential logging integration
    // For MVP, we just close them
    posix.close(result.pipes.stdout_read);
    posix.close(result.pipes.stderr_read);
}

fn setupSignalHandlers() void {
    // Block SIGTERM and SIGINT so we can handle them in the event loop
    var mask = posix.sigemptyset();
    posix.sigaddset(&mask, posix.SIG.TERM);
    posix.sigaddset(&mask, posix.SIG.INT);
    posix.sigaddset(&mask, posix.SIG.CHLD);

    posix.sigprocmask(posix.SIG.BLOCK, &mask, null);
}

fn mainEventLoop(allocator: std.mem.Allocator, manager: *ServiceManager) !void {
    var mask = posix.sigemptyset();
    posix.sigaddset(&mask, posix.SIG.TERM);
    posix.sigaddset(&mask, posix.SIG.INT);
    posix.sigaddset(&mask, posix.SIG.CHLD);

    while (!shutdown_requested) {
        // Wait for a signal with timeout
        var timeout = linux.timespec{
            .tv_sec = 1,
            .tv_nsec = 0,
        };

        const sig = linux.sigtimedwait(&mask, null, &timeout);

        if (sig < 0) {
            // Timeout or error - check for zombies anyway
            try handleReaping(allocator, manager);
            continue;
        }

        // Handle the signal
        if (sig == @intFromEnum(posix.SIG.TERM) or sig == @intFromEnum(posix.SIG.INT)) {
            const sig_name = if (sig == @intFromEnum(posix.SIG.TERM)) "SIGTERM" else "SIGINT";
            std.debug.print("\n[init] Received {s}, initiating shutdown...\n", .{sig_name});
            shutdown_requested = true;
        } else if (sig == @intFromEnum(posix.SIG.CHLD)) {
            // Child process exited
            try handleReaping(allocator, manager);
        }
    }
}

fn handleReaping(allocator: std.mem.Allocator, manager: *ServiceManager) !void {
    const result = try reaper.reapProcesses(allocator, manager);
    defer reaper.freeReapResult(allocator, result);

    // Restart services that need it
    for (result.restarts_needed.items) |service_name| {
        const service = manager.getServiceByName(service_name) orelse continue;

        monitor.logLifecycleEvent(service_name, .{ .restarting = service.info.restart_count });

        // Small delay before restart
        std.time.sleep(100 * std.time.ns_per_ms);

        // Restart the service
        startService(allocator, manager, service_name) catch |err| {
            std.debug.print("[{s}] Failed to restart: {}\n", .{ service_name, err });
        };
    }
}

fn shutdownAllServices(manager: *ServiceManager) !void {
    const allocator = manager.allocator;
    const services = try manager.getAllRunningServices(allocator);
    defer allocator.free(services);

    if (services.len == 0) {
        std.debug.print("[init] No services to stop\n", .{});
        return;
    }

    std.debug.print("[init] Stopping {d} running service(s)...\n", .{services.len});

    // Send SIGTERM to all running services
    for (services) |service| {
        if (service.info.pid > 0) {
            std.debug.print("[{s}] Sending SIGTERM to PID {d}\n", .{ service.config.name, service.info.pid });
            _ = linux.kill(service.info.pid, @intFromEnum(posix.SIG.TERM));
        }
    }

    // Wait for services to exit (with timeout)
    const timeout_ms = 5000; // 5 seconds
    const start = std.time.milliTimestamp();

    while (true) {
        const running_count = manager.countByState(.running);
        if (running_count == 0) {
            std.debug.print("[init] All services stopped gracefully\n", .{});
            break;
        }

        const elapsed = std.time.milliTimestamp() - start;
        if (elapsed > timeout_ms) {
            std.debug.print("[init] Timeout waiting for services, sending SIGKILL...\n", .{});

            // Send SIGKILL to remaining processes
            const remaining = try manager.getAllRunningServices(allocator);
            defer allocator.free(remaining);

            for (remaining) |service| {
                if (service.info.pid > 0) {
                    std.debug.print("[{s}] Sending SIGKILL to PID {d}\n", .{ service.config.name, service.info.pid });
                    _ = linux.kill(service.info.pid, @intFromEnum(posix.SIG.KILL));
                }
            }
            break;
        }

        // Reap any exited processes
        const result = try reaper.reapProcesses(allocator, manager);
        reaper.freeReapResult(allocator, result);

        std.time.sleep(100 * std.time.ns_per_ms);
    }
}

fn printHelp() void {
    std.debug.print(
        \\Usage: zei [OPTIONS]
        \\
        \\A lightweight init system for containers with privilege escalation support.
        \\
        \\Options:
        \\  -c, --config <path>   Path to configuration file (required)
        \\  -h, --help            Show this help message
        \\  -v, --version         Show version information
        \\
        \\Example:
        \\  zei --config /etc/zei.yaml
        \\
        \\For more information, visit: https://github.com/bnferguson/zei
        \\
    , .{});
}

test "version constant" {
    try std.testing.expect(VERSION.len > 0);
}
