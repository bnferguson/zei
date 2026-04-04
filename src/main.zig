const std = @import("std");
const config = @import("config.zig");
const logger = @import("logger.zig");
const user_lookup = @import("user_lookup.zig");
const privilege = @import("privilege.zig");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    _ = gpa.allocator();
    _ = config;
    _ = logger;
    _ = user_lookup;
    _ = privilege;
}

comptime {
    _ = @import("config.zig");
    _ = @import("logger.zig");
    _ = @import("user_lookup.zig");
    _ = @import("privilege.zig");
}
