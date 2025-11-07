const std = @import("std");
const Yaml = @import("yaml").Yaml;

/// Restart policy for services
pub const RestartPolicy = enum {
    always,
    on_failure,
    never,

    pub fn fromString(s: []const u8) ?RestartPolicy {
        if (std.mem.eql(u8, s, "always")) return .always;
        if (std.mem.eql(u8, s, "on-failure")) return .on_failure;
        if (std.mem.eql(u8, s, "never")) return .never;
        return null;
    }

    pub fn toString(self: RestartPolicy) []const u8 {
        return switch (self) {
            .always => "always",
            .on_failure => "on-failure",
            .never => "never",
        };
    }
};

/// Service configuration from YAML
pub const ServiceConfig = struct {
    name: []const u8,
    command: []const []const u8, // Array of command and arguments
    user: ?[]const u8 = null,
    group: ?[]const u8 = null,
    working_dir: ?[]const u8 = null,
    env: ?std.StringHashMap([]const u8) = null,
    restart: RestartPolicy = .always,

    pub fn deinit(self: *ServiceConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.command) |arg| {
            allocator.free(arg);
        }
        allocator.free(self.command);

        if (self.user) |user| allocator.free(user);
        if (self.group) |group| allocator.free(group);
        if (self.working_dir) |wd| allocator.free(wd);

        if (self.env) |*env_map| {
            var it = env_map.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            env_map.deinit();
        }
    }
};

/// Top-level configuration
pub const Config = struct {
    services: []ServiceConfig,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Config) void {
        for (self.services) |*service| {
            service.deinit(self.allocator);
        }
        self.allocator.free(self.services);
    }
};

/// Parse configuration file
pub fn parseConfigFile(allocator: std.mem.Allocator, file_path: []const u8) !Config {
    // Read the file
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    const content = try allocator.alloc(u8, file_size);
    defer allocator.free(content);

    const bytes_read = try file.readAll(content);
    if (bytes_read != file_size) {
        return error.IncompleteRead;
    }

    return parseConfig(allocator, content);
}

/// Parse configuration from YAML string
pub fn parseConfig(allocator: std.mem.Allocator, yaml_content: []const u8) !Config {
    var yaml: Yaml = .{ .source = yaml_content };
    try yaml.load(allocator);

    if (yaml.docs.items.len == 0) {
        return error.EmptyConfiguration;
    }

    const doc = yaml.docs.items[0];

    // Get the root mapping
    const root_map = doc.map;

    // Get the services array
    const services_node = root_map.get("services") orelse {
        return error.MissingServicesKey;
    };

    if (services_node != .list) {
        return error.ServicesNotArray;
    }

    const services_list = services_node.list;
    var services: std.ArrayList(ServiceConfig) = .empty;
    try services.ensureTotalCapacity(allocator, services_list.len);
    errdefer {
        for (services.items) |*service| {
            service.deinit(allocator);
        }
        services.deinit(allocator);
    }

    // Parse each service
    for (services_list) |service_node| {
        if (service_node != .map) {
            return error.ServiceNotMapping;
        }

        const service_map = service_node.map;

        // Parse required field: name
        const name_node = service_map.get("name") orelse {
            return error.MissingServiceName;
        };
        if (name_node != .scalar) {
            return error.ServiceNameNotString;
        }
        const name = try allocator.dupe(u8, name_node.scalar);
        errdefer allocator.free(name);

        // Parse required field: command (can be string or array)
        const command_node = service_map.get("command") orelse {
            return error.MissingServiceCommand;
        };

        const command = try parseCommand(allocator, command_node);
        errdefer {
            for (command) |arg| allocator.free(arg);
            allocator.free(command);
        }

        // Parse optional fields
        const user = if (service_map.get("user")) |node|
            if (node == .scalar) try allocator.dupe(u8, node.scalar) else null
        else
            null;
        errdefer if (user) |u| allocator.free(u);

        const group = if (service_map.get("group")) |node|
            if (node == .scalar) try allocator.dupe(u8, node.scalar) else null
        else
            null;
        errdefer if (group) |g| allocator.free(g);

        const working_dir = if (service_map.get("working_dir")) |node|
            if (node == .scalar) try allocator.dupe(u8, node.scalar) else null
        else
            null;
        errdefer if (working_dir) |wd| allocator.free(wd);

        // Parse environment variables
        const env = if (service_map.get("env")) |env_node| blk: {
            if (env_node != .map) break :blk null;

            var env_map = std.StringHashMap([]const u8).init(allocator);
            errdefer env_map.deinit();

            var it = env_node.map.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key);

                const val_node = entry.value_ptr.*;
                if (val_node != .scalar) continue;

                const value = try allocator.dupe(u8, val_node.scalar);
                errdefer allocator.free(value);

                try env_map.put(key, value);
            }

            break :blk env_map;
        } else null;
        errdefer if (env) |*e| {
            var it = e.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
            }
            e.deinit();
        };

        // Parse restart policy
        const restart = if (service_map.get("restart")) |node| blk: {
            if (node != .scalar) break :blk RestartPolicy.always;
            const policy = RestartPolicy.fromString(node.scalar) orelse {
                std.debug.print("Warning: Invalid restart policy '{s}' for service '{s}', defaulting to 'always'\n", .{ node.scalar, name });
                break :blk RestartPolicy.always;
            };
            break :blk policy;
        } else RestartPolicy.always;

        // Create service config
        const service_config = ServiceConfig{
            .name = name,
            .command = command,
            .user = user,
            .group = group,
            .working_dir = working_dir,
            .env = env,
            .restart = restart,
        };

        try services.append(allocator, service_config);
    }

    return Config{
        .services = try services.toOwnedSlice(),
        .allocator = allocator,
    };
}

/// Parse command field (handles both string and array formats)
fn parseCommand(allocator: std.mem.Allocator, command_node: anytype) ![][]const u8 {
    if (command_node == .scalar) {
        // Command is a string - split on whitespace
        var args: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (args.items) |arg| allocator.free(arg);
            args.deinit(allocator);
        }

        var it = std.mem.tokenizeAny(u8, command_node.scalar, " \t\n");
        while (it.next()) |token| {
            const arg = try allocator.dupe(u8, token);
            try args.append(allocator, arg);
        }

        if (args.items.len == 0) {
            return error.EmptyCommand;
        }

        return args.toOwnedSlice();
    } else if (command_node == .list) {
        // Command is an array
        const cmd_list = command_node.list;
        if (cmd_list.items.len == 0) {
            return error.EmptyCommand;
        }

        var args: std.ArrayList([]const u8) = .empty;
        try args.ensureTotalCapacity(allocator, cmd_list.items.len);
        errdefer {
            for (args.items) |arg| allocator.free(arg);
            args.deinit(allocator);
        }

        for (cmd_list.items) |item| {
            if (item != .scalar) {
                return error.CommandArrayNotStrings;
            }
            const arg = try allocator.dupe(u8, item.scalar);
            try args.append(allocator, arg);
        }

        return args.toOwnedSlice();
    } else {
        return error.CommandInvalidType;
    }
}

// Tests
test "RestartPolicy.fromString" {
    try std.testing.expectEqual(RestartPolicy.always, RestartPolicy.fromString("always").?);
    try std.testing.expectEqual(RestartPolicy.on_failure, RestartPolicy.fromString("on-failure").?);
    try std.testing.expectEqual(RestartPolicy.never, RestartPolicy.fromString("never").?);
    try std.testing.expect(RestartPolicy.fromString("invalid") == null);
}

test "RestartPolicy.toString" {
    try std.testing.expectEqualStrings("always", RestartPolicy.always.toString());
    try std.testing.expectEqualStrings("on-failure", RestartPolicy.on_failure.toString());
    try std.testing.expectEqualStrings("never", RestartPolicy.never.toString());
}

test "parse simple config" {
    const yaml_content =
        \\services:
        \\  - name: test-service
        \\    command: /bin/echo hello
        \\    restart: always
    ;

    var config = try parseConfig(std.testing.allocator, yaml_content);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.services.len);
    try std.testing.expectEqualStrings("test-service", config.services[0].name);
    try std.testing.expectEqual(@as(usize, 2), config.services[0].command.len);
    try std.testing.expectEqualStrings("/bin/echo", config.services[0].command[0]);
    try std.testing.expectEqualStrings("hello", config.services[0].command[1]);
    try std.testing.expectEqual(RestartPolicy.always, config.services[0].restart);
}

test "parse config with optional fields" {
    const yaml_content =
        \\services:
        \\  - name: web-service
        \\    command: ["/usr/bin/nginx", "-g", "daemon off;"]
        \\    user: www-data
        \\    group: www-data
        \\    working_dir: /var/www
        \\    restart: on-failure
        \\    env:
        \\      PORT: "8080"
        \\      LOG_LEVEL: info
    ;

    var config = try parseConfig(std.testing.allocator, yaml_content);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.services.len);

    const service = config.services[0];
    try std.testing.expectEqualStrings("web-service", service.name);
    try std.testing.expectEqual(@as(usize, 3), service.command.len);
    try std.testing.expectEqualStrings("/usr/bin/nginx", service.command[0]);
    try std.testing.expectEqualStrings("www-data", service.user.?);
    try std.testing.expectEqualStrings("www-data", service.group.?);
    try std.testing.expectEqualStrings("/var/www", service.working_dir.?);
    try std.testing.expectEqual(RestartPolicy.on_failure, service.restart);

    try std.testing.expect(service.env != null);
    try std.testing.expectEqualStrings("8080", service.env.?.get("PORT").?);
    try std.testing.expectEqualStrings("info", service.env.?.get("LOG_LEVEL").?);
}

test "missing required fields" {
    const yaml_no_name =
        \\services:
        \\  - command: /bin/echo
    ;
    try std.testing.expectError(error.MissingServiceName, parseConfig(std.testing.allocator, yaml_no_name));

    const yaml_no_command =
        \\services:
        \\  - name: test
    ;
    try std.testing.expectError(error.MissingServiceCommand, parseConfig(std.testing.allocator, yaml_no_command));

    const yaml_no_services =
        \\other: value
    ;
    try std.testing.expectError(error.MissingServicesKey, parseConfig(std.testing.allocator, yaml_no_services));
}
