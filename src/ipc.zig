const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

const config = @import("config.zig");
const daemon = @import("daemon.zig");
const logger = @import("logger.zig");
const monitor = @import("monitor.zig");
const privilege = @import("privilege.zig");

pub const socket_path = "/tmp/zei.sock";

// -- Request / Response protocol (JSON over Unix socket) --

pub const Command = enum {
    list,
    status,
    restart,
    signal,

    pub fn parse(s: []const u8) ?Command {
        return std.meta.stringToEnum(Command, s);
    }
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
    try w.writeByte('}');
}

fn writeJsonEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
}

// -- IPC Server --

pub const Server = struct {
    server: std.net.Server,
    log: logger.Logger,

    pub fn init(log: logger.Logger) !Server {
        // Remove existing socket.
        std.fs.deleteFileAbsolute(socket_path) catch {};

        var addr = try std.net.Address.initUnix(socket_path);
        const server = try addr.listen(.{
            .force_nonblocking = true,
            .kernel_backlog = 8,
        });

        log.info("IPC server listening on {s}", .{socket_path});

        return .{
            .server = server,
            .log = log,
        };
    }

    pub fn deinit(self: *Server) void {
        self.server.deinit();
        std.fs.deleteFileAbsolute(socket_path) catch {};
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

        // The accepted socket inherits non-blocking from the listener.
        // Switch to blocking for the request/response exchange.
        const nonblock_bit: usize = 1 << @bitOffsetOf(posix.O, "NONBLOCK");
        const fl_flags = posix.fcntl(conn.stream.handle, posix.F.GETFL, 0) catch return;
        _ = posix.fcntl(conn.stream.handle, posix.F.SETFL, fl_flags & ~nonblock_bit) catch return;

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
            self.writeError(fd, "invalid request format");
            return;
        };

        const cmd = Command.parse(req.value.command) orelse {
            self.writeError(fd, "unknown command");
            return;
        };

        switch (cmd) {
            .list => self.handleList(fd, d),
            .status => self.handleStatus(fd, d, req.value.service),
            .restart => self.handleRestart(fd, d, req.value.service),
            .signal => self.handleSignal(fd, d, req.value.service, req.value.signal),
        }
    }

    fn handleList(self: *Server, fd: posix.fd_t, d: *daemon.Daemon) void {
        _ = self;
        var buf: [8192]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        writeResponse(fbs.writer(), true, null, d, null) catch return;
        _ = posix.write(fd, fbs.getWritten()) catch {};
    }

    fn handleStatus(self: *Server, fd: posix.fd_t, d: *daemon.Daemon, service: ?[]const u8) void {
        _ = self;
        var buf: [8192]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);

        if (service) |name| {
            // Check if service exists.
            const found = for (d.cfg.services) |svc| {
                if (std.mem.eql(u8, svc.name, name)) break true;
            } else false;

            if (!found) {
                writeResponse(fbs.writer(), false, "service not found", null, null) catch return;
            } else {
                writeResponse(fbs.writer(), true, null, d, service) catch return;
            }
        } else {
            writeResponse(fbs.writer(), true, null, d, null) catch return;
        }

        _ = posix.write(fd, fbs.getWritten()) catch {};
    }

    fn handleRestart(self: *Server, fd: posix.fd_t, d: *daemon.Daemon, service: ?[]const u8) void {
        var buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);

        const name = service orelse {
            writeResponse(fbs.writer(), false, "service name required", null, null) catch return;
            _ = posix.write(fd, fbs.getWritten()) catch {};
            return;
        };

        const idx = for (d.cfg.services, 0..) |svc, i| {
            if (std.mem.eql(u8, svc.name, name)) break i;
        } else {
            writeResponse(fbs.writer(), false, "service not found", null, null) catch return;
            _ = posix.write(fd, fbs.getWritten()) catch {};
            return;
        };

        // Restart the service (elevates privileges on Linux).
        self.log.info("IPC restart requested for {s}", .{name});
        d.restartService(idx);

        writeResponse(fbs.writer(), true, "restart requested", null, null) catch return;
        _ = posix.write(fd, fbs.getWritten()) catch {};
    }

    fn handleSignal(self: *Server, fd: posix.fd_t, d: *daemon.Daemon, service: ?[]const u8, sig_str: ?[]const u8) void {
        var buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);

        const name = service orelse {
            writeResponse(fbs.writer(), false, "service name required", null, null) catch return;
            _ = posix.write(fd, fbs.getWritten()) catch {};
            return;
        };

        const sig_name = sig_str orelse {
            writeResponse(fbs.writer(), false, "signal name required", null, null) catch return;
            _ = posix.write(fd, fbs.getWritten()) catch {};
            return;
        };

        const sig = parseSignalName(sig_name) orelse {
            writeResponse(fbs.writer(), false, "unsupported signal", null, null) catch return;
            _ = posix.write(fd, fbs.getWritten()) catch {};
            return;
        };

        const idx = for (d.cfg.services, 0..) |svc, i| {
            if (std.mem.eql(u8, svc.name, name)) break i;
        } else {
            writeResponse(fbs.writer(), false, "service not found", null, null) catch return;
            _ = posix.write(fd, fbs.getWritten()) catch {};
            return;
        };

        const pid = d.statuses[idx].pid orelse {
            writeResponse(fbs.writer(), false, "service not running", null, null) catch return;
            _ = posix.write(fd, fbs.getWritten()) catch {};
            return;
        };

        // Elevate to send signal on Linux.
        if (builtin.os.tag == .linux) {
            privilege.elevate() catch {
                writeResponse(fbs.writer(), false, "privilege elevation failed", null, null) catch return;
                _ = posix.write(fd, fbs.getWritten()) catch {};
                return;
            };
            defer privilege.drop(d.app_user, d.app_group) catch {};
        }

        posix.kill(pid, sig) catch |err| {
            self.log.err("signal failed: {s}", .{@errorName(err)});
            writeResponse(fbs.writer(), false, "signal delivery failed", null, null) catch return;
            _ = posix.write(fd, fbs.getWritten()) catch {};
            return;
        };

        self.log.info("sent signal {s} to {s} pid={d}", .{ sig_name, name, pid });
        writeResponse(fbs.writer(), true, "signal sent", null, null) catch return;
        _ = posix.write(fd, fbs.getWritten()) catch {};
    }

    fn writeError(self: *Server, fd: posix.fd_t, message: []const u8) void {
        _ = self;
        var buf: [1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        writeResponse(fbs.writer(), false, message, null, null) catch return;
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
    var cfg = try config.load(std.testing.allocator, "example/zei.toml");
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

test "Command.parse valid commands" {
    try std.testing.expectEqual(Command.list, Command.parse("list").?);
    try std.testing.expectEqual(Command.status, Command.parse("status").?);
    try std.testing.expectEqual(Command.restart, Command.parse("restart").?);
    try std.testing.expectEqual(Command.signal, Command.parse("signal").?);
}

test "Command.parse invalid command" {
    try std.testing.expect(Command.parse("invalid") == null);
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
