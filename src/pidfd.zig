const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

pub const PidfdError = error{
    /// pidfd syscalls not available (non-Linux or kernel < 5.3).
    Unsupported,
    /// Target process no longer exists.
    ProcessNotFound,
    /// Caller lacks permission to signal the target.
    PermissionDenied,
    /// Unexpected errno from the kernel.
    Unexpected,
};

/// Obtain a pidfd for the given process. The returned fd must be closed
/// via close() when no longer needed.
pub fn open(pid: posix.pid_t) PidfdError!posix.fd_t {
    if (builtin.os.tag != .linux) return error.Unsupported;

    const rc = std.os.linux.pidfd_open(pid, 0);
    const e = std.os.linux.E.init(rc);
    if (e == .SUCCESS) return @intCast(@as(isize, @bitCast(rc)));

    return switch (e) {
        .NOSYS => error.Unsupported,
        .SRCH => error.ProcessNotFound,
        .PERM => error.PermissionDenied,
        else => error.Unexpected,
    };
}

/// Send a signal to the process identified by pidfd. Avoids the PID-reuse
/// race inherent in kill(2) — the signal is guaranteed to reach the
/// original process or fail with ProcessNotFound.
pub fn sendSignal(pidfd: posix.fd_t, sig: u8) PidfdError!void {
    if (builtin.os.tag != .linux) return error.Unsupported;

    const rc = std.os.linux.pidfd_send_signal(pidfd, @intCast(sig), null, 0);
    const e = std.os.linux.E.init(rc);
    if (e == .SUCCESS) return;

    return switch (e) {
        .NOSYS => error.Unsupported,
        .SRCH => error.ProcessNotFound,
        .PERM => error.PermissionDenied,
        .BADF => error.ProcessNotFound, // pidfd was closed or invalid
        else => error.Unexpected,
    };
}

pub fn close(pidfd: posix.fd_t) void {
    posix.close(pidfd);
}

// -- Tests --

test "open returns Unsupported on non-Linux" {
    if (builtin.os.tag == .linux) return error.SkipZigTest;

    const result = open(1);
    try std.testing.expectError(error.Unsupported, result);
}

test "sendSignal returns Unsupported on non-Linux" {
    if (builtin.os.tag == .linux) return error.SkipZigTest;

    const result = sendSignal(3, 0);
    try std.testing.expectError(error.Unsupported, result);
}

test "open succeeds for own PID on Linux" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const pid = std.c.getpid();
    const pidfd = try open(pid);
    defer close(pidfd);

    try std.testing.expect(pidfd >= 0);
}

test "sendSignal with signal 0 checks process existence on Linux" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const pid = std.c.getpid();
    const pidfd = try open(pid);
    defer close(pidfd);

    // Signal 0 is the existence check — no signal is actually delivered.
    try sendSignal(pidfd, 0);
}

test "open returns ProcessNotFound for nonexistent PID" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    // PID 4194304 (2^22) is above the typical Linux pid_max.
    const result = open(4194304);
    try std.testing.expectError(error.ProcessNotFound, result);
}
