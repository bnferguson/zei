const std = @import("std");

pub const Level = enum(u2) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }

    pub fn parse(val: ?[]const u8) Level {
        const s = val orelse return .info;
        if (std.mem.eql(u8, s, "debug")) return .debug;
        if (std.mem.eql(u8, s, "info")) return .info;
        if (std.mem.eql(u8, s, "warn")) return .warn;
        if (std.mem.eql(u8, s, "error")) return .err;
        return .info;
    }
};

pub const Format = enum {
    text,
    json,

    pub fn parse(val: ?[]const u8) Format {
        const s = val orelse return .text;
        if (std.mem.eql(u8, s, "json")) return .json;
        return .text;
    }
};

pub const Logger = struct {
    level: Level,
    format: Format,
    component: ?[]const u8 = null,
    service: ?[]const u8 = null,
    writer: std.io.AnyWriter,

    pub const max_line_length = 4096;

    // Logger is copied by value in scoped()/forService() — keep it small.
    comptime {
        std.debug.assert(@sizeOf(Logger) <= 64);
    }

    /// Create a logger with explicit settings.
    pub fn init(writer: std.io.AnyWriter, level: Level, format: Format) Logger {
        return .{ .level = level, .format = format, .writer = writer };
    }

    /// Create a logger configured from ZEI_LOG_LEVEL and ZEI_LOG_FORMAT env vars.
    pub fn initFromEnv() Logger {
        const level_str = std.posix.getenv("ZEI_LOG_LEVEL");
        const format_str = std.posix.getenv("ZEI_LOG_FORMAT");
        return init(
            stderrWriter(),
            Level.parse(level_str),
            Format.parse(format_str),
        );
    }

    /// An AnyWriter that writes to stderr via the POSIX fd directly.
    /// Avoids the std.fs.File.writer() API which requires a buffer in 0.15.2.
    fn stderrWriter() std.io.AnyWriter {
        return .{
            .context = @ptrFromInt(std.posix.STDERR_FILENO),
            .writeFn = &stderrWriteFn,
        };
    }

    fn stderrWriteFn(context: *const anyopaque, bytes: []const u8) anyerror!usize {
        const fd: std.posix.fd_t = @intCast(@intFromPtr(context));
        return std.posix.write(fd, bytes);
    }

    /// Return a new logger scoped to a component.
    pub fn scoped(self: Logger, component_name: []const u8) Logger {
        var l = self;
        l.component = component_name;
        return l;
    }

    /// Return a new logger scoped to a service.
    pub fn forService(self: Logger, service_name: []const u8) Logger {
        var l = self;
        l.service = service_name;
        return l;
    }

    pub fn debug(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.write(.debug, fmt, args);
    }

    pub fn info(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.write(.info, fmt, args);
    }

    pub fn warn(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.write(.warn, fmt, args);
    }

    pub fn err(self: Logger, comptime fmt: []const u8, args: anytype) void {
        self.write(.err, fmt, args);
    }

    fn write(self: Logger, level: Level, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(level) < @intFromEnum(self.level)) return;

        var msg_buf: [max_line_length]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch |e| switch (e) {
            error.NoSpaceLeft => blk: {
                @memcpy(msg_buf[max_line_length - 3 ..], "...");
                break :blk msg_buf[0..max_line_length];
            },
        };

        var buf: [max_line_length]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();

        switch (self.format) {
            .text => formatText(w, level, self.component, self.service, msg),
            .json => formatJson(w, level, self.component, self.service, msg),
        }
        w.writeByte('\n') catch return;

        // Fire-and-forget: if stderr is broken on PID 1, there's nowhere to report it.
        self.writer.writeAll(fbs.getWritten()) catch {};
    }

    fn formatText(w: anytype, level: Level, component: ?[]const u8, service: ?[]const u8, msg: []const u8) void {
        writeTimestamp(w);
        w.print(" {s}", .{level.label()}) catch return;
        if (component) |c| w.print(" component={s}", .{c}) catch return;
        if (service) |s| w.print(" service={s}", .{s}) catch return;
        w.print(" {s}", .{msg}) catch return;
    }

    fn formatJson(w: anytype, level: Level, component: ?[]const u8, service: ?[]const u8, msg: []const u8) void {
        w.writeAll("{\"time\":\"") catch return;
        writeTimestamp(w);
        w.print("\",\"level\":\"{s}\"", .{level.label()}) catch return;
        if (component) |c| {
            w.writeAll(",\"component\":\"") catch return;
            writeJsonEscaped(w, c);
            w.writeByte('"') catch return;
        }
        if (service) |s| {
            w.writeAll(",\"service\":\"") catch return;
            writeJsonEscaped(w, s);
            w.writeByte('"') catch return;
        }
        w.writeAll(",\"msg\":\"") catch return;
        writeJsonEscaped(w, msg);
        w.writeAll("\"}") catch return;
    }

    fn writeJsonEscaped(w: anytype, s: []const u8) void {
        for (s) |c| {
            switch (c) {
                '"' => w.writeAll("\\\"") catch return,
                '\\' => w.writeAll("\\\\") catch return,
                '\n' => w.writeAll("\\n") catch return,
                '\r' => w.writeAll("\\r") catch return,
                '\t' => w.writeAll("\\t") catch return,
                0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => {
                    w.print("\\u{x:0>4}", .{c}) catch return;
                },
                else => w.writeByte(c) catch return,
            }
        }
    }

    fn writeTimestamp(w: anytype) void {
        const raw_ts = std.time.timestamp();
        const ts: u64 = if (raw_ts < 0) 0 else @intCast(raw_ts);
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = ts };
        const epoch_day = epoch_seconds.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_seconds = epoch_seconds.getDaySeconds();

        w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
            year_day.year,
            @intFromEnum(month_day.month),
            @as(u9, month_day.day_index) + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        }) catch {};
    }
};

// -- Tests --

test "Level.parse parses valid levels" {
    try std.testing.expectEqual(Level.debug, Level.parse("debug"));
    try std.testing.expectEqual(Level.info, Level.parse("info"));
    try std.testing.expectEqual(Level.warn, Level.parse("warn"));
    try std.testing.expectEqual(Level.err, Level.parse("error"));
}

test "Level.parse defaults to info" {
    try std.testing.expectEqual(Level.info, Level.parse(null));
    try std.testing.expectEqual(Level.info, Level.parse("garbage"));
}

test "Format.parse parses valid formats" {
    try std.testing.expectEqual(Format.json, Format.parse("json"));
    try std.testing.expectEqual(Format.text, Format.parse("text"));
}

test "Format.parse defaults to text" {
    try std.testing.expectEqual(Format.text, Format.parse(null));
    try std.testing.expectEqual(Format.text, Format.parse("garbage"));
}

test "level filtering suppresses lower levels" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const logger = Logger.init(fbs.writer().any(), .warn, .text);

    logger.debug("should not appear", .{});
    logger.info("should not appear", .{});
    try std.testing.expectEqual(@as(usize, 0), fbs.getWritten().len);

    logger.warn("should appear", .{});
    try std.testing.expect(fbs.getWritten().len > 0);
}

test "level filtering allows equal and higher levels" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const logger = Logger.init(fbs.writer().any(), .info, .text);

    logger.info("info message", .{});
    const after_info = fbs.getWritten().len;
    try std.testing.expect(after_info > 0);

    logger.err("error message", .{});
    try std.testing.expect(fbs.getWritten().len > after_info);
}

test "text format includes level and message" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const logger = Logger.init(fbs.writer().any(), .debug, .text);

    logger.info("hello world", .{});
    const output = fbs.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, output, "INFO") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "hello world") != null);
}

test "text format includes component when scoped" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const logger = Logger.init(fbs.writer().any(), .debug, .text).scoped("reaper");

    logger.info("reaped zombie", .{});
    const output = fbs.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, output, "component=reaper") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "reaped zombie") != null);
}

test "text format includes service when set" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const logger = Logger.init(fbs.writer().any(), .debug, .text)
        .scoped("daemon")
        .forService("echo");

    logger.info("started", .{});
    const output = fbs.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, output, "component=daemon") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "service=echo") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "started") != null);
}

test "json format produces valid structure" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const logger = Logger.init(fbs.writer().any(), .debug, .json)
        .scoped("monitor")
        .forService("web");

    logger.warn("restart needed", .{});
    const output = fbs.getWritten();

    try std.testing.expect(output.len > 0);
    try std.testing.expect(output[0] == '{');
    try std.testing.expect(std.mem.indexOf(u8, output, "\"level\":\"WARN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"component\":\"monitor\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"service\":\"web\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"msg\":\"restart needed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"time\":\"") != null);
}

test "json format escapes special characters" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const logger = Logger.init(fbs.writer().any(), .debug, .json);

    logger.info("line1\nline2\ttab \"quoted\"", .{});
    const output = fbs.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, output, "line1\\nline2\\ttab \\\"quoted\\\"") != null);
}

test "json format escapes control characters as unicode" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const logger = Logger.init(fbs.writer().any(), .debug, .json);

    logger.info("before\x01after", .{});
    const output = fbs.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, output, "before\\u0001after") != null);
}

test "text format includes timestamp" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const logger = Logger.init(fbs.writer().any(), .debug, .text);

    logger.info("test", .{});
    const output = fbs.getWritten();

    // Timestamp format: YYYY-MM-DDTHH:MM:SSZ.
    try std.testing.expect(output.len > 20);
    try std.testing.expect(output[4] == '-');
    try std.testing.expect(output[10] == 'T');
    try std.testing.expect(std.mem.indexOf(u8, output, "Z") != null);
}

test "scoped returns independent logger" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const base = Logger.init(fbs.writer().any(), .debug, .text);
    const child = base.scoped("child");

    try std.testing.expect(base.component == null);
    try std.testing.expectEqualStrings("child", child.component.?);
}

test "forService returns independent logger" {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const base = Logger.init(fbs.writer().any(), .debug, .text);
    const svc = base.forService("echo");

    try std.testing.expect(base.service == null);
    try std.testing.expectEqualStrings("echo", svc.service.?);
}

test "Level.label returns correct names" {
    try std.testing.expectEqualStrings("DEBUG", Level.debug.label());
    try std.testing.expectEqualStrings("INFO", Level.info.label());
    try std.testing.expectEqualStrings("WARN", Level.warn.label());
    try std.testing.expectEqualStrings("ERROR", Level.err.label());
}
