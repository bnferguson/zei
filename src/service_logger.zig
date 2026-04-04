const std = @import("std");
const logger = @import("logger.zig");

/// Process a single line of service output through the structured logger.
///
/// If `json_logs` is true, attempts to parse the line as JSON and extract
/// level/message fields. Falls back to plain text on parse failure.
pub fn processLine(
    log: logger.Logger,
    line: []const u8,
    stream: []const u8,
    json_logs: bool,
) void {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return;

    if (json_logs) {
        processJsonLine(log, trimmed, stream);
    } else {
        processPlainLine(log, trimmed, stream);
    }
}

fn processPlainLine(log: logger.Logger, line: []const u8, stream: []const u8) void {
    log.info("[{s}] {s}", .{ stream, line });
}

fn processJsonLine(log: logger.Logger, line: []const u8, stream: []const u8) void {
    // Try to parse as JSON.
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        std.heap.page_allocator,
        line,
        .{},
    ) catch {
        // Not valid JSON — fall back to plain text.
        processPlainLine(log, line, stream);
        return;
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |*o| o,
        else => {
            // Valid JSON but not an object — log as plain text.
            processPlainLine(log, line, stream);
            return;
        },
    };

    const level = extractLevel(obj);
    const message = extractMessage(obj);

    // Build a context string from remaining fields.
    var ctx_buf: [logger.Logger.max_line_length]u8 = undefined;
    var ctx_fbs = std.io.fixedBufferStream(&ctx_buf);
    const ctx_w = ctx_fbs.writer();
    writeContext(ctx_w, obj);
    const ctx = ctx_fbs.getWritten();

    // Log at the extracted level.
    const svc_log = log;
    switch (level) {
        .debug => if (ctx.len > 0)
            svc_log.debug("[{s}] {s} {s}", .{ stream, message, ctx })
        else
            svc_log.debug("[{s}] {s}", .{ stream, message }),
        .info => if (ctx.len > 0)
            svc_log.info("[{s}] {s} {s}", .{ stream, message, ctx })
        else
            svc_log.info("[{s}] {s}", .{ stream, message }),
        .warn => if (ctx.len > 0)
            svc_log.warn("[{s}] {s} {s}", .{ stream, message, ctx })
        else
            svc_log.warn("[{s}] {s}", .{ stream, message }),
        .err => if (ctx.len > 0)
            svc_log.err("[{s}] {s} {s}", .{ stream, message, ctx })
        else
            svc_log.err("[{s}] {s}", .{ stream, message }),
    }
}

/// Level field names to check, in priority order.
const level_fields = [_][]const u8{ "level", "severity", "lvl" };
/// Message field names to check, in priority order.
const message_fields = [_][]const u8{ "msg", "message", "text", "content" };

fn extractLevel(obj: *std.json.ObjectMap) logger.Level {
    for (level_fields) |field| {
        if (obj.get(field)) |val| {
            switch (val) {
                .string => |s| return parseLevel(s),
                else => {},
            }
        }
    }
    return .info;
}

fn extractMessage(obj: *std.json.ObjectMap) []const u8 {
    for (message_fields) |field| {
        if (obj.get(field)) |val| {
            switch (val) {
                .string => |s| return s,
                else => {},
            }
        }
    }
    return "(no message)";
}

fn parseLevel(s: []const u8) logger.Level {
    // Case-insensitive comparison via uppercase check.
    if (eqlIgnoreCase(s, "debug") or eqlIgnoreCase(s, "dbg") or eqlIgnoreCase(s, "trace")) return .debug;
    if (eqlIgnoreCase(s, "info") or eqlIgnoreCase(s, "information")) return .info;
    if (eqlIgnoreCase(s, "warn") or eqlIgnoreCase(s, "warning")) return .warn;
    if (eqlIgnoreCase(s, "error") or eqlIgnoreCase(s, "err") or
        eqlIgnoreCase(s, "fatal") or eqlIgnoreCase(s, "critical")) return .err;
    return .info;
}

/// Write remaining JSON fields (excluding level/message fields) as key=value pairs.
fn writeContext(w: anytype, obj: *std.json.ObjectMap) void {
    var first = true;
    var it = obj.iterator();
    while (it.next()) |entry| {
        // Skip fields we already extracted.
        if (isKnownField(entry.key_ptr.*)) continue;

        if (!first) w.writeByte(' ') catch return;
        first = false;

        w.print("{s}=", .{entry.key_ptr.*}) catch return;
        writeJsonValue(w, entry.value_ptr.*);
    }
}

fn isKnownField(key: []const u8) bool {
    for (level_fields) |f| {
        if (std.mem.eql(u8, key, f)) return true;
    }
    for (message_fields) |f| {
        if (std.mem.eql(u8, key, f)) return true;
    }
    return false;
}

fn writeJsonValue(w: anytype, val: std.json.Value) void {
    switch (val) {
        .string => |s| w.print("{s}", .{s}) catch return,
        .integer => |i| w.print("{d}", .{i}) catch return,
        .float => |f| w.print("{d}", .{f}) catch return,
        .bool => |b| w.print("{}", .{b}) catch return,
        .null => w.writeAll("null") catch return,
        else => w.writeAll("<complex>") catch return,
    }
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (std.ascii.toLower(ac) != std.ascii.toLower(bc)) return false;
    }
    return true;
}

// -- Pipe draining --

/// Read available lines from a file (typically a pipe) and process each
/// through the service logger. Uses non-blocking reads to avoid stalling
/// the daemon's main loop.
///
/// `remainder` holds partial line data between calls. The caller must
/// persist it across invocations for the same pipe.
pub fn drainPipe(
    file: std.fs.File,
    log: logger.Logger,
    stream: []const u8,
    json_logs: bool,
    remainder: *[4096]u8,
    remainder_len: *usize,
) void {
    // Read what's available.
    var read_buf: [4096]u8 = undefined;
    const n = file.read(&read_buf) catch |err| {
        switch (err) {
            error.WouldBlock => return, // No data available.
            else => return, // Pipe closed or other error.
        }
    };
    if (n == 0) return; // EOF.

    // Append to remainder and process complete lines.
    const data = read_buf[0..n];
    var start: usize = 0;
    for (data, 0..) |byte, i| {
        if (byte == '\n') {
            const line_end = i;
            if (remainder_len.* > 0) {
                // Combine remainder with this chunk.
                const avail = remainder.len - remainder_len.*;
                const copy_len = @min(line_end - start, avail);
                @memcpy(remainder[remainder_len.*..][0..copy_len], data[start..][0..copy_len]);
                processLine(log, remainder[0 .. remainder_len.* + copy_len], stream, json_logs);
                remainder_len.* = 0;
            } else {
                processLine(log, data[start..line_end], stream, json_logs);
            }
            start = i + 1;
        }
    }

    // Save any remaining partial line.
    if (start < data.len) {
        const leftover = data[start..];
        const avail = remainder.len - remainder_len.*;
        const copy_len = @min(leftover.len, avail);
        @memcpy(remainder[remainder_len.*..][0..copy_len], leftover[0..copy_len]);
        remainder_len.* += copy_len;
    }
}

// -- Tests --

fn testProcessLine(line: []const u8, stream: []const u8, json_logs: bool) [4096]u8 {
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const log = logger.Logger.init(fbs.writer().any(), .debug, .text)
        .scoped("service-output")
        .forService("test-svc");
    processLine(log, line, stream, json_logs);
    // Copy the written portion to return.
    var result: [4096]u8 = undefined;
    const written = fbs.getWritten();
    @memcpy(result[0..written.len], written);
    @memset(result[written.len..], 0);
    return result;
}

fn getOutput(buf: *const [4096]u8) []const u8 {
    // Find the zero-terminated portion.
    for (buf, 0..) |b, i| {
        if (b == 0) return buf[0..i];
    }
    return buf[0..];
}

test "processLine plain text" {
    const buf = testProcessLine("hello world", "stdout", false);
    const output = getOutput(&buf);
    try std.testing.expect(std.mem.indexOf(u8, output, "[stdout] hello world") != null);
}

test "processLine skips empty lines" {
    const buf = testProcessLine("", "stdout", false);
    const output = getOutput(&buf);
    try std.testing.expectEqual(@as(usize, 0), output.len);
}

test "processLine skips whitespace-only lines" {
    const buf = testProcessLine("   \t  ", "stdout", false);
    const output = getOutput(&buf);
    try std.testing.expectEqual(@as(usize, 0), output.len);
}

test "processLine JSON extracts level and message" {
    const buf = testProcessLine(
        \\{"level":"error","msg":"something broke","request_id":"abc123"}
    , "stderr", true);
    const output = getOutput(&buf);
    try std.testing.expect(std.mem.indexOf(u8, output, "ERROR") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "something broke") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "request_id=abc123") != null);
}

test "processLine JSON with severity field" {
    const buf = testProcessLine(
        \\{"severity":"WARNING","message":"disk low"}
    , "stdout", true);
    const output = getOutput(&buf);
    try std.testing.expect(std.mem.indexOf(u8, output, "WARN") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "disk low") != null);
}

test "processLine JSON with debug level" {
    const buf = testProcessLine(
        \\{"level":"debug","msg":"verbose info"}
    , "stdout", true);
    const output = getOutput(&buf);
    try std.testing.expect(std.mem.indexOf(u8, output, "DEBUG") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "verbose info") != null);
}

test "processLine JSON falls back on invalid JSON" {
    const buf = testProcessLine("this is not json", "stdout", true);
    const output = getOutput(&buf);
    // Should be logged as plain text.
    try std.testing.expect(std.mem.indexOf(u8, output, "[stdout] this is not json") != null);
}

test "processLine JSON falls back on non-object JSON" {
    const buf = testProcessLine("[1, 2, 3]", "stdout", true);
    const output = getOutput(&buf);
    try std.testing.expect(std.mem.indexOf(u8, output, "[stdout] [1, 2, 3]") != null);
}

test "processLine JSON with no message field" {
    const buf = testProcessLine(
        \\{"level":"info","status":"ok"}
    , "stdout", true);
    const output = getOutput(&buf);
    try std.testing.expect(std.mem.indexOf(u8, output, "(no message)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "status=ok") != null);
}

test "processLine JSON with case-insensitive level" {
    const buf = testProcessLine(
        \\{"level":"FATAL","msg":"crash"}
    , "stderr", true);
    const output = getOutput(&buf);
    try std.testing.expect(std.mem.indexOf(u8, output, "ERROR") != null);
}

test "extractLevel defaults to info" {
    try std.testing.expectEqual(logger.Level.info, parseLevel("unknown"));
}

test "parseLevel handles common variants" {
    try std.testing.expectEqual(logger.Level.debug, parseLevel("debug"));
    try std.testing.expectEqual(logger.Level.debug, parseLevel("DEBUG"));
    try std.testing.expectEqual(logger.Level.debug, parseLevel("trace"));
    try std.testing.expectEqual(logger.Level.info, parseLevel("info"));
    try std.testing.expectEqual(logger.Level.info, parseLevel("INFORMATION"));
    try std.testing.expectEqual(logger.Level.warn, parseLevel("warn"));
    try std.testing.expectEqual(logger.Level.warn, parseLevel("WARNING"));
    try std.testing.expectEqual(logger.Level.err, parseLevel("error"));
    try std.testing.expectEqual(logger.Level.err, parseLevel("FATAL"));
    try std.testing.expectEqual(logger.Level.err, parseLevel("critical"));
}

test "processLine includes service context" {
    const buf = testProcessLine("hello", "stdout", false);
    const output = getOutput(&buf);
    try std.testing.expect(std.mem.indexOf(u8, output, "service=test-svc") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "component=service-output") != null);
}
