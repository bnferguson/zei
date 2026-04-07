const std = @import("std");
const posix = std.posix;

const Child = std.process.Child;
const pidfd = @import("pidfd.zig");

pub const SpawnOptions = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    env: ?*const std.process.EnvMap = null,
    uid: ?posix.uid_t = null,
    gid: ?posix.gid_t = null,
};

/// Result of a successful spawn. Owns the stdout/stderr pipe file handles.
/// The caller is responsible for reaping the child via waitpid (typically
/// in the reaper loop) and must call deinit() to close the pipes.
pub const SpawnResult = struct {
    pid: posix.pid_t,
    stdout: std.fs.File,
    stderr: std.fs.File,
    pidfd: ?posix.fd_t = null,

    pub fn deinit(self: *SpawnResult) void {
        if (self.pidfd) |pfd| pidfd.close(pfd);
        self.stdout.close();
        self.stderr.close();
        self.* = undefined;
    }
};

/// Spawn a child process with piped stdout/stderr.
///
/// The child's stdin is connected to /dev/null. The caller must reap
/// the child via waitpid and call result.deinit() to close pipes.
pub fn spawn(allocator: std.mem.Allocator, opts: SpawnOptions) Child.SpawnError!SpawnResult {
    std.debug.assert(opts.argv.len > 0);
    std.debug.assert(opts.argv[0].len > 0);

    var child = Child.init(opts.argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.stdin_behavior = .Ignore;
    child.cwd = opts.cwd;
    child.env_map = opts.env;
    child.uid = opts.uid;
    child.gid = opts.gid;

    try child.spawn();

    return .{
        .pid = child.id,
        .stdout = child.stdout.?,
        .stderr = child.stderr.?,
        .pidfd = pidfd.open(child.id) catch null,
    };
}

// -- Tests --

/// Helper: spawn, read all stdout, reap child, return output and exit code.
fn spawnAndCollect(allocator: std.mem.Allocator, opts: SpawnOptions) !struct { output: []u8, exit_code: u8 } {
    var result = try spawn(allocator, opts);
    defer result.deinit();

    const output = try result.stdout.readToEndAlloc(allocator, 4096);

    const wait_result = posix.waitpid(result.pid, 0);
    if (!posix.W.IFEXITED(wait_result.status)) return error.UnexpectedChildStatus;
    const exit_code = posix.W.EXITSTATUS(wait_result.status);

    return .{ .output = output, .exit_code = exit_code };
}

test "spawn /bin/echo and read stdout" {
    const r = try spawnAndCollect(std.testing.allocator, .{
        .argv = &.{ "/bin/echo", "hello", "world" },
    });
    defer std.testing.allocator.free(r.output);

    const trimmed = std.mem.trimRight(u8, r.output, "\n");
    try std.testing.expectEqualStrings("hello world", trimmed);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
}

test "spawn captures stderr" {
    var result = try spawn(std.testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "echo err >&2" },
    });
    defer result.deinit();

    var buf: [256]u8 = undefined;
    const n = try result.stderr.readAll(&buf);
    const output = std.mem.trimRight(u8, buf[0..n], "\n");
    try std.testing.expectEqualStrings("err", output);

    _ = posix.waitpid(result.pid, 0);
}

test "spawn with working directory" {
    const r = try spawnAndCollect(std.testing.allocator, .{
        .argv = &.{"/bin/pwd"},
        .cwd = "/tmp",
    });
    defer std.testing.allocator.free(r.output);

    const trimmed = std.mem.trimRight(u8, r.output, "\n");
    try std.testing.expectEqualStrings("/tmp", trimmed);
}

test "spawn with environment variables" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ZEI_TEST_VAR", "hello_from_zei");

    const r = try spawnAndCollect(std.testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "echo $ZEI_TEST_VAR" },
        .env = &env,
    });
    defer std.testing.allocator.free(r.output);

    const trimmed = std.mem.trimRight(u8, r.output, "\n");
    try std.testing.expectEqualStrings("hello_from_zei", trimmed);
}

test "spawn returns non-zero exit code" {
    const r = try spawnAndCollect(std.testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "exit 42" },
    });
    defer std.testing.allocator.free(r.output);

    try std.testing.expectEqual(@as(u8, 42), r.exit_code);
}

test "spawn with uid/gid as root" {
    const c = @cImport({
        @cInclude("unistd.h");
    });
    if (c.geteuid() != 0) return error.SkipZigTest;

    const user_lookup = @import("user_lookup.zig");
    const creds = user_lookup.lookup("appuser", "appgroup") catch return error.SkipZigTest;

    const r = try spawnAndCollect(std.testing.allocator, .{
        .argv = &.{ "/usr/bin/id", "-u" },
        .uid = creds.uid,
        .gid = creds.gid,
    });
    defer std.testing.allocator.free(r.output);

    const trimmed = std.mem.trimRight(u8, r.output, "\n");
    try std.testing.expectEqualStrings("1000", trimmed);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
}
