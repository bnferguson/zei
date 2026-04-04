///! Privilege management for a suid-root binary.
///!
///! zei runs in non-root containers with the suid bit set on the binary.
///! This gives us: real UID = container user (non-root), effective UID = root.
///! We use setreuid/setregid to swap root between real and effective positions,
///! allowing us to elevate for privileged operations (spawning services as
///! different users) and drop back afterward. This provides user isolation
///! across services without running the container as root.
///!
///! The typical cycle is:
///!   start:   real=container_user, effective=root (suid)
///!   drop:    real=root, effective=service_user
///!   elevate: real=service_user, effective=root
///!   drop:    real=root, effective=next_service_user
///!   ...
const std = @import("std");
const user_lookup = @import("user_lookup.zig");

const c = @cImport({
    @cInclude("unistd.h");
});

pub const PrivilegeError = error{
    SetUidFailed,
    SetGidFailed,
    /// The second setXid call failed AND we could not restore the first.
    RestoreFailed,
};

/// Drop effective privileges to the given user/group.
///
/// Parks root in the real UID position (so elevate() can retrieve it) and
/// sets the effective UID/GID to the target. GID is set first because
/// changing effective UID away from root clears CAP_SETGID.
pub fn drop(username: []const u8, groupname: []const u8) (PrivilegeError || user_lookup.LookupError)!void {
    const creds = try user_lookup.lookup(username, groupname);
    std.debug.assert(creds.uid != 0); // Dropping to root is a no-op bug.

    const root_uid = c.geteuid();
    const root_gid = c.getegid();
    std.debug.assert(root_uid == 0); // Effective UID must be root (from suid or prior elevate).

    // GID first — we still have root effective UID and CAP_SETGID.
    if (c.setregid(root_gid, creds.gid) != 0) return error.SetGidFailed;

    if (c.setreuid(root_uid, creds.uid) != 0) {
        // Restore GID to prevent a half-dropped state.
        if (c.setregid(root_gid, root_gid) != 0) return error.RestoreFailed;
        return error.SetUidFailed;
    }
}

/// Restore effective UID/GID back to root.
///
/// After drop(), root is parked in the real UID position. This swaps it
/// back into the effective position. UID is restored first because we
/// need root effective UID (and thus CAP_SETGID) before changing GID.
pub fn elevate() PrivilegeError!void {
    const root_uid = c.getuid();
    const root_gid = c.getgid();
    std.debug.assert(root_uid == 0); // Real UID must be root (set by prior drop).

    const prev_uid = c.geteuid();
    const prev_gid = c.getegid();

    // UID first — restores CAP_SETGID so we can change GID next.
    if (c.setreuid(prev_uid, root_uid) != 0) return error.SetUidFailed;

    if (c.setregid(prev_gid, root_gid) != 0) {
        // Restore effective UID to non-root to prevent a half-elevated state.
        if (c.setreuid(root_uid, prev_uid) != 0) return error.RestoreFailed;
        return error.SetGidFailed;
    }
}

// -- Tests --

test "drop returns UserNotFound for bad username" {
    const result = drop("__no_such_user__", "root");
    try std.testing.expectError(error.UserNotFound, result);
}

test "drop returns GroupNotFound for bad groupname" {
    const result = drop("root", "__no_such_group__");
    try std.testing.expectError(error.GroupNotFound, result);
}

test "drop and elevate round-trip" {
    // Needs effective root (suid binary or running as root in Docker).
    if (c.geteuid() != 0) return error.SkipZigTest;

    // Verify appuser exists (skip if not in Docker).
    _ = user_lookup.lookup("appuser", "appgroup") catch return error.SkipZigTest;

    // Drop to appuser — effective becomes non-root, real becomes root.
    try drop("appuser", "appgroup");
    try std.testing.expectEqual(@as(c_uint, 1000), c.geteuid());
    try std.testing.expectEqual(@as(c_uint, 1000), c.getegid());
    try std.testing.expectEqual(@as(c_uint, 0), c.getuid());
    try std.testing.expectEqual(@as(c_uint, 0), c.getgid());

    // Elevate — effective becomes root again.
    try elevate();
    try std.testing.expectEqual(@as(c_uint, 0), c.geteuid());
    try std.testing.expectEqual(@as(c_uint, 0), c.getegid());

    // Second cycle — simulates starting another service as a different user.
    // In Docker we only have appuser, so drop to the same user again.
    try drop("appuser", "appgroup");
    try std.testing.expectEqual(@as(c_uint, 1000), c.geteuid());

    try elevate();
    try std.testing.expectEqual(@as(c_uint, 0), c.geteuid());
}
