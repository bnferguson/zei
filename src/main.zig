const std = @import("std");
const builtin = @import("builtin");

const VERSION = "0.1.0-dev";

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

    // Print startup banner
    std.debug.print("zei v{s} - Zig Privilege Escalating Init\n", .{VERSION});
    std.debug.print("Configuration: {s}\n", .{config_path.?});
    std.debug.print("PID: {d}\n\n", .{std.os.linux.getpid()});

    // Check if running as PID 1
    const pid = std.os.linux.getpid();
    if (pid == 1) {
        std.debug.print("Running as PID 1 (init process)\n", .{});
    } else {
        std.debug.print("Warning: Not running as PID 1 (current PID: {d})\n", .{pid});
    }

    // TODO: Load and parse configuration
    // TODO: Initialize service manager
    // TODO: Start all services
    // TODO: Enter main event loop
    // TODO: Handle signals (SIGTERM, SIGINT, SIGCHLD)

    std.debug.print("\nInit system initialized (MVP mode)\n", .{});
    std.debug.print("Press Ctrl+C to exit\n\n", .{});

    // For now, just wait for signals
    // In the full implementation, this will be the main event loop
    try waitForSignal();
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

fn waitForSignal() !void {
    // Set up signal handler for SIGTERM and SIGINT
    const signals = [_]std.posix.SIG{
        std.posix.SIG.TERM,
        std.posix.SIG.INT,
    };

    // Block these signals so we can wait for them
    var mask = std.posix.empty_sigset;
    for (signals) |sig| {
        std.os.linux.sigaddset(&mask, @intFromEnum(sig));
    }
    try std.posix.sigprocmask(std.posix.SIG.BLOCK, &mask, null);

    std.debug.print("Waiting for signals (SIGTERM or SIGINT)...\n", .{});

    // Wait for a signal
    const sig = std.os.linux.sigwaitinfo(&mask, null);

    std.debug.print("\nReceived signal: {d}\n", .{sig});
    std.debug.print("Shutting down...\n", .{});
}

test "version constant" {
    try std.testing.expect(VERSION.len > 0);
}

test "basic parsing" {
    // Add basic tests here as we build functionality
    try std.testing.expect(true);
}
