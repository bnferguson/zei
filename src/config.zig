const std = @import("std");
const Yaml = @import("yaml").Yaml;

const config_size_max = 1024 * 1024; // 1 MiB
const max_services = 256;

const ns_per_m: u64 = 60 * std.time.ns_per_s;
const ns_per_h: u64 = 60 * ns_per_m;

const default_restart_delay_ns: u64 = std.time.ns_per_s;

pub const RestartPolicy = enum {
    always,
    @"on-failure",
    never,
};

pub const EnvironmentMap = std.StringArrayHashMapUnmanaged([]const u8);

pub const Service = struct {
    name: []const u8 = "",
    command: []const []const u8 = &.{},
    user: []const u8 = "root",
    group: []const u8 = "root",
    working_dir: ?[]const u8 = null,
    environment: ?EnvironmentMap = null,
    max_restarts: u32 = 0,
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

pub const Config = struct {
    version: []const u8,
    services: []Service,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Look up a service index by name. Returns null if not found.
    pub fn getServiceIndex(self: *const Config, name: []const u8) ?usize {
        for (self.services, 0..) |svc, i| {
            if (std.mem.eql(u8, svc.name, name)) return i;
        }
        return null;
    }

    /// Look up a service by name. Returns null if not found.
    pub fn getService(self: *const Config, name: []const u8) ?*const Service {
        const idx = self.getServiceIndex(name) orelse return null;
        return &self.services[idx];
    }
};

pub const LoadError = error{
    FileNotFound,
    ParseFailed,
};

/// Load and parse a YAML configuration file into a Config.
/// The caller must call Config.deinit() when done.
pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return LoadError.FileNotFound,
        else => return LoadError.ParseFailed,
    };
    defer file.close();

    const source = file.readToEndAllocOptions(allocator, config_size_max, null, @enumFromInt(0), 0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return LoadError.ParseFailed,
    };
    defer allocator.free(source);

    return loadFromSource(allocator, source);
}

/// Parse YAML source into a Config. Factored out for testability.
fn loadFromSource(allocator: std.mem.Allocator, source: [:0]const u8) !Config {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var yaml: Yaml = .{ .source = source };
    defer yaml.deinit(allocator);
    yaml.load(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return LoadError.ParseFailed,
    };

    if (yaml.docs.items.len == 0) return LoadError.ParseFailed;
    const root = yaml.docs.items[0].asMap() orelse return LoadError.ParseFailed;

    // Version (optional, defaults to "1.0").
    const version = if (root.get("version")) |v|
        try alloc.dupe(u8, v.asScalar() orelse return LoadError.ParseFailed)
    else
        "1.0";

    // Services map.
    const services_map = (root.get("services") orelse return LoadError.ParseFailed).asMap() orelse
        return LoadError.ParseFailed;

    if (services_map.keys().len > max_services) return LoadError.ParseFailed;

    var services: std.ArrayListUnmanaged(Service) = .{};
    for (services_map.keys(), services_map.values()) |svc_name, svc_value| {
        const svc_map = svc_value.asMap() orelse return LoadError.ParseFailed;
        const svc = try parseService(alloc, svc_name, svc_map);
        try services.append(alloc, svc);
    }

    return .{
        .version = version,
        .services = try services.toOwnedSlice(alloc),
        .arena = arena,
    };
}

// All allocations use the arena, so partial failure is cleaned up by the
// caller's errdefer arena.deinit().
fn parseService(alloc: std.mem.Allocator, name: []const u8, map: Yaml.Map) !Service {
    const command = try parseStringList(alloc, map.get("command")) orelse return LoadError.ParseFailed;
    try validateCommand(command);

    return .{
        .name = try alloc.dupe(u8, name),
        .command = command,
        .user = try dupeScalar(alloc, map.get("user")) orelse return LoadError.ParseFailed,
        .group = try dupeScalar(alloc, map.get("group")) orelse return LoadError.ParseFailed,
        .working_dir = try dupeScalar(alloc, map.get("working_dir")),
        .environment = try parseEnvironment(alloc, map.get("environment")),
        .max_restarts = parseUint(u32, map.get("max_restarts")) orelse 0,
        .restart = parseRestartPolicy(map.get("restart")),
        .restart_delay = try dupeScalar(alloc, map.get("restart_delay")),
        .depends_on = try parseStringList(alloc, map.get("depends_on")),
        .stdout = try dupeScalar(alloc, map.get("stdout")),
        .stderr = try dupeScalar(alloc, map.get("stderr")),
        .interval = try dupeScalar(alloc, map.get("interval")),
        .oneshot = parseBool(map.get("oneshot")),
        .json_logs = parseBool(map.get("json_logs")),
    };
}

// -- Validation --

/// Reject commands that use relative paths, path traversal, or null bytes.
/// Does NOT check file existence — the binary may be volume-mounted at runtime.
fn validateCommand(command: []const []const u8) LoadError!void {
    if (command.len == 0) return LoadError.ParseFailed;

    const exe = command[0];
    if (exe.len == 0 or exe[0] != '/') return LoadError.ParseFailed;
    if (std.mem.indexOf(u8, exe, "..") != null) return LoadError.ParseFailed;

    for (command) |arg| {
        if (std.mem.indexOfScalar(u8, arg, 0) != null) return LoadError.ParseFailed;
    }
}

// -- YAML extraction helpers --

fn dupeScalar(alloc: std.mem.Allocator, value: ?Yaml.Value) !?[]const u8 {
    const v = value orelse return null;
    const s = v.asScalar() orelse return null;
    return try alloc.dupe(u8, s);
}

fn dupeScalarOr(alloc: std.mem.Allocator, value: ?Yaml.Value, default: []const u8) ![]const u8 {
    return try dupeScalar(alloc, value) orelse default;
}

fn parseUint(comptime T: type, value: ?Yaml.Value) ?T {
    const s = (value orelse return null).asScalar() orelse return null;
    return std.fmt.parseInt(T, s, 10) catch null;
}

fn parseBool(value: ?Yaml.Value) bool {
    const s = (value orelse return false).asScalar() orelse return false;
    return std.mem.eql(u8, s, "true");
}

fn parseRestartPolicy(value: ?Yaml.Value) RestartPolicy {
    const s = (value orelse return .never).asScalar() orelse return .never;
    return std.meta.stringToEnum(RestartPolicy, s) orelse .never;
}

fn parseStringList(alloc: std.mem.Allocator, value: ?Yaml.Value) !?[]const []const u8 {
    const list = (value orelse return null).asList() orelse return null;
    const result = try alloc.alloc([]const u8, list.len);
    for (list, 0..) |item, i| {
        result[i] = try alloc.dupe(u8, item.asScalar() orelse return LoadError.ParseFailed);
    }
    return result;
}

fn parseEnvironment(alloc: std.mem.Allocator, value: ?Yaml.Value) !?EnvironmentMap {
    const map = (value orelse return null).asMap() orelse return null;
    var env: EnvironmentMap = .{};
    for (map.keys(), map.values()) |key, val| {
        const k = try alloc.dupe(u8, key);
        const v = try alloc.dupe(u8, val.asScalar() orelse return LoadError.ParseFailed);
        try env.put(alloc, k, v);
    }
    return env;
}

// -- Duration parsing --

/// Parse a duration string like "5s", "100ms", "2m", "1h" into nanoseconds.
/// Returns null if the string is not a valid duration or on overflow.
pub fn parseDuration(s: []const u8) ?u64 {
    if (s.len == 0) return null;

    var i: usize = 0;
    while (i < s.len and (s[i] >= '0' and s[i] <= '9')) : (i += 1) {}
    if (i == 0) return null;

    const value = std.fmt.parseInt(u64, s[0..i], 10) catch return null;
    const suffix = s[i..];

    const multiplier: u64 = if (std.mem.eql(u8, suffix, "ns"))
        1
    else if (std.mem.eql(u8, suffix, "ms"))
        std.time.ns_per_ms
    else if (std.mem.eql(u8, suffix, "s"))
        std.time.ns_per_s
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
    var cfg = try load(std.testing.allocator, "example/zei.yaml");
    defer cfg.deinit();

    try std.testing.expectEqualStrings("1.0", cfg.version);
    try std.testing.expect(cfg.services.len > 0);

    const echo = cfg.getService("echo") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("echo", echo.name);
    try std.testing.expectEqual(RestartPolicy.always, echo.restart);
    try std.testing.expectEqual(@as(u32, 3), echo.max_restarts);
    try std.testing.expectEqualStrings("appuser", echo.user);
    try std.testing.expect(echo.command.len > 0);
}

test "load parses oneshot service" {
    var cfg = try load(std.testing.allocator, "example/zei.yaml");
    defer cfg.deinit();

    const healthcheck = cfg.getService("healthcheck") orelse return error.TestUnexpectedResult;
    try std.testing.expect(healthcheck.oneshot);
    try std.testing.expect(healthcheck.interval != null);
    try std.testing.expect(healthcheck.depends_on != null);
}

test "load parses environment variables" {
    var cfg = try load(std.testing.allocator, "example/zei.yaml");
    defer cfg.deinit();

    const zombie = cfg.getService("zombie_maker") orelse return error.TestUnexpectedResult;
    const env = zombie.environment orelse return error.TestUnexpectedResult;
    const log_level = env.get("LOG_LEVEL") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("debug", log_level);
}

test "load parses json_logs flag" {
    var cfg = try load(std.testing.allocator, "example/zei.yaml");
    defer cfg.deinit();

    const json_logger = cfg.getService("json_logger") orelse return error.TestUnexpectedResult;
    try std.testing.expect(json_logger.json_logs);
}

test "load returns error for missing file" {
    const result = load(std.testing.allocator, "nonexistent.yaml");
    try std.testing.expectError(LoadError.FileNotFound, result);
}

test "validateCommand accepts absolute path" {
    try validateCommand(&.{"/bin/sh", "-c", "echo hello"});
}

test "validateCommand rejects relative path" {
    try std.testing.expectError(LoadError.ParseFailed, validateCommand(&.{"sh", "-c", "echo hello"}));
}

test "validateCommand rejects path traversal" {
    try std.testing.expectError(LoadError.ParseFailed, validateCommand(&.{"/usr/../bin/sh"}));
}

test "validateCommand rejects null byte in argument" {
    try std.testing.expectError(LoadError.ParseFailed, validateCommand(&.{"/bin/sh", "-c", "echo\x00injected"}));
}

test "validateCommand rejects empty command" {
    try std.testing.expectError(LoadError.ParseFailed, validateCommand(&.{}));
}

test "load rejects service missing user field" {
    const yaml =
        \\version: "1.0"
        \\services:
        \\  broken:
        \\    command: ["/bin/true"]
        \\    group: appuser
    ;
    const result = loadFromSource(std.testing.allocator, yaml);
    try std.testing.expectError(LoadError.ParseFailed, result);
}

test "load rejects service missing group field" {
    const yaml =
        \\version: "1.0"
        \\services:
        \\  broken:
        \\    command: ["/bin/true"]
        \\    user: appuser
    ;
    const result = loadFromSource(std.testing.allocator, yaml);
    try std.testing.expectError(LoadError.ParseFailed, result);
}

test "Service.restartDelayNs returns parsed delay" {
    const svc = Service{
        .restart_delay = "5s",
    };
    try std.testing.expectEqual(@as(u64, 5_000_000_000), svc.restartDelayNs());
}

test "Service.restartDelayNs returns default for no delay" {
    const svc = Service{};
    try std.testing.expectEqual(default_restart_delay_ns, svc.restartDelayNs());
}
