const std = @import("std");

const c = @cImport({
    @cInclude("pwd.h");
    @cInclude("grp.h");
});

pub const Credentials = struct {
    uid: std.posix.uid_t,
    gid: std.posix.gid_t,
};

pub const LookupError = error{
    UserNotFound,
    GroupNotFound,
    SystemError,
    NameTooLong,
};

const max_name_length = 256;

/// Look up a user and group by name, returning their numeric uid and gid.
/// Both getpwnam and getgrnam use static buffers, so we extract numeric IDs
/// immediately before the next call can overwrite them.
pub fn lookup(username: []const u8, groupname: []const u8) LookupError!Credentials {
    const uid = try lookupUser(username);
    const gid = try lookupGroup(groupname);
    return .{ .uid = uid, .gid = gid };
}

pub fn lookupUser(name: []const u8) LookupError!std.posix.uid_t {
    std.debug.assert(name.len > 0);
    var buf: [max_name_length + 1]u8 = undefined;
    const name_z = toCString(&buf, name) orelse return error.NameTooLong;

    // getpwnam returns NULL for both "not found" (errno unchanged) and
    // system errors (errno set). Clear errno first to distinguish them.
    std.c._errno().* = 0;
    const pw = c.getpwnam(name_z);
    if (pw == null) {
        return if (std.c._errno().* != 0) error.SystemError else error.UserNotFound;
    }
    return pw.?.*.pw_uid;
}

pub fn lookupGroup(name: []const u8) LookupError!std.posix.gid_t {
    std.debug.assert(name.len > 0);
    var buf: [max_name_length + 1]u8 = undefined;
    const name_z = toCString(&buf, name) orelse return error.NameTooLong;

    std.c._errno().* = 0;
    const gr = c.getgrnam(name_z);
    if (gr == null) {
        return if (std.c._errno().* != 0) error.SystemError else error.GroupNotFound;
    }
    return gr.?.*.gr_gid;
}

fn toCString(buf: *[max_name_length + 1]u8, s: []const u8) ?[*:0]const u8 {
    if (s.len > max_name_length) return null;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return @ptrCast(buf);
}

// -- Tests --

test "lookupUser finds root" {
    const uid = try lookupUser("root");
    try std.testing.expectEqual(@as(std.posix.uid_t, 0), uid);
}

test "lookupGroup finds gid 0 group" {
    const gid = try lookupGroup("root");
    try std.testing.expectEqual(@as(std.posix.gid_t, 0), gid);
}

test "lookup returns both uid and gid" {
    const creds = try lookup("root", "root");
    try std.testing.expectEqual(@as(std.posix.uid_t, 0), creds.uid);
    try std.testing.expectEqual(@as(std.posix.gid_t, 0), creds.gid);
}

test "lookupUser returns UserNotFound for nonexistent user" {
    const result = lookupUser("__no_such_user_zei_test__");
    try std.testing.expectError(error.UserNotFound, result);
}

test "lookupGroup returns GroupNotFound for nonexistent group" {
    const result = lookupGroup("__no_such_group_zei_test__");
    try std.testing.expectError(error.GroupNotFound, result);
}

test "lookupUser returns NameTooLong for oversized name" {
    const long_name = "a" ** (max_name_length + 1);
    const result = lookupUser(long_name);
    try std.testing.expectError(error.NameTooLong, result);
}

test "lookupUser accepts name at max length" {
    // A 256-char name should not trigger NameTooLong (it won't exist, but
    // the error should be UserNotFound, not NameTooLong).
    const exact_name = "a" ** max_name_length;
    const result = lookupUser(exact_name);
    try std.testing.expectError(error.UserNotFound, result);
}

test "lookup finds appuser in Docker" {
    // appuser/appgroup are created in the Dockerfile for testing.
    const creds = lookup("appuser", "appgroup") catch |err| {
        // Skip if not running in the Docker container.
        if (err == error.UserNotFound or err == error.GroupNotFound) return error.SkipZigTest;
        return err;
    };
    try std.testing.expectEqual(@as(std.posix.uid_t, 1000), creds.uid);
    try std.testing.expectEqual(@as(std.posix.gid_t, 1000), creds.gid);
}
