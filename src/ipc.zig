const std = @import("std");
const posix = std.posix;
const config = @import("config.zig");
const daemon = @import("daemon.zig");
const logger = @import("logger.zig");
const monitor = @import("monitor.zig");
const user_lookup = @import("user_lookup.zig");

pub const socket_dir = "/run/zei";
pub const socket_path = socket_dir ++ "/zei.sock";

/// Maximum number of IPC connections to handle per signal loop iteration.
/// Prevents connection floods from starving signal handling.
pub const max_connections_per_poll = 4;

// -- Peer credential checking --

/// Linux ucred struct returned by SO_PEERCRED. Defined here rather than via
/// @cImport because the libc header requires _GNU_SOURCE, and the layout
/// is stable across Linux architectures.
const Ucred = extern struct {
    pid: posix.pid_t,
    uid: posix.uid_t,
    gid: posix.gid_t,

    comptime {
        std.debug.assert(@sizeOf(Ucred) == 12);
    }
};

/// Verify the connecting peer is either root or the app user.
/// Returns true if authorized, false if rejected.
fn checkPeerCredentials(fd: posix.fd_t, app_uid: posix.uid_t, log: logger.Logger) bool {
    var cred: Ucred = undefined;
    posix.getsockopt(fd, posix.SOL.SOCKET, posix.SO.PEERCRED, std.mem.asBytes(&cred)) catch {
        log.err("SO_PEERCRED failed", .{});
        return false;
    };

    if (cred.uid == 0 or cred.uid == app_uid) return true;

    log.warn("IPC connection rejected: peer uid={d}", .{cred.uid});
    return false;
}

// -- Request / Response protocol (JSON over Unix socket) --

pub const Command = enum {
    list,
    status,
    restart,
    signal,
};

pub const Request = struct {
    command: []const u8,
    service: ?[]const u8 = null,
    signal: ?[]const u8 = null,
};

// -- Response writing --

/// Write a JSON response to the connection stream.
pub fn writeResponse(
    w: anytype,
    success: bool,
    message: ?[]const u8,
    d: ?*const daemon.Daemon,
    service_name: ?[]const u8,
) !void {
    try w.writeAll("{\"success\":");
    try w.writeAll(if (success) "true" else "false");

    if (message) |msg| {
        try w.writeAll(",\"message\":\"");
        try writeJsonEscaped(w, msg);
        try w.writeByte('"');
    }

    if (d) |dm| {
        if (service_name) |name| {
            // Single service status.
            for (dm.statuses, 0..) |*status, i| {
                if (std.mem.eql(u8, dm.cfg.services[i].name, name)) {
                    try w.writeAll(",\"service\":");
                    try writeServiceStatus(w, &dm.cfg.services[i], status);
                    break;
                }
            }
        } else {
            // All services.
            try w.writeAll(",\"services\":{");
            var first = true;
            for (dm.statuses, 0..) |*status, i| {
                if (!first) try w.writeByte(',');
                first = false;
                try w.writeByte('"');
                try writeJsonEscaped(w, dm.cfg.services[i].name);
                try w.writeAll("\":");
                try writeServiceStatus(w, &dm.cfg.services[i], status);
            }
            try w.writeByte('}');
        }
    }

    try w.writeAll("}\n");
}

fn writeServiceStatus(w: anytype, svc: *const config.Service, status: *const monitor.ServiceStatus) !void {
    try w.writeAll("{\"name\":\"");
    try writeJsonEscaped(w, svc.name);
    try w.writeAll("\",\"running\":");
    try w.writeAll(if (status.state == .running) "true" else "false");
    try w.writeAll(",\"state\":\"");
    try w.writeAll(@tagName(status.state));
    try w.writeAll("\",\"pid\":");
    if (status.pid) |pid| {
        try std.fmt.format(w, "{d}", .{pid});
    } else {
        try w.writeAll("0");
    }
    try w.writeAll(",\"restarts\":");
    try std.fmt.format(w, "{d}", .{status.restart_count});
    if (status.started_at) |started| {
        try w.writeAll(",\"start_time\":");
        try std.fmt.format(w, "{d}", .{started});
    }
    if (status.restart_after) |restart_at| {
        try w.writeAll(",\"restart_at\":");
        try std.fmt.format(w, "{d}", .{restart_at});
    }
    try w.writeByte('}');
}

const writeJsonEscaped = logger.writeJsonEscaped;

// -- IPC Server --

pub const Server = struct {
    server: std.net.Server,
    log: logger.Logger,
    app_uid: posix.uid_t,

    pub fn init(log: logger.Logger, app_user: []const u8, app_group: []const u8) !Server {
        // Resolve the app user's credentials for peer credential checks
        // and socket directory ownership.
        const creds = user_lookup.lookup(app_user, app_group) catch |err| {
            log.err("failed to resolve app user '{s}:{s}': {s}", .{ app_user, app_group, @errorName(err) });
            return err;
        };
        // The security model assumes a non-root app user — directory ownership
        // and SO_PEERCRED checks are meaningless if the app user is root.
        if (creds.uid == 0) {
            log.err("app user must not be root", .{});
            return error.PermissionDenied;
        }

        // Ensure the socket directory exists with restrictive permissions.
        // 0o700 = owner only — service users (different UIDs) cannot access.
        posix.mkdir(socket_dir, 0o700) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                log.err("failed to create socket dir {s}: {s}", .{ socket_dir, @errorName(err) });
                return err;
            },
        };

        // Set ownership to the app user and enforce permissions. This runs
        // while we still have root effective UID (before privilege.drop in main).
        // Handles both fresh directories and pre-existing ones with wrong perms.
        {
            var dir = std.fs.openDirAbsolute(socket_dir, .{}) catch |err| {
                log.err("cannot open socket dir: {s}", .{@errorName(err)});
                return err;
            };
            defer dir.close();

            posix.fchown(dir.fd, creds.uid, creds.gid) catch |err| {
                log.err("cannot chown socket dir: {s}", .{@errorName(err)});
                return err;
            };
            dir.chmod(0o700) catch |err| {
                log.err("cannot chmod socket dir: {s}", .{@errorName(err)});
                return err;
            };
        }

        // Remove existing socket.
        std.fs.deleteFileAbsolute(socket_path) catch {};

        var addr = try std.net.Address.initUnix(socket_path);
        const server = try addr.listen(.{
            .force_nonblocking = true,
            .kernel_backlog = 8,
        });
        errdefer server.deinit();

        log.info("IPC server listening on {s}", .{socket_path});

        return .{
            .server = server,
            .log = log,
            .app_uid = creds.uid,
        };
    }

    pub fn deinit(self: *Server) void {
        self.server.deinit();
        std.fs.deleteFileAbsolute(socket_path) catch |err| {
            if (err != error.FileNotFound) {
                self.log.warn("failed to remove socket: {s}", .{@errorName(err)});
            }
        };
        self.* = undefined;
    }

    /// Try to accept and handle one pending connection (non-blocking).
    /// Returns true if a connection was handled, false if none pending.
    pub fn tryAccept(self: *Server, d: *daemon.Daemon) bool {
        const conn = self.server.accept() catch |err| {
            switch (err) {
                error.WouldBlock => return false,
                else => {
                    self.log.err("IPC accept error: {s}", .{@errorName(err)});
                    return false;
                },
            }
        };

        self.handleConnection(conn, d);
        return true;
    }

    fn handleConnection(self: *Server, conn: std.net.Server.Connection, d: *daemon.Daemon) void {
        defer conn.stream.close();

        // Verify the connecting process is authorized (root or app user).
        if (!checkPeerCredentials(conn.stream.handle, self.app_uid, self.log)) return;

        // The accepted socket inherits non-blocking from the listener.
        // Switch to blocking for the request/response exchange.
        const nonblock_bit: usize = 1 << @bitOffsetOf(posix.O, "NONBLOCK");
        const fl_flags = posix.fcntl(conn.stream.handle, posix.F.GETFL, 0) catch return;
        _ = posix.fcntl(conn.stream.handle, posix.F.SETFL, fl_flags & ~nonblock_bit) catch return;

        // Set a read timeout to prevent a slow/malicious client from blocking
        // the daemon's signal loop indefinitely. Drop the connection if it
        // fails — proceeding without a timeout defeats the purpose.
        {
            const timeout = std.c.timeval{ .sec = 2, .usec = 0 };
            posix.setsockopt(
                conn.stream.handle,
                posix.SOL.SOCKET,
                posix.SO.RCVTIMEO,
                std.mem.asBytes(&timeout),
            ) catch {
                self.log.warn("SO_RCVTIMEO failed, dropping connection", .{});
                return;
            };
        }

        // Read request (max 4KB).
        var buf: [4096]u8 = undefined;
        const n = posix.read(conn.stream.handle, &buf) catch |err| {
            self.log.err("IPC read error: {s}", .{@errorName(err)});
            return;
        };
        if (n == 0) return;

        self.dispatchRequest(buf[0..n], conn.stream.handle, d);
    }

    fn dispatchRequest(self: *Server, data: []const u8, fd: posix.fd_t, d: *daemon.Daemon) void {
        // Parse the JSON request using stack memory (requests are bounded at 4KB).
        var parse_buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&parse_buf);
        const req = std.json.parseFromSlice(Request, fba.allocator(), data, .{
            .ignore_unknown_fields = true,
        }) catch {
            sendSimpleResponse(fd, false, "invalid request format");
            return;
        };

        const cmd = std.meta.stringToEnum(Command, req.value.command) orelse {
            sendSimpleResponse(fd, false, "unknown command");
            return;
        };

        switch (cmd) {
            .list => handleList(fd, d),
            .status => handleStatus(fd, d, req.value.service),
            .restart => self.handleRestart(fd, d, req.value.service),
            .signal => self.handleSignal(fd, d, req.value.service, req.value.signal),
        }
    }

    fn handleList(fd: posix.fd_t, d: *daemon.Daemon) void {
        var buf: [8192]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        writeResponse(fbs.writer(), true, null, d, null) catch return;
        _ = posix.write(fd, fbs.getWritten()) catch {};
    }

    fn handleStatus(fd: posix.fd_t, d: *daemon.Daemon, service: ?[]const u8) void {
        if (service) |name| {
            if (d.cfg.getServiceIndex(name) == null) {
                sendSimpleResponse(fd, false, "service not found");
                return;
            }
        }

        var buf: [8192]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        writeResponse(fbs.writer(), true, null, d, service) catch return;
        _ = posix.write(fd, fbs.getWritten()) catch {};
    }

    fn handleRestart(self: *Server, fd: posix.fd_t, d: *daemon.Daemon, service: ?[]const u8) void {
        const name = service orelse {
            sendSimpleResponse(fd, false, "service name required");
            return;
        };

        const idx = d.cfg.getServiceIndex(name) orelse {
            sendSimpleResponse(fd, false, "service not found");
            return;
        };

        if (d.statuses[idx].state == .starting) {
            sendSimpleResponse(fd, false, "service is starting, try again later");
            return;
        }

        self.log.info("IPC restart requested for {s}", .{name});
        d.restartService(idx);

        sendSimpleResponse(fd, true, "restart requested");
    }

    fn handleSignal(self: *Server, fd: posix.fd_t, d: *daemon.Daemon, service: ?[]const u8, sig_str: ?[]const u8) void {
        const name = service orelse {
            sendSimpleResponse(fd, false, "service name required");
            return;
        };

        const sig_name = sig_str orelse {
            sendSimpleResponse(fd, false, "signal name required");
            return;
        };

        const sig = parseSignalName(sig_name) orelse {
            sendSimpleResponse(fd, false, "unsupported signal");
            return;
        };

        const idx = d.cfg.getServiceIndex(name) orelse {
            sendSimpleResponse(fd, false, "service not found");
            return;
        };

        const pid = d.statuses[idx].pid orelse {
            sendSimpleResponse(fd, false, "service not running");
            return;
        };

        d.elevatePrivileges() catch {
            sendSimpleResponse(fd, false, "privilege elevation failed");
            return;
        };
        defer d.dropPrivileges();

        d.sendSignalToService(idx, sig) catch |err| {
            self.log.err("signal failed: {s}", .{@errorName(err)});
            sendSimpleResponse(fd, false, "signal delivery failed");
            return;
        };

        self.log.info("sent signal {s} to {s} pid={d}", .{ sig_name, name, pid });
        sendSimpleResponse(fd, true, "signal sent");
    }

    fn sendSimpleResponse(fd: posix.fd_t, success: bool, message: []const u8) void {
        var buf: [1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        writeResponse(fbs.writer(), success, message, null, null) catch return;
        _ = posix.write(fd, fbs.getWritten()) catch {};
    }
};

fn parseSignalName(name: []const u8) ?u8 {
    if (std.mem.eql(u8, name, "HUP") or std.mem.eql(u8, name, "SIGHUP")) return posix.SIG.HUP;
    if (std.mem.eql(u8, name, "TERM") or std.mem.eql(u8, name, "SIGTERM")) return posix.SIG.TERM;
    if (std.mem.eql(u8, name, "KILL") or std.mem.eql(u8, name, "SIGKILL")) return posix.SIG.KILL;
    if (std.mem.eql(u8, name, "USR1") or std.mem.eql(u8, name, "SIGUSR1")) return posix.SIG.USR1;
    if (std.mem.eql(u8, name, "USR2") or std.mem.eql(u8, name, "SIGUSR2")) return posix.SIG.USR2;
    return null;
}

// -- Client helper (used by CLI) --

/// Response from the daemon, returned by sendRequest.
/// Caller must call deinit() when done.
pub const Response = struct {
    buf: []u8,
    len: usize,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.buf);
        self.* = undefined;
    }

    pub fn slice(self: *const Response) []const u8 {
        return self.buf[0..self.len];
    }
};

pub fn sendRequest(allocator: std.mem.Allocator, req: Request) !Response {
    const addr = try std.net.Address.initUnix(socket_path);

    // Connect via Unix socket.
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(fd);
    try posix.connect(fd, &addr.any, addr.getOsSockLen());

    // Serialize request.
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    try w.writeAll("{\"command\":\"");
    try writeJsonEscaped(w, req.command);
    try w.writeByte('"');
    if (req.service) |svc| {
        try w.writeAll(",\"service\":\"");
        try writeJsonEscaped(w, svc);
        try w.writeByte('"');
    }
    if (req.signal) |sig| {
        try w.writeAll(",\"signal\":\"");
        try writeJsonEscaped(w, sig);
        try w.writeByte('"');
    }
    try w.writeByte('}');

    _ = try posix.write(fd, fbs.getWritten());

    // Shutdown write side so the server knows we're done.
    posix.shutdown(fd, .send) catch {};

    // Read response into allocated buffer.
    const resp_buf = try allocator.alloc(u8, 8192);
    errdefer allocator.free(resp_buf);
    const n = try posix.read(fd, resp_buf);
    posix.close(fd);

    return .{ .buf = resp_buf, .len = n, .allocator = allocator };
}

// -- Tests --

test "writeResponse success with message" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeResponse(fbs.writer(), true, "ok", null, null);
    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"success\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"message\":\"ok\"") != null);
}

test "writeResponse failure" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeResponse(fbs.writer(), false, "bad request", null, null);
    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"success\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"message\":\"bad request\"") != null);
}

test "writeResponse with service statuses" {
    var cfg = try config.load(std.testing.allocator, "example/zei.yaml");
    defer cfg.deinit();

    var d = try daemon.Daemon.init(std.testing.allocator, &cfg, "appuser", "appgroup");
    defer d.deinit();

    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeResponse(fbs.writer(), true, null, &d, null);
    const output = fbs.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "\"services\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"state\":\"stopped\"") != null);
}

test "Command enum parses valid commands" {
    try std.testing.expectEqual(Command.list, std.meta.stringToEnum(Command, "list").?);
    try std.testing.expectEqual(Command.status, std.meta.stringToEnum(Command, "status").?);
    try std.testing.expectEqual(Command.restart, std.meta.stringToEnum(Command, "restart").?);
    try std.testing.expectEqual(Command.signal, std.meta.stringToEnum(Command, "signal").?);
}

test "Command enum rejects invalid command" {
    try std.testing.expect(std.meta.stringToEnum(Command, "invalid") == null);
}

test "parseSignalName valid signals" {
    try std.testing.expectEqual(posix.SIG.HUP, parseSignalName("HUP").?);
    try std.testing.expectEqual(posix.SIG.TERM, parseSignalName("SIGTERM").?);
    try std.testing.expectEqual(posix.SIG.KILL, parseSignalName("KILL").?);
    try std.testing.expectEqual(posix.SIG.USR1, parseSignalName("USR1").?);
    try std.testing.expectEqual(posix.SIG.USR2, parseSignalName("SIGUSR2").?);
}

test "parseSignalName invalid" {
    try std.testing.expect(parseSignalName("INVALID") == null);
}

test "writeJsonEscaped handles special chars" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeJsonEscaped(fbs.writer(), "hello \"world\"\nnewline");
    const output = fbs.getWritten();
    try std.testing.expectEqualStrings("hello \\\"world\\\"\\nnewline", output);
}

// -- Security hardening tests --

test "socket path is under /run, not /tmp" {
    try std.testing.expect(std.mem.startsWith(u8, socket_path, "/run/"));
    try std.testing.expect(!std.mem.startsWith(u8, socket_path, "/tmp/"));
}

test "socket directory path is prefix of socket path" {
    try std.testing.expect(std.mem.startsWith(u8, socket_path, socket_dir));
}

test "max_connections_per_poll is bounded" {
    try std.testing.expect(max_connections_per_poll > 0);
    try std.testing.expect(max_connections_per_poll <= 16);
}

test "checkPeerCredentials allows matching uid" {
    // Create a Unix socket pair to test SO_PEERCRED.
    var fds: [2]c_int = undefined;
    if (std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds) != 0) return error.SkipZigTest;
    defer posix.close(@intCast(fds[0]));
    defer posix.close(@intCast(fds[1]));

    const log = logger.Logger.initFromEnv().scoped("test");
    const our_uid = std.c.getuid();

    // Our own UID should be accepted when we set app_uid to match.
    try std.testing.expect(checkPeerCredentials(@intCast(fds[0]), our_uid, log));
}

test "checkPeerCredentials rejects unauthorized uid" {
    // Needs root to call setresuid.
    if (std.c.geteuid() != 0) return error.SkipZigTest;

    // SO_PEERCRED reports the effective UID. Set real and effective to
    // appuser so the peer isn't root (which is always authorized).
    // Use the setresuid syscall to explicitly keep root in the saved
    // set-user-ID slot — setreuid would overwrite it, locking us out.
    const appuser_uid = 1000;
    std.debug.assert(std.os.linux.E.init(std.os.linux.setresuid(appuser_uid, appuser_uid, 0)) == .SUCCESS);
    defer std.debug.assert(std.os.linux.E.init(std.os.linux.setresuid(0, 0, 0)) == .SUCCESS);

    var fds: [2]c_int = undefined;
    std.debug.assert(std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds) == 0);
    defer posix.close(@intCast(fds[0]));
    defer posix.close(@intCast(fds[1]));

    const log = logger.Logger.initFromEnv().scoped("test");

    // Peer UID is 1000 (appuser). Set app_uid to something else — should reject.
    try std.testing.expect(!checkPeerCredentials(@intCast(fds[0]), appuser_uid + 1, log));
}
