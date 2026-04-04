const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

/// The set of signals we handle. Blocked at startup so they queue
/// rather than invoking default handlers (which would kill PID 1).
const managed_signals = [_]u8{
    posix.SIG.TERM,
    posix.SIG.INT,
    posix.SIG.QUIT,
    posix.SIG.HUP,
    posix.SIG.USR1,
    posix.SIG.USR2,
    posix.SIG.CHLD,
    posix.SIG.PIPE,
};

comptime {
    for (managed_signals) |sig| {
        std.debug.assert(classify(sig) != .unknown);
    }
}

/// What the daemon should do in response to a signal.
pub const Action = enum {
    /// Initiate graceful shutdown (SIGTERM, SIGINT, SIGQUIT).
    shutdown,
    /// Forward signal to all managed services (SIGHUP, SIGUSR1, SIGUSR2).
    forward,
    /// A child exited — run the reaper (SIGCHLD).
    reap,
    /// Ignore (SIGPIPE).
    ignore,
    /// Not a signal we manage.
    unknown,
};

/// Classify a signal number into the action the daemon should take.
pub fn classify(sig: u8) Action {
    return switch (sig) {
        posix.SIG.TERM, posix.SIG.INT, posix.SIG.QUIT => .shutdown,
        posix.SIG.HUP, posix.SIG.USR1, posix.SIG.USR2 => .forward,
        posix.SIG.CHLD => .reap,
        posix.SIG.PIPE => .ignore,
        else => .unknown,
    };
}

/// Build the signal mask for all managed signals.
fn managedSignalMask() posix.sigset_t {
    var mask = posix.sigemptyset();
    for (managed_signals) |sig| {
        posix.sigaddset(&mask, sig);
    }
    return mask;
}

/// Block all managed signals so they queue for synchronous retrieval.
/// Must be called early in main, before spawning any threads.
pub fn blockManagedSignals() void {
    const mask = managedSignalMask();
    posix.sigprocmask(posix.SIG.BLOCK, &mask, null);
}

/// Restore the default signal mask (unblock managed signals).
/// Useful for child processes after fork, before exec.
pub fn unblockManagedSignals() void {
    const mask = managedSignalMask();
    posix.sigprocmask(posix.SIG.UNBLOCK, &mask, null);
}

/// Wait for a managed signal, returning the signal number.
///
/// On Linux, uses the rt_sigtimedwait syscall for efficient blocking
/// with a 1-second timeout. On other platforms (macOS), polls with
/// a short sleep — sigtimedwait is not available as a high-level
/// function in Zig 0.15.2 on macOS.
///
/// Returns the signal number, or null if the timeout expired without
/// a signal being delivered.
pub fn waitForSignal() ?u8 {
    const mask = managedSignalMask();

    if (builtin.os.tag == .linux) {
        return waitForSignalLinux(&mask);
    } else {
        return waitForSignalPoll();
    }
}

/// Linux implementation using rt_sigtimedwait syscall.
fn waitForSignalLinux(mask: *const posix.sigset_t) ?u8 {
    const linux = std.os.linux;
    var timeout = linux.timespec{ .sec = 1, .nsec = 0 };

    const rc = linux.syscall4(
        .rt_sigtimedwait,
        @intFromPtr(mask),
        @intFromPtr(@as(?*anyopaque, null)),
        @intFromPtr(&timeout),
        @sizeOf(posix.sigset_t),
    );

    const signed: isize = @bitCast(rc);
    if (signed > 0) {
        return @intCast(signed);
    }
    // Timeout or error — caller will loop.
    return null;
}

/// C signal functions, only needed on non-Linux for the polling fallback.
const c = if (builtin.os.tag == .linux) struct {} else @cImport({
    @cInclude("signal.h");
});

/// Fallback polling implementation for macOS and other platforms.
/// Uses sigpending to check for queued signals, then sigwait to
/// consume one. Falls back to a short sleep if no signals pending.
fn waitForSignalPoll() ?u8 {
    var mask: c.sigset_t = 0;
    _ = c.sigemptyset(&mask);
    for (managed_signals) |sig| {
        _ = c.sigaddset(&mask, @intCast(sig));
    }

    var pending: c.sigset_t = 0;
    if (c.sigpending(&pending) != 0) return null;

    for (managed_signals) |sig| {
        if (c.sigismember(&pending, @intCast(sig)) == 1) {
            var result_sig: c_int = 0;
            const rc = c.sigwait(&mask, &result_sig);
            if (rc == 0 and result_sig > 0) {
                return @intCast(result_sig);
            }
            return null;
        }
    }

    // No signals pending — sleep briefly and let the caller loop.
    posix.nanosleep(0, 100_000_000); // 100ms
    return null;
}

// -- Tests --

test "classify shutdown signals" {
    try std.testing.expectEqual(Action.shutdown, classify(posix.SIG.TERM));
    try std.testing.expectEqual(Action.shutdown, classify(posix.SIG.INT));
    try std.testing.expectEqual(Action.shutdown, classify(posix.SIG.QUIT));
}

test "classify forward signals" {
    try std.testing.expectEqual(Action.forward, classify(posix.SIG.HUP));
    try std.testing.expectEqual(Action.forward, classify(posix.SIG.USR1));
    try std.testing.expectEqual(Action.forward, classify(posix.SIG.USR2));
}

test "classify reap signal" {
    try std.testing.expectEqual(Action.reap, classify(posix.SIG.CHLD));
}

test "classify ignore signal" {
    try std.testing.expectEqual(Action.ignore, classify(posix.SIG.PIPE));
}

test "classify unknown signal" {
    try std.testing.expectEqual(Action.unknown, classify(42));
}

test "blockManagedSignals adds signals to blocked set" {
    var original: posix.sigset_t = undefined;
    posix.sigprocmask(posix.SIG.BLOCK, null, &original);
    defer posix.sigprocmask(posix.SIG.SETMASK, &original, null);

    // Start with an empty mask.
    const empty = posix.sigemptyset();
    posix.sigprocmask(posix.SIG.SETMASK, &empty, null);

    blockManagedSignals();

    var current: posix.sigset_t = undefined;
    posix.sigprocmask(posix.SIG.BLOCK, null, &current);

    // Verify the mask is no longer empty (signals were added).
    try std.testing.expect(current != posix.sigemptyset());
}

test "unblockManagedSignals removes signals from blocked set" {
    var original: posix.sigset_t = undefined;
    posix.sigprocmask(posix.SIG.BLOCK, null, &original);
    defer posix.sigprocmask(posix.SIG.SETMASK, &original, null);

    // Start with an empty mask, block, then unblock.
    const empty = posix.sigemptyset();
    posix.sigprocmask(posix.SIG.SETMASK, &empty, null);

    blockManagedSignals();
    unblockManagedSignals();

    var current: posix.sigset_t = undefined;
    posix.sigprocmask(posix.SIG.BLOCK, null, &current);

    // After unblocking, should be back to empty.
    try std.testing.expectEqual(posix.sigemptyset(), current);
}

test "waitForSignal returns null on timeout" {
    var original: posix.sigset_t = undefined;
    posix.sigprocmask(posix.SIG.BLOCK, null, &original);
    defer posix.sigprocmask(posix.SIG.SETMASK, &original, null);

    blockManagedSignals();
    const result = waitForSignal();
    try std.testing.expect(result == null);
}

test "waitForSignal receives queued signal" {
    var original: posix.sigset_t = undefined;
    posix.sigprocmask(posix.SIG.BLOCK, null, &original);
    defer posix.sigprocmask(posix.SIG.SETMASK, &original, null);

    blockManagedSignals();

    // Send ourselves a signal — it will queue since it's blocked.
    try posix.kill(std.c.getpid(), posix.SIG.USR1);

    const result = waitForSignal();
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u8, posix.SIG.USR1), result.?);
}
