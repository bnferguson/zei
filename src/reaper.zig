const std = @import("std");
const posix = std.posix;
const logger = @import("logger.zig");
const monitor = @import("monitor.zig");

pub const ReapResult = struct {
    pid: posix.pid_t,
    exit_info: monitor.ExitInfo,
};

/// Reap all available zombie children without blocking.
///
/// Calls waitpid in a loop with WNOHANG until no more exited children
/// remain. Results are written into `buf`; returns the number of
/// children reaped. If `buf` fills up, remaining zombies will be
/// reaped on the next call.
///
/// Uses raw libc waitpid rather than std.posix.waitpid because the
/// std wrapper treats ECHILD as unreachable, which would panic when
/// called with no children (normal for PID 1 at startup).
pub fn reapChildren(buf: []ReapResult) usize {
    std.debug.assert(buf.len > 0);
    var count: usize = 0;

    while (count < buf.len) {
        var status: c_int = 0;
        const rc = std.c.waitpid(-1, &status, std.c.W.NOHANG);

        if (rc == 0) break; // No more children have exited.
        if (rc < 0) {
            switch (posix.errno(rc)) {
                .CHILD => break, // No children exist — normal for PID 1.
                .INTR => continue, // Interrupted by signal — retry.
                else => |e| {
                    // Unexpected errno — log and stop reaping this round
                    // rather than crashing PID 1.
                    const log = logger.Logger.initFromEnv().scoped("reaper");
                    log.err("unexpected waitpid errno: {s}", .{@tagName(e)});
                    break;
                },
            }
        }

        const raw_status: u32 = @bitCast(status);
        const exit_info = parseWaitStatus(raw_status);
        buf[count] = .{ .pid = @intCast(rc), .exit_info = exit_info };
        count += 1;
    }

    return count;
}

/// Parse a raw wait status into an ExitInfo.
pub fn parseWaitStatus(status: u32) monitor.ExitInfo {
    if (posix.W.IFEXITED(status)) {
        return .{ .exited = posix.W.EXITSTATUS(status) };
    }
    if (posix.W.IFSIGNALED(status)) {
        return .{ .signaled = posix.W.TERMSIG(status) };
    }
    // Stopped or continued — shouldn't happen with our wait flags,
    // but treat as signal 0 rather than leaving undefined.
    return .{ .signaled = 0 };
}

// -- Tests --

/// Fork a child that exits with the given code.
fn forkExiting(code: u8) !posix.pid_t {
    const pid = try posix.fork();
    if (pid == 0) {
        posix.exit(code);
    }
    return pid;
}

/// Fork a child that kills itself with a signal.
fn forkSignaled(sig: u8) !posix.pid_t {
    const pid = try posix.fork();
    if (pid == 0) {
        _ = std.c.raise(@intCast(sig));
        posix.exit(255);
    }
    return pid;
}

/// Brief sleep to let forked children exit before we reap.
fn waitForChildren() void {
    posix.nanosleep(0, 50_000_000); // 50ms
}

test "reap single child with exit code 0" {
    const child_pid = try forkExiting(0);
    waitForChildren();

    var buf: [8]ReapResult = undefined;
    const n = reapChildren(&buf);

    try std.testing.expect(n >= 1);
    const found = findResult(buf[0..n], child_pid);
    try std.testing.expect(found != null);
    try std.testing.expect(found.?.exit_info.isSuccess());
}

test "reap single child with non-zero exit" {
    const child_pid = try forkExiting(42);
    waitForChildren();

    var buf: [8]ReapResult = undefined;
    const n = reapChildren(&buf);

    try std.testing.expect(n >= 1);
    const found = findResult(buf[0..n], child_pid);
    try std.testing.expect(found != null);

    switch (found.?.exit_info) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 42), code),
        .signaled => return error.UnexpectedSignal,
    }
}

test "reap child killed by signal" {
    const child_pid = try forkSignaled(posix.SIG.ABRT);
    waitForChildren();

    var buf: [8]ReapResult = undefined;
    const n = reapChildren(&buf);

    try std.testing.expect(n >= 1);
    const found = findResult(buf[0..n], child_pid);
    try std.testing.expect(found != null);

    switch (found.?.exit_info) {
        .signaled => |sig| try std.testing.expectEqual(posix.SIG.ABRT, sig),
        .exited => return error.ExpectedSignal,
    }
}

test "reap multiple children" {
    const pid1 = try forkExiting(0);
    const pid2 = try forkExiting(1);
    const pid3 = try forkExiting(2);
    waitForChildren();

    var buf: [16]ReapResult = undefined;
    const n = reapChildren(&buf);

    try std.testing.expect(n >= 3);
    try std.testing.expect(findResult(buf[0..n], pid1) != null);
    try std.testing.expect(findResult(buf[0..n], pid2) != null);
    try std.testing.expect(findResult(buf[0..n], pid3) != null);
}

test "reap returns 0 when no children have exited" {
    // Fork a child that sleeps, so it won't have exited when we reap.
    const pid = try posix.fork();
    if (pid == 0) {
        posix.nanosleep(5, 0);
        posix.exit(0);
    }

    var buf: [8]ReapResult = undefined;
    const n = reapChildren(&buf);
    try std.testing.expectEqual(@as(usize, 0), n);

    // Clean up: kill the sleeping child and reap it.
    posix.kill(pid, posix.SIG.KILL) catch {};
    _ = posix.waitpid(pid, 0);
}

test "reap respects buffer limit" {
    _ = try forkExiting(0);
    _ = try forkExiting(0);
    _ = try forkExiting(0);
    waitForChildren();

    // Buffer of 1: should reap exactly 1, leaving others for next call.
    var buf: [1]ReapResult = undefined;
    const n1 = reapChildren(&buf);
    try std.testing.expectEqual(@as(usize, 1), n1);

    // Second call should get more.
    var buf2: [8]ReapResult = undefined;
    const n2 = reapChildren(&buf2);
    try std.testing.expect(n2 >= 2);
}

fn findResult(results: []const ReapResult, pid: posix.pid_t) ?*const ReapResult {
    for (results) |*r| {
        if (r.pid == pid) return r;
    }
    return null;
}
