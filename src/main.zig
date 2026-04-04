const std = @import("std");
const config = @import("config.zig");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    _ = gpa.allocator();
    _ = config;
}

comptime {
    _ = @import("config.zig");
}
