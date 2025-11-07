const std = @import("std");
const os = std.os;
const linux = std.os.linux;

/// Error types for privilege operations
pub const PrivilegeError = error{
    UserNotFound,
    GroupNotFound,
    PermissionDenied,
    NotSetuid,
    PrivilegeLeakDetected,
};

/// Context for saving/restoring privileges
pub const PrivilegeContext = struct {
    original_uid: linux.uid_t,
    original_gid: linux.gid_t,
    original_euid: linux.uid_t,
    original_egid: linux.gid_t,
    escalated: bool,

    pub fn init() PrivilegeContext {
        return PrivilegeContext{
            .original_uid = linux.getuid(),
            .original_gid = linux.getgid(),
            .original_euid = linux.geteuid(),
            .original_egid = linux.getegid(),
            .escalated = false,
        };
    }
};

/// Get current real user ID
pub fn getCurrentUid() linux.uid_t {
    return linux.getuid();
}

/// Get current real group ID
pub fn getCurrentGid() linux.gid_t {
    return linux.getgid();
}

/// Get current effective user ID
pub fn getCurrentEuid() linux.uid_t {
    return linux.geteuid();
}

/// Get current effective group ID
pub fn getCurrentEgid() linux.gid_t {
    return linux.getegid();
}

/// Look up user ID from username by parsing /etc/passwd
pub fn lookupUser(allocator: std.mem.Allocator, username: []const u8) !linux.uid_t {
    const passwd_file = std.fs.openFileAbsolute("/etc/passwd", .{}) catch |err| {
        std.debug.print("Failed to open /etc/passwd: {}\n", .{err});
        return PrivilegeError.UserNotFound;
    };
    defer passwd_file.close();

    const content = passwd_file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        std.debug.print("Failed to read /etc/passwd: {}\n", .{err});
        return PrivilegeError.UserNotFound;
    };
    defer allocator.free(content);

    // Parse /etc/passwd format: username:password:uid:gid:gecos:home:shell
    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ':');

        const user = fields.next() orelse continue;
        if (!std.mem.eql(u8, user, username)) {
            continue;
        }

        _ = fields.next(); // skip password field
        const uid_str = fields.next() orelse continue;

        const uid = std.fmt.parseInt(linux.uid_t, uid_str, 10) catch continue;
        return uid;
    }

    std.debug.print("User '{s}' not found in /etc/passwd\n", .{username});
    return PrivilegeError.UserNotFound;
}

/// Look up group ID from group name by parsing /etc/group
pub fn lookupGroup(allocator: std.mem.Allocator, groupname: []const u8) !linux.gid_t {
    const group_file = std.fs.openFileAbsolute("/etc/group", .{}) catch |err| {
        std.debug.print("Failed to open /etc/group: {}\n", .{err});
        return PrivilegeError.GroupNotFound;
    };
    defer group_file.close();

    const content = group_file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        std.debug.print("Failed to read /etc/group: {}\n", .{err});
        return PrivilegeError.GroupNotFound;
    };
    defer allocator.free(content);

    // Parse /etc/group format: groupname:password:gid:members
    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ':');

        const group = fields.next() orelse continue;
        if (!std.mem.eql(u8, group, groupname)) {
            continue;
        }

        _ = fields.next(); // skip password field
        const gid_str = fields.next() orelse continue;

        const gid = std.fmt.parseInt(linux.gid_t, gid_str, 10) catch continue;
        return gid;
    }

    std.debug.print("Group '{s}' not found in /etc/group\n", .{groupname});
    return PrivilegeError.GroupNotFound;
}

/// Verify that the binary is properly configured for setuid operation
pub fn verifySetuidConfiguration() !void {
    const euid = getCurrentEuid();
    const ruid = getCurrentUid();

    // Check if we have setuid bit set (effective UID is different from real UID)
    if (euid == ruid) {
        // We're not running with setuid - this is okay for development/testing
        // but required for production use
        std.debug.print("Warning: Binary not running with setuid bit. " ++
            "Privilege escalation will only work if already running as root.\n", .{});
    }

    // Check if effective UID is root when setuid is set
    if (euid == 0) {
        std.debug.print("Running with root privileges (EUID=0)\n", .{});
    } else if (ruid != 0) {
        std.debug.print("Running as non-root user (UID={d}, EUID={d})\n", .{ ruid, euid });
    }
}

/// Escalate privileges to root (requires setuid binary or running as root)
pub fn escalatePrivileges(ctx: *PrivilegeContext) !void {
    if (ctx.escalated) {
        std.debug.print("Warning: Privileges already escalated\n", .{});
        return;
    }

    // Save current state
    ctx.* = PrivilegeContext.init();

    // Try to escalate to root
    const result = linux.setuid(0);
    if (result != 0) {
        const err = posix.errno(result);
        if (err == .PERM) {
            std.debug.print("Failed to escalate privileges: Permission denied\n", .{});
            return PrivilegeError.PermissionDenied;
        }
        std.debug.print("Failed to escalate privileges: errno={}\n", .{err});
        return PrivilegeError.PermissionDenied;
    }

    ctx.escalated = true;

    // Verify we actually have root
    if (getCurrentEuid() != 0) {
        std.debug.print("Privilege escalation failed: EUID is not 0 after setuid(0)\n", .{});
        return PrivilegeError.PrivilegeLeakDetected;
    }
}

/// Switch to a specific user (and optionally group)
/// This should be called after escalatePrivileges()
pub fn switchToUser(target_uid: linux.uid_t, target_gid: ?linux.gid_t) !void {
    // Verify we're running as root
    if (getCurrentEuid() != 0) {
        std.debug.print("Cannot switch user: not running as root (EUID={d})\n", .{getCurrentEuid()});
        return PrivilegeError.PermissionDenied;
    }

    // Set group first (must be done before dropping root)
    if (target_gid) |gid| {
        const gid_result = linux.setgid(gid);
        if (gid_result != 0) {
            const err = posix.errno(gid_result);
            std.debug.print("Failed to setgid({d}): errno={}\n", .{ gid, err });
            return PrivilegeError.PermissionDenied;
        }

        // Verify GID was set
        if (getCurrentGid() != gid) {
            std.debug.print("setgid verification failed: expected {d}, got {d}\n", .{ gid, getCurrentGid() });
            return PrivilegeError.PrivilegeLeakDetected;
        }
    }

    // Now set user
    const uid_result = linux.setuid(target_uid);
    if (uid_result != 0) {
        const err = posix.errno(uid_result);
        std.debug.print("Failed to setuid({d}): errno={}\n", .{ target_uid, err });
        return PrivilegeError.PermissionDenied;
    }

    // Verify UID was set
    if (getCurrentUid() != target_uid) {
        std.debug.print("setuid verification failed: expected {d}, got {d}\n", .{ target_uid, getCurrentUid() });
        return PrivilegeError.PrivilegeLeakDetected;
    }

    // Safety check: verify we can't escalate back to root
    const test_result = linux.setuid(0);
    if (test_result == 0) {
        std.debug.print("Security violation: able to regain root after dropping privileges!\n", .{});
        return PrivilegeError.PrivilegeLeakDetected;
    }
}

/// Drop privileges back to original user/group
/// Note: This only works if we haven't called setuid() yet, only seteuid()
/// Once setuid() is called, privileges cannot be regained
pub fn dropPrivileges(ctx: *PrivilegeContext) !void {
    if (!ctx.escalated) {
        return; // Already dropped or never escalated
    }

    // Try to restore original GID first
    const gid_result = linux.setgid(ctx.original_gid);
    if (gid_result != 0) {
        const err = posix.errno(gid_result);
        std.debug.print("Failed to restore GID: errno={}\n", .{err});
        return PrivilegeError.PermissionDenied;
    }

    // Then restore original UID
    const uid_result = linux.setuid(ctx.original_uid);
    if (uid_result != 0) {
        const err = posix.errno(uid_result);
        std.debug.print("Failed to restore UID: errno={}\n", .{err});
        return PrivilegeError.PermissionDenied;
    }

    ctx.escalated = false;

    // Verify we dropped privileges
    if (getCurrentUid() != ctx.original_uid or getCurrentGid() != ctx.original_gid) {
        std.debug.print("Failed to verify privilege drop\n", .{});
        return PrivilegeError.PrivilegeLeakDetected;
    }
}

/// Helper function to execute a function with temporary root privileges
/// This is useful for operations that need root briefly
pub fn withEscalatedPrivileges(
    comptime func: anytype,
    args: anytype,
) !@typeInfo(@TypeOf(func)).Fn.return_type.? {
    var ctx = PrivilegeContext.init();

    try escalatePrivileges(&ctx);
    defer dropPrivileges(&ctx) catch |err| {
        std.debug.print("Warning: Failed to drop privileges after operation: {}\n", .{err});
    };

    return @call(.auto, func, args);
}

// Tests
test "getCurrentUid and getCurrentGid" {
    const uid = getCurrentUid();
    const gid = getCurrentGid();

    // Just verify they return values (can't test specific values)
    try std.testing.expect(uid >= 0);
    try std.testing.expect(gid >= 0);
}

test "PrivilegeContext initialization" {
    const ctx = PrivilegeContext.init();

    try std.testing.expect(ctx.original_uid >= 0);
    try std.testing.expect(ctx.original_gid >= 0);
    try std.testing.expect(ctx.original_euid >= 0);
    try std.testing.expect(ctx.original_egid >= 0);
    try std.testing.expect(!ctx.escalated);
}

test "lookupUser - root" {
    // Root should always exist
    const uid = try lookupUser(std.testing.allocator, "root");
    try std.testing.expectEqual(@as(linux.uid_t, 0), uid);
}

test "lookupUser - nonexistent" {
    // This user should not exist
    const result = lookupUser(std.testing.allocator, "nonexistent_user_xyz123");
    try std.testing.expectError(PrivilegeError.UserNotFound, result);
}

test "lookupGroup - root" {
    // Root group should always exist
    const gid = try lookupGroup(std.testing.allocator, "root");
    try std.testing.expectEqual(@as(linux.gid_t, 0), gid);
}

test "lookupGroup - nonexistent" {
    // This group should not exist
    const result = lookupGroup(std.testing.allocator, "nonexistent_group_xyz123");
    try std.testing.expectError(PrivilegeError.GroupNotFound, result);
}

test "verifySetuidConfiguration" {
    // This should not fail, just print warnings if not configured
    try verifySetuidConfiguration();
}

// Note: The following tests require root privileges to fully test
// They will be skipped in non-root environments

test "privilege escalation (requires root)" {
    // Skip if not running as root
    if (getCurrentUid() != 0 and getCurrentEuid() != 0) {
        std.debug.print("Skipping privilege escalation test (not root)\n", .{});
        return error.SkipZigTest;
    }

    var ctx = PrivilegeContext.init();

    try escalatePrivileges(&ctx);
    try std.testing.expect(ctx.escalated);
    try std.testing.expectEqual(@as(linux.uid_t, 0), getCurrentEuid());

    try dropPrivileges(&ctx);
    try std.testing.expect(!ctx.escalated);
}
