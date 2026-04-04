const std = @import("std");
const config = @import("config.zig");
const ipc = @import("ipc.zig");

const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

/// Run the CLI with the given arguments. Returns true if a command was
/// handled, false if the caller should fall through to daemon mode.
pub fn run(allocator: std.mem.Allocator, args: []const []const u8, config_path: []const u8) bool {
    if (args.len == 0) {
        // No subcommand — try listing from daemon, fall through if not running.
        listFromDaemon(allocator) catch return false;
        return true;
    }

    const command = args[0];

    if (std.mem.eql(u8, command, "list")) {
        listFromDaemon(allocator) catch {
            // Fallback to config-only listing.
            listFromConfig(allocator, config_path);
        };
    } else if (std.mem.eql(u8, command, "status")) {
        const service_name: ?[]const u8 = if (args.len > 1) args[1] else null;
        statusFromDaemon(allocator, service_name) catch {
            statusFromConfig(allocator, config_path, service_name);
        };
    } else if (std.mem.eql(u8, command, "restart")) {
        if (args.len < 2) {
            stderr.writeAll("error: restart requires a service name\n") catch {};
            return true;
        }
        restartService(allocator, args[1]);
    } else if (std.mem.eql(u8, command, "signal")) {
        if (args.len < 2) {
            stderr.writeAll("error: signal requires service:signal format (e.g., echo:HUP)\n") catch {};
            return true;
        }
        sendSignal(allocator, args[1]);
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "--help")) {
        printUsage();
    } else {
        stderr.print("unknown command: {s}\nrun 'zei help' for usage\n", .{command}) catch {};
    }

    return true;
}

// -- IPC-based commands --

fn listFromDaemon(allocator: std.mem.Allocator) !void {
    var resp = try ipc.sendRequest(allocator, .{ .command = "list" });
    defer resp.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp.slice(), .{}) catch {
        stderr.writeAll("error: invalid response from daemon\n") catch {};
        return;
    };
    defer parsed.deinit();

    printServiceTable(&parsed.value);
}

fn statusFromDaemon(allocator: std.mem.Allocator, service_name: ?[]const u8) !void {
    var resp = try ipc.sendRequest(allocator, .{
        .command = "status",
        .service = service_name,
    });
    defer resp.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp.slice(), .{}) catch {
        stderr.writeAll("error: invalid response from daemon\n") catch {};
        return;
    };
    defer parsed.deinit();

    // Single service detail view.
    if (service_name != null) {
        if (parsed.value.object.get("service")) |svc| {
            printServiceDetail(&svc);
            return;
        }
        if (parsed.value.object.get("message")) |msg| {
            switch (msg) {
                .string => |s| stderr.print("error: {s}\n", .{s}) catch {},
                else => {},
            }
        }
        return;
    }

    printServiceTable(&parsed.value);
}

fn restartService(allocator: std.mem.Allocator, name: []const u8) void {
    var resp = ipc.sendRequest(allocator, .{
        .command = "restart",
        .service = name,
    }) catch {
        stderr.writeAll("error: cannot connect to daemon\n") catch {};
        return;
    };
    defer resp.deinit();

    printResultMessage(allocator, resp.slice());
}

fn sendSignal(allocator: std.mem.Allocator, arg: []const u8) void {
    // Parse service:signal format.
    const colon = std.mem.indexOfScalar(u8, arg, ':') orelse {
        stderr.writeAll("error: format should be service:signal (e.g., echo:HUP)\n") catch {};
        return;
    };

    const service_name = arg[0..colon];
    const signal_name = arg[colon + 1 ..];

    if (service_name.len == 0 or signal_name.len == 0) {
        stderr.writeAll("error: format should be service:signal (e.g., echo:HUP)\n") catch {};
        return;
    }

    var resp = ipc.sendRequest(allocator, .{
        .command = "signal",
        .service = service_name,
        .signal = signal_name,
    }) catch {
        stderr.writeAll("error: cannot connect to daemon\n") catch {};
        return;
    };
    defer resp.deinit();

    printResultMessage(allocator, resp.slice());
}

// -- Config-only fallback --

fn listFromConfig(allocator: std.mem.Allocator, config_path: []const u8) void {
    var cfg = config.load(allocator, config_path) catch {
        stderr.writeAll("error: cannot load config\n") catch {};
        return;
    };
    defer cfg.deinit();

    printTableHeader();
    for (cfg.services) |svc| {
        stdout.print("{s:<20} {s:<10} {s:<8} {s:<12} {s:<10}\n", .{
            svc.name, "stopped", "-", "-", "-",
        }) catch {};
    }
}

fn statusFromConfig(allocator: std.mem.Allocator, config_path: []const u8, service_name: ?[]const u8) void {
    var cfg = config.load(allocator, config_path) catch {
        stderr.writeAll("error: cannot load config\n") catch {};
        return;
    };
    defer cfg.deinit();

    if (service_name) |name| {
        const svc = cfg.getService(name) orelse {
            stderr.print("error: service '{s}' not found\n", .{name}) catch {};
            return;
        };
        stdout.print("Service: {s}\n", .{svc.name}) catch {};
        stdout.print("Command: ", .{}) catch {};
        for (svc.command) |arg| {
            stdout.print("{s} ", .{arg}) catch {};
        }
        stdout.writeByte('\n') catch {};
        stdout.print("User: {s}\n", .{svc.user}) catch {};
        stdout.print("Group: {s}\n", .{svc.group}) catch {};
        stdout.print("Restart: {s}\n", .{@tagName(svc.restart)}) catch {};
        stdout.writeAll("Status: stopped (daemon not running)\n") catch {};
    } else {
        listFromConfig(allocator, config_path);
    }
}

// -- Output formatting --

fn printTableHeader() void {
    stdout.print("{s:<20} {s:<10} {s:<8} {s:<12} {s:<10}\n", .{
        "NAME", "STATUS", "PID", "RESTARTS", "UPTIME",
    }) catch {};
    stdout.print("{s:<20} {s:<10} {s:<8} {s:<12} {s:<10}\n", .{
        "----", "------", "---", "--------", "------",
    }) catch {};
}

fn printServiceTable(json: *const std.json.Value) void {
    const services = json.object.get("services") orelse return;
    const obj = switch (services) {
        .object => |*o| o,
        else => return,
    };

    printTableHeader();
    var it = obj.iterator();
    while (it.next()) |entry| {
        const svc = switch (entry.value_ptr.*) {
            .object => |*o| o,
            else => continue,
        };
        printServiceRow(entry.key_ptr.*, svc);
    }
}

fn printServiceRow(name: []const u8, svc: *const std.json.ObjectMap) void {
    const running = if (svc.get("running")) |v| switch (v) {
        .bool => |b| b,
        else => false,
    } else false;

    var pid_buf: [16]u8 = undefined;
    const pid_str = if (running) blk: {
        if (svc.get("pid")) |v| {
            switch (v) {
                .integer => |i| break :blk std.fmt.bufPrint(&pid_buf, "{d}", .{i}) catch "-",
                else => {},
            }
        }
        break :blk @as([]const u8, "-");
    } else @as([]const u8, "-");

    var restarts_buf: [16]u8 = undefined;
    const restarts_str = if (svc.get("restarts")) |v| switch (v) {
        .integer => |i| std.fmt.bufPrint(&restarts_buf, "{d}", .{i}) catch "-",
        else => "-",
    } else "-";

    var uptime_buf: [16]u8 = undefined;
    const uptime_str = if (running) blk: {
        if (svc.get("start_time")) |v| {
            switch (v) {
                .integer => |start| {
                    const now = std.time.timestamp();
                    const elapsed: u64 = if (now > start) @intCast(now - start) else 0;
                    break :blk formatUptime(&uptime_buf, elapsed);
                },
                else => {},
            }
        }
        break :blk @as([]const u8, "-");
    } else @as([]const u8, "-");

    const state_str = if (svc.get("state")) |v| switch (v) {
        .string => |s| s,
        else => if (running) "running" else "stopped",
    } else if (running) "running" else "stopped";

    stdout.print("{s:<20} {s:<10} {s:<8} {s:<12} {s:<10}\n", .{
        name, state_str, pid_str, restarts_str, uptime_str,
    }) catch {};
}

fn printServiceDetail(svc: *const std.json.Value) void {
    const obj = switch (svc.*) {
        .object => |*o| o,
        else => return,
    };

    const name = if (obj.get("name")) |v| switch (v) {
        .string => |s| s,
        else => "unknown",
    } else "unknown";

    stdout.print("Service: {s}\n", .{name}) catch {};

    const state = if (obj.get("state")) |v| switch (v) {
        .string => |s| s,
        else => "unknown",
    } else "unknown";
    stdout.print("State: {s}\n", .{state}) catch {};

    if (obj.get("pid")) |v| {
        switch (v) {
            .integer => |i| if (i > 0) {
                stdout.print("PID: {d}\n", .{i}) catch {};
            },
            else => {},
        }
    }

    if (obj.get("restarts")) |v| {
        switch (v) {
            .integer => |i| stdout.print("Restarts: {d}\n", .{i}) catch {},
            else => {},
        }
    }

    if (obj.get("start_time")) |v| {
        switch (v) {
            .integer => |start| {
                const now = std.time.timestamp();
                const elapsed: u64 = if (now > start) @intCast(now - start) else 0;
                var buf: [16]u8 = undefined;
                stdout.print("Uptime: {s}\n", .{formatUptime(&buf, elapsed)}) catch {};
            },
            else => {},
        }
    }
}

fn printResultMessage(allocator: std.mem.Allocator, resp: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp, .{}) catch {
        stderr.writeAll("error: invalid response\n") catch {};
        return;
    };
    defer parsed.deinit();

    const success = if (parsed.value.object.get("success")) |v| switch (v) {
        .bool => |b| b,
        else => false,
    } else false;

    const msg = if (parsed.value.object.get("message")) |v| switch (v) {
        .string => |s| s,
        else => "",
    } else "";

    if (success) {
        stdout.print("{s}\n", .{msg}) catch {};
    } else {
        stderr.print("error: {s}\n", .{msg}) catch {};
    }
}

/// Format elapsed seconds as human-readable uptime (e.g., "2d5h", "3h30m", "45m", "12s").
pub fn formatUptime(buf: *[16]u8, seconds: u64) []const u8 {
    if (seconds >= 86400) {
        const days = seconds / 86400;
        const hours = (seconds % 86400) / 3600;
        return std.fmt.bufPrint(buf, "{d}d{d}h", .{ days, hours }) catch "-";
    } else if (seconds >= 3600) {
        const hours = seconds / 3600;
        const mins = (seconds % 3600) / 60;
        return std.fmt.bufPrint(buf, "{d}h{d}m", .{ hours, mins }) catch "-";
    } else if (seconds >= 60) {
        const mins = seconds / 60;
        return std.fmt.bufPrint(buf, "{d}m", .{mins}) catch "-";
    } else {
        return std.fmt.bufPrint(buf, "{d}s", .{seconds}) catch "-";
    }
}

fn printUsage() void {
    stdout.writeAll(
        \\Usage: zei [command] [options]
        \\
        \\Commands:
        \\  list                List all services
        \\  status [service]    Show status of one or all services
        \\  restart <service>   Restart a service
        \\  signal <svc:SIG>    Send signal to a service (e.g., echo:HUP)
        \\  help                Show this help
        \\
        \\Options:
        \\  -c <path>           Config file path (default: /etc/zei/zei.toml)
        \\
        \\When run as PID 1, zei starts in daemon mode.
        \\Otherwise, it operates as a CLI client.
        \\
    ) catch {};
}

// -- Tests --

test "formatUptime seconds" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0s", formatUptime(&buf, 0));
    try std.testing.expectEqualStrings("30s", formatUptime(&buf, 30));
    try std.testing.expectEqualStrings("59s", formatUptime(&buf, 59));
}

test "formatUptime minutes" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("1m", formatUptime(&buf, 60));
    try std.testing.expectEqualStrings("5m", formatUptime(&buf, 300));
    try std.testing.expectEqualStrings("59m", formatUptime(&buf, 3599));
}

test "formatUptime hours" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("1h0m", formatUptime(&buf, 3600));
    try std.testing.expectEqualStrings("2h30m", formatUptime(&buf, 9000));
}

test "formatUptime days" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("1d0h", formatUptime(&buf, 86400));
    try std.testing.expectEqualStrings("3d12h", formatUptime(&buf, 302400));
}
