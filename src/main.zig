const std = @import("std");
const posix = std.posix;

const cli = @import("cli.zig");
const config = @import("config.zig");
const daemon = @import("daemon.zig");
const ipc = @import("ipc.zig");
const logger = @import("logger.zig");
const privilege = @import("privilege.zig");
const signal = @import("signal.zig");

const default_config_path = "/etc/zei/zei.yaml";
const default_app_user = "appuser";
const default_app_group = "appuser";

fn writeStderr(msg: []const u8) void {
    _ = posix.write(posix.STDERR_FILENO, msg) catch {};
}

pub fn main() void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    // Parse arguments.
    var args_iter = std.process.args();
    _ = args_iter.next(); // skip argv[0]

    var config_path: []const u8 = default_config_path;
    var cli_args: std.ArrayListUnmanaged([]const u8) = .{};

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-c")) {
            config_path = args_iter.next() orelse {
                writeStderr("error: -c requires a config path\n");
                posix.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-help")) {
            cli_args.append(allocator, "help") catch posix.exit(1);
        } else {
            cli_args.append(allocator, arg) catch posix.exit(1);
        }
    }

    // Try CLI commands first. If a command is handled, we're done.
    if (cli.run(allocator, cli_args.items, config_path)) return;

    // No CLI command handled — check if we should run as daemon.
    if (std.c.getpid() != 1) {
        writeStderr(
            "No zei daemon running. Available commands:\n" ++
                "  zei list                    List all services\n" ++
                "  zei status [service]        Show service status\n" ++
                "  zei restart <service>       Restart a service\n" ++
                "  zei signal <service:signal> Send signal to service\n" ++
                "\nTo run as daemon: zei must be run as PID 1\n",
        );
        posix.exit(1);
    }

    if (std.c.geteuid() != 0) {
        writeStderr("error: zei must run as root\n");
        posix.exit(1);
    }

    // -- Daemon mode --
    const log = logger.Logger.initFromEnv();
    log.info("zei starting as PID 1", .{});

    // Block signals before anything else.
    signal.blockManagedSignals();

    // Load config.
    var cfg = config.load(allocator, config_path) catch |err| {
        log.err("failed to load config: {s}", .{@errorName(err)});
        posix.exit(1);
    };
    defer cfg.deinit();

    log.info("loaded {d} services from {s}", .{ cfg.services.len, config_path });

    // Read app user/group from environment.
    const app_user = posix.getenv("ZEI_APP_USER") orelse default_app_user;
    const app_group = posix.getenv("ZEI_APP_GROUP") orelse default_app_group;

    // Initialize daemon.
    var d = daemon.Daemon.init(allocator, &cfg, app_user, app_group) catch |err| {
        log.err("daemon init failed: {s}", .{@errorName(err)});
        posix.exit(1);
    };
    defer d.deinit();

    // Start IPC server.
    var ipc_server = ipc.Server.init(log.scoped("ipc"), app_user, app_group) catch |err| {
        log.err("IPC server failed to start: {s}", .{@errorName(err)});
        posix.exit(1);
    };
    defer ipc_server.deinit();

    // Wire IPC server into daemon for polling.
    d.ipc_server = &ipc_server;

    // Start all services.
    d.startAll();

    // Drop privileges after starting services.
    privilege.drop(app_user, app_group) catch |err| {
        log.err("failed to drop privileges: {s}", .{@errorName(err)});
        posix.exit(1);
    };
    log.info("dropped privileges to {s}:{s}", .{ app_user, app_group });

    // Enter main loop.
    log.info("entering signal loop", .{});
    d.run();

    log.info("zei shutdown complete", .{});
}

comptime {
    _ = @import("config.zig");
    _ = @import("logger.zig");
    _ = @import("user_lookup.zig");
    _ = @import("pidfd.zig");
    _ = @import("privilege.zig");
    _ = @import("process.zig");
    _ = @import("monitor.zig");
    _ = @import("reaper.zig");
    _ = @import("signal.zig");
    _ = @import("daemon.zig");
    _ = @import("service_logger.zig");
    _ = @import("ipc.zig");
    _ = @import("cli.zig");
}
