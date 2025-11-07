const std = @import("std");
const os = std.os;
const linux = std.os.linux;
const posix = std.posix;

const config = @import("config.zig");
const privilege = @import("privilege.zig");

/// Pipe file descriptors for process I/O
pub const ProcessPipes = struct {
    stdout_read: posix.fd_t,
    stdout_write: posix.fd_t,
    stderr_read: posix.fd_t,
    stderr_write: posix.fd_t,

    /// Close all pipe file descriptors
    pub fn closeAll(self: *ProcessPipes) void {
        posix.close(self.stdout_read);
        posix.close(self.stdout_write);
        posix.close(self.stderr_read);
        posix.close(self.stderr_write);
    }

    /// Close parent-side pipes (read ends)
    pub fn closeParentSide(self: *ProcessPipes) void {
        posix.close(self.stdout_read);
        posix.close(self.stderr_read);
    }

    /// Close child-side pipes (write ends)
    pub fn closeChildSide(self: *ProcessPipes) void {
        posix.close(self.stdout_write);
        posix.close(self.stderr_write);
    }
};

/// Result of spawning a process
pub const SpawnResult = struct {
    pid: posix.pid_t,
    pipes: ProcessPipes,
};

/// Parse command string or array into argv format
pub fn parseCommand(allocator: std.mem.Allocator, command: []const []const u8) ![:null]?[*:0]u8 {
    // Allocate argv array (command + null terminator)
    var argv = try allocator.alloc(?[*:0]u8, command.len + 1);
    errdefer allocator.free(argv);

    // Convert each argument to null-terminated string
    for (command, 0..) |arg, i| {
        const arg_z = try allocator.dupeZ(u8, arg);
        argv[i] = arg_z;
    }

    // Null terminator for argv
    argv[command.len] = null;

    return argv[0..command.len :null];
}

/// Free argv array created by parseCommand
pub fn freeCommand(allocator: std.mem.Allocator, argv: [:null]?[*:0]u8) void {
    for (argv) |arg| {
        if (arg) |a| {
            allocator.free(std.mem.span(a));
        }
    }
    allocator.free(argv);
}

/// Create pipes for stdout and stderr
pub fn createPipes() !ProcessPipes {
    // Create stdout pipe
    var stdout_fds: [2]posix.fd_t = undefined;
    try posix.pipe(&stdout_fds);

    // Create stderr pipe
    var stderr_fds: [2]posix.fd_t = undefined;
    try posix.pipe(&stderr_fds);

    return ProcessPipes{
        .stdout_read = stdout_fds[0],
        .stdout_write = stdout_fds[1],
        .stderr_read = stderr_fds[0],
        .stderr_write = stderr_fds[1],
    };
}

/// Spawn a process with the given configuration
pub fn spawnProcess(
    allocator: std.mem.Allocator,
    service_config: *const config.ServiceConfig,
) !SpawnResult {
    // Create pipes for process output
    var pipes = try createPipes();
    errdefer pipes.closeAll();

    // Parse command into argv format
    const argv = try parseCommand(allocator, service_config.command);
    defer freeCommand(allocator, argv);

    // Prepare environment variables
    const envp = try prepareEnvironment(allocator, service_config.env);
    defer freeEnvironment(allocator, envp);

    // Fork the process
    const pid = try posix.fork();

    if (pid == 0) {
        // Child process
        childProcess(service_config, argv, envp, &pipes) catch |err| {
            std.debug.print("Child process failed: {}\n", .{err});
            os.exit(1);
        };
        // Should never reach here if exec succeeds
        os.exit(127);
    } else {
        // Parent process
        // Close the write ends of the pipes (child uses these)
        posix.close(pipes.stdout_write);
        posix.close(pipes.stderr_write);

        return SpawnResult{
            .pid = pid,
            .pipes = ProcessPipes{
                .stdout_read = pipes.stdout_read,
                .stdout_write = 0, // Already closed
                .stderr_read = pipes.stderr_read,
                .stderr_write = 0, // Already closed
            },
        };
    }
}

/// Child process setup and execution
fn childProcess(
    service_config: *const config.ServiceConfig,
    argv: [:null]?[*:0]u8,
    envp: [:null]?[*:0]u8,
    pipes: *ProcessPipes,
) !void {
    // Close the read ends of the pipes (parent uses these)
    posix.close(pipes.stdout_read);
    posix.close(pipes.stderr_read);

    // Redirect stdout to pipe
    try posix.dup2(pipes.stdout_write, posix.STDOUT_FILENO);
    posix.close(pipes.stdout_write);

    // Redirect stderr to pipe
    try posix.dup2(pipes.stderr_write, posix.STDERR_FILENO);
    posix.close(pipes.stderr_write);

    // Change working directory if specified
    if (service_config.working_dir) |wd| {
        try posix.chdir(wd);
    }

    // Switch to target user/group if specified
    if (service_config.user) |username| {
        // We need to be root to switch users
        var priv_ctx = privilege.PrivilegeContext.init();
        privilege.escalatePrivileges(&priv_ctx) catch |err| {
            std.debug.print("Failed to escalate privileges: {}\n", .{err});
            return err;
        };

        // Look up target user
        const allocator = std.heap.page_allocator;
        const target_uid = privilege.lookupUser(allocator, username) catch |err| {
            std.debug.print("Failed to lookup user '{s}': {}\n", .{ username, err });
            return err;
        };

        // Look up target group if specified
        var target_gid: ?linux.gid_t = null;
        if (service_config.group) |groupname| {
            target_gid = privilege.lookupGroup(allocator, groupname) catch |err| {
                std.debug.print("Failed to lookup group '{s}': {}\n", .{ groupname, err });
                return err;
            };
        }

        // Switch to target user/group
        privilege.switchToUser(target_uid, target_gid) catch |err| {
            std.debug.print("Failed to switch to user '{s}': {}\n", .{ username, err });
            return err;
        };
    }

    // Execute the command
    const err = posix.execvpeZ(argv[0].?, argv, envp);

    // If we get here, exec failed
    std.debug.print("Failed to exec '{s}': {}\n", .{ service_config.command[0], err });
    return err;
}

/// Prepare environment variables for execve
fn prepareEnvironment(
    allocator: std.mem.Allocator,
    service_env: ?std.StringHashMap([]const u8),
) ![:null]?[*:0]u8 {
    // Start with current environment
    var env_list: std.ArrayList([*:0]u8) = .empty;
    defer env_list.deinit(allocator);

    // Copy existing environment
    var env_iter = std.process.getEnvMap(allocator) catch |err| {
        std.debug.print("Failed to get environment: {}\n", .{err});
        return err;
    };
    defer env_iter.deinit();

    var it = env_iter.iterator();
    while (it.next()) |entry| {
        const env_str = try std.fmt.allocPrintZ(
            allocator,
            "{s}={s}",
            .{ entry.key_ptr.*, entry.value_ptr.* },
        );
        try env_list.append(allocator, env_str);
    }

    // Add/override service-specific environment variables
    if (service_env) |env_map| {
        var service_it = env_map.iterator();
        while (service_it.next()) |entry| {
            const env_str = try std.fmt.allocPrintZ(
                allocator,
                "{s}={s}",
                .{ entry.key_ptr.*, entry.value_ptr.* },
            );
            try env_list.append(allocator, env_str);
        }
    }

    // Convert to null-terminated array
    const env_slice = try env_list.toOwnedSlice(allocator);
    var envp = try allocator.alloc(?[*:0]u8, env_slice.len + 1);

    for (env_slice, 0..) |env_str, i| {
        envp[i] = env_str;
    }
    envp[env_slice.len] = null;

    allocator.free(env_slice);

    return envp[0..env_slice.len :null];
}

/// Free environment array
fn freeEnvironment(allocator: std.mem.Allocator, envp: [:null]?[*:0]u8) void {
    for (envp) |env| {
        if (env) |e| {
            allocator.free(std.mem.span(e));
        }
    }
    allocator.free(envp);
}

// Tests
test "parseCommand" {
    const command = [_][]const u8{ "/bin/echo", "hello", "world" };

    const argv = try parseCommand(std.testing.allocator, &command);
    defer freeCommand(std.testing.allocator, argv);

    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("/bin/echo", std.mem.span(argv[0].?));
    try std.testing.expectEqualStrings("hello", std.mem.span(argv[1].?));
    try std.testing.expectEqualStrings("world", std.mem.span(argv[2].?));
}

test "createPipes" {
    var pipes = try createPipes();
    defer pipes.closeAll();

    // Verify we got valid file descriptors
    try std.testing.expect(pipes.stdout_read >= 0);
    try std.testing.expect(pipes.stdout_write >= 0);
    try std.testing.expect(pipes.stderr_read >= 0);
    try std.testing.expect(pipes.stderr_write >= 0);

    // Verify they're different
    try std.testing.expect(pipes.stdout_read != pipes.stdout_write);
    try std.testing.expect(pipes.stderr_read != pipes.stderr_write);
}

test "spawnProcess - simple echo" {
    const allocator = std.testing.allocator;

    // Create a simple service config
    const name = try allocator.dupe(u8, "test-echo");
    defer allocator.free(name);

    const cmd = try allocator.alloc([]const u8, 2);
    defer allocator.free(cmd);
    cmd[0] = try allocator.dupe(u8, "/bin/echo");
    cmd[1] = try allocator.dupe(u8, "hello");
    defer allocator.free(cmd[0]);
    defer allocator.free(cmd[1]);

    const service_config = config.ServiceConfig{
        .name = name,
        .command = cmd,
        .user = null,
        .group = null,
        .working_dir = null,
        .env = null,
        .restart = .always,
    };

    // Spawn the process
    const result = try spawnProcess(allocator, &service_config);
    defer {
        posix.close(result.pipes.stdout_read);
        posix.close(result.pipes.stderr_read);
    }

    // Verify we got a valid PID
    try std.testing.expect(result.pid > 0);

    // Read output from stdout pipe
    var buffer: [1024]u8 = undefined;
    const bytes_read = try posix.read(result.pipes.stdout_read, &buffer);

    try std.testing.expect(bytes_read > 0);
    try std.testing.expect(std.mem.startsWith(u8, buffer[0..bytes_read], "hello"));

    // Wait for process to exit
    const wait_result = posix.waitpid(result.pid, 0);
    try std.testing.expect(wait_result.status == 0);
}

test "spawnProcess - with working directory" {
    const allocator = std.testing.allocator;

    const name = try allocator.dupe(u8, "test-pwd");
    defer allocator.free(name);

    const cmd = try allocator.alloc([]const u8, 1);
    defer allocator.free(cmd);
    cmd[0] = try allocator.dupe(u8, "/bin/pwd");
    defer allocator.free(cmd[0]);

    const working_dir = try allocator.dupe(u8, "/tmp");
    defer allocator.free(working_dir);

    const service_config = config.ServiceConfig{
        .name = name,
        .command = cmd,
        .user = null,
        .group = null,
        .working_dir = working_dir,
        .env = null,
        .restart = .always,
    };

    const result = try spawnProcess(allocator, &service_config);
    defer {
        posix.close(result.pipes.stdout_read);
        posix.close(result.pipes.stderr_read);
    }

    // Read output
    var buffer: [1024]u8 = undefined;
    const bytes_read = try posix.read(result.pipes.stdout_read, &buffer);

    try std.testing.expect(bytes_read > 0);
    try std.testing.expect(std.mem.startsWith(u8, buffer[0..bytes_read], "/tmp"));

    // Wait for process
    _ = posix.waitpid(result.pid, 0);
}

test "spawnProcess - with environment variables" {
    const allocator = std.testing.allocator;

    const name = try allocator.dupe(u8, "test-env");
    defer allocator.free(name);

    const cmd = try allocator.alloc([]const u8, 2);
    defer allocator.free(cmd);
    cmd[0] = try allocator.dupe(u8, "/usr/bin/env");
    cmd[1] = try allocator.dupe(u8, "TEST_VAR");
    defer allocator.free(cmd[0]);
    defer allocator.free(cmd[1]);

    var env_map = std.StringHashMap([]const u8).init(allocator);
    defer env_map.deinit();

    const key = try allocator.dupe(u8, "TEST_VAR");
    const value = try allocator.dupe(u8, "test_value");
    try env_map.put(key, value);
    defer allocator.free(key);
    defer allocator.free(value);

    const service_config = config.ServiceConfig{
        .name = name,
        .command = cmd,
        .user = null,
        .group = null,
        .working_dir = null,
        .env = env_map,
        .restart = .always,
    };

    const result = try spawnProcess(allocator, &service_config);
    defer {
        posix.close(result.pipes.stdout_read);
        posix.close(result.pipes.stderr_read);
    }

    // Read output
    var buffer: [1024]u8 = undefined;
    const bytes_read = try posix.read(result.pipes.stdout_read, &buffer);

    try std.testing.expect(bytes_read > 0);
    try std.testing.expect(std.mem.startsWith(u8, buffer[0..bytes_read], "test_value"));

    // Wait for process
    _ = posix.waitpid(result.pid, 0);
}
