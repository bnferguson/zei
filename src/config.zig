const std = @import("std");
const toml = @import("toml");

const ns_per_ms: u64 = 1_000_000;
const ns_per_s: u64 = 1_000_000_000;
const ns_per_m: u64 = 60 * ns_per_s;
const ns_per_h: u64 = 60 * ns_per_m;

const default_restart_delay_ns: u64 = ns_per_s;

pub const RestartPolicy = enum {
    always,
    @"on-failure",
    never,
};

pub const Service = struct {
    name: []const u8 = "",
    command: []const []const u8,
    user: []const u8 = "root",
    group: []const u8 = "root",
    working_dir: ?[]const u8 = null,
    environment: ?toml.HashMap([]const u8) = null,
    // zig-toml maps all TOML integers to i64; validated in load().
    max_restarts: i64 = 0,
    restart: RestartPolicy = .never,
    restart_delay: ?[]const u8 = null,
    depends_on: ?[]const []const u8 = null,
    stdout: ?[]const u8 = null,
    stderr: ?[]const u8 = null,
    interval: ?[]const u8 = null,
    oneshot: bool = false,
    json_logs: bool = false,

    /// Return the restart delay in nanoseconds, or a default of 1 second.
    pub fn restartDelayNs(self: Service) u64 {
        if (self.restart_delay) |delay_str| {
            return parseDuration(delay_str) orelse default_restart_delay_ns;
        }
        return default_restart_delay_ns;
    }

    /// Return the oneshot interval in nanoseconds, or null if not set.
    pub fn intervalNs(self: Service) ?u64 {
        if (self.interval) |interval_str| {
            return parseDuration(interval_str);
        }
        return null;
    }
};

const TomlConfig = struct {
    version: []const u8 = "1.0",
    services: toml.HashMap(Service),
};

pub const Config = struct {
    version: []const u8,
    services: []Service,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Look up a service by name. Returns null if not found.
    pub fn getService(self: *const Config, name: []const u8) ?*const Service {
        for (self.services) |*svc| {
            if (std.mem.eql(u8, svc.name, name)) return svc;
        }
        return null;
    }
};

pub const LoadError = error{
    FileNotFound,
    ParseFailed,
};

/// Load and parse a TOML configuration file into a Config.
/// The caller must call Config.deinit() when done.
pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
    var parser = toml.Parser(TomlConfig).init(allocator);
    defer parser.deinit();

    var result = parser.parseFile(path) catch |err| {
        switch (err) {
            error.FileNotFound => return LoadError.FileNotFound,
            else => {
                std.log.err("config parse failed: {s}", .{@errorName(err)});
                return LoadError.ParseFailed;
            },
        }
    };
    errdefer result.arena.deinit();

    const toml_config = result.value;
    const arena_alloc = result.arena.allocator();

    // Build service slice from the HashMap, setting name from map key.
    var entries: std.ArrayListUnmanaged(Service) = .{};
    var it = toml_config.services.map.iterator();
    while (it.next()) |entry| {
        var svc = entry.value_ptr.*;
        svc.name = entry.key_ptr.*;
        try entries.append(arena_alloc, svc);
    }

    const services = try entries.toOwnedSlice(arena_alloc);
    std.debug.assert(services.len == toml_config.services.map.count());

    return .{
        .version = toml_config.version,
        .services = services,
        .arena = result.arena,
    };
}

// -- Duration parsing --

/// Parse a duration string like "5s", "100ms", "2m", "1h" into nanoseconds.
/// Returns null if the string is not a valid duration or on overflow.
pub fn parseDuration(s: []const u8) ?u64 {
    if (s.len == 0) return null;

    // Find where the numeric part ends.
    var i: usize = 0;
    while (i < s.len and (s[i] >= '0' and s[i] <= '9')) : (i += 1) {}
    std.debug.assert(i <= s.len);

    if (i == 0) return null;

    const value = std.fmt.parseInt(u64, s[0..i], 10) catch return null;
    const suffix = s[i..];

    const multiplier: u64 = if (std.mem.eql(u8, suffix, "ns"))
        1
    else if (std.mem.eql(u8, suffix, "ms"))
        ns_per_ms
    else if (std.mem.eql(u8, suffix, "s"))
        ns_per_s
    else if (std.mem.eql(u8, suffix, "m"))
        ns_per_m
    else if (std.mem.eql(u8, suffix, "h"))
        ns_per_h
    else
        return null;

    return std.math.mul(u64, value, multiplier) catch null;
}

// -- Tests --

test "parseDuration parses valid durations" {
    try std.testing.expectEqual(@as(u64, 5_000_000_000), parseDuration("5s").?);
    try std.testing.expectEqual(@as(u64, 100_000_000), parseDuration("100ms").?);
    try std.testing.expectEqual(@as(u64, 120_000_000_000), parseDuration("2m").?);
    try std.testing.expectEqual(@as(u64, 3_600_000_000_000), parseDuration("1h").?);
    try std.testing.expectEqual(@as(u64, 500), parseDuration("500ns").?);
}

test "parseDuration rejects invalid input" {
    try std.testing.expect(parseDuration("") == null);
    try std.testing.expect(parseDuration("abc") == null);
    try std.testing.expect(parseDuration("5x") == null);
    try std.testing.expect(parseDuration("s") == null);
}

test "parseDuration returns null on overflow" {
    try std.testing.expect(parseDuration("99999999999999999h") == null);
}

test "load parses valid config file" {
    var config = try load(std.testing.allocator, "example/zei.toml");
    defer config.deinit();

    try std.testing.expectEqualStrings("1.0", config.version);
    try std.testing.expect(config.services.len > 0);

    const echo = config.getService("echo") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("echo", echo.name);
    try std.testing.expectEqual(RestartPolicy.always, echo.restart);
    try std.testing.expectEqual(@as(i64, 3), echo.max_restarts);
    try std.testing.expectEqualStrings("appuser", echo.user);
    try std.testing.expect(echo.command.len > 0);
}

test "load parses oneshot service" {
    var config = try load(std.testing.allocator, "example/zei.toml");
    defer config.deinit();

    const healthcheck = config.getService("healthcheck") orelse return error.TestUnexpectedResult;
    try std.testing.expect(healthcheck.oneshot);
    try std.testing.expect(healthcheck.interval != null);
    try std.testing.expect(healthcheck.depends_on != null);
}

test "load parses environment variables" {
    var config = try load(std.testing.allocator, "example/zei.toml");
    defer config.deinit();

    const zombie = config.getService("zombie_maker") orelse return error.TestUnexpectedResult;
    const env = zombie.environment orelse return error.TestUnexpectedResult;
    const log_level = env.map.get("LOG_LEVEL") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("debug", log_level);
}

test "load parses json_logs flag" {
    var config = try load(std.testing.allocator, "example/zei.toml");
    defer config.deinit();

    const json_logger = config.getService("json_logger") orelse return error.TestUnexpectedResult;
    try std.testing.expect(json_logger.json_logs);
}

test "load returns error for missing file" {
    const result = load(std.testing.allocator, "nonexistent.toml");
    try std.testing.expectError(LoadError.FileNotFound, result);
}

test "Service.restartDelayNs returns parsed delay" {
    const svc = Service{
        .command = &.{},
        .restart_delay = "5s",
    };
    try std.testing.expectEqual(@as(u64, 5_000_000_000), svc.restartDelayNs());
}

test "Service.restartDelayNs returns default for no delay" {
    const svc = Service{
        .command = &.{},
    };
    try std.testing.expectEqual(default_restart_delay_ns, svc.restartDelayNs());
}
