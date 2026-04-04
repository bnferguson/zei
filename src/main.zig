const std = @import("std");
const config = @import("config.zig");
const logger = @import("logger.zig");
const user_lookup = @import("user_lookup.zig");
const privilege = @import("privilege.zig");
const process = @import("process.zig");
const monitor = @import("monitor.zig");
const reaper = @import("reaper.zig");
const signal = @import("signal.zig");
const daemon = @import("daemon.zig");
const service_logger = @import("service_logger.zig");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    _ = gpa.allocator();
    _ = config;
    _ = logger;
    _ = user_lookup;
    _ = privilege;
    _ = process;
    _ = monitor;
    _ = reaper;
    _ = signal;
    _ = daemon;
    _ = service_logger;
}

comptime {
    _ = @import("config.zig");
    _ = @import("logger.zig");
    _ = @import("user_lookup.zig");
    _ = @import("privilege.zig");
    _ = @import("process.zig");
    _ = @import("monitor.zig");
    _ = @import("reaper.zig");
    _ = @import("signal.zig");
    _ = @import("daemon.zig");
    _ = @import("service_logger.zig");
}
