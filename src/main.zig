const std = @import("std");
const config = @import("config.zig");
const logger = @import("logger.zig");
const user_lookup = @import("user_lookup.zig");
const privilege = @import("privilege.zig");
const process = @import("process.zig");
const monitor = @import("monitor.zig");
const reaper = @import("reaper.zig");

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
}

comptime {
    _ = @import("config.zig");
    _ = @import("logger.zig");
    _ = @import("user_lookup.zig");
    _ = @import("privilege.zig");
    _ = @import("process.zig");
    _ = @import("monitor.zig");
    _ = @import("reaper.zig");
}
