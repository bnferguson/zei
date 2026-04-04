const std = @import("std");
const config = @import("config.zig");
const logger = @import("logger.zig");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    _ = gpa.allocator();
    _ = config;
    _ = logger;
}

comptime {
    _ = @import("config.zig");
    _ = @import("logger.zig");
}
