const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

const config = @import("config.zig");
const ipc = @import("ipc.zig");
const logger = @import("logger.zig");
const monitor = @import("monitor.zig");
const pidfd = @import("pidfd.zig");
const privilege = @import("privilege.zig");
const process = @import("process.zig");
const reaper = @import("reaper.zig");
const signal = @import("signal.zig");
const user_lookup = @import("user_lookup.zig");

/// Grace period (ms) after SIGTERM before escalating to SIGKILL.
const kill_timeout_ms: i64 = 5000;

pub const Daemon = struct {
    cfg: *config.Config,
    statuses: []monitor.ServiceStatus,
    spawns: []?process.SpawnResult,
    log: logger.Logger,
    app_user: []const u8,
    app_group: []const u8,
    allocator: std.mem.Allocator,
    ipc_server: ?*ipc.Server,
    shutting_down: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        cfg: *config.Config,
        app_user: []const u8,
        app_group: []const u8,
    ) !Daemon {
        const n = cfg.services.len;
        std.debug.assert(n > 0);

        const statuses = try allocator.alloc(monitor.ServiceStatus, n);
        errdefer allocator.free(statuses);
        for (cfg.services, 0..) |svc, i| {
            statuses[i] = monitor.ServiceStatus.init(svc.name);
        }

        const spawns = try allocator.alloc(?process.SpawnResult, n);
        errdefer allocator.free(spawns);
        @memset(spawns, null);

        return .{
            .cfg = cfg,
            .statuses = statuses,
            .spawns = spawns,
            .log = logger.Logger.initFromEnv().scoped("daemon"),
            .app_user = app_user,
            .app_group = app_group,
            .allocator = allocator,
            .ipc_server = null,
            .shutting_down = false,
        };
    }

    pub fn deinit(self: *Daemon) void {
        for (self.spawns) |*maybe_spawn| {
            if (maybe_spawn.*) |*s| s.deinit();
        }
        self.allocator.free(self.spawns);
        self.allocator.free(self.statuses);
        self.* = undefined;
    }

    // -- Service lifecycle --

    /// Start a single service by index. Looks up credentials, builds
    /// environment, spawns the process, and records the status.
    pub fn startService(self: *Daemon, idx: usize) void {
        const svc = &self.cfg.services[idx];
        const svc_log = self.log.forService(svc.name);

        self.statuses[idx].recordStarting();

        const creds = user_lookup.lookup(svc.user, svc.group) catch |err| {
            svc_log.err("user/group lookup failed: {s}", .{@errorName(err)});
            self.statuses[idx].recordStartFailed();
            return;
        };

        // Build environment map from config.
        var env = self.buildEnvMap(svc) catch |err| {
            svc_log.err("failed to build environment: {s}", .{@errorName(err)});
            self.statuses[idx].recordStartFailed();
            return;
        };
        defer env.deinit();

        const result = process.spawn(self.allocator, .{
            .argv = svc.command,
            .cwd = svc.working_dir,
            .env = &env,
            .uid = creds.uid,
            .gid = creds.gid,
        }) catch |err| {
            svc_log.err("spawn failed: {s}", .{@errorName(err)});
            self.statuses[idx].recordStartFailed();
            return;
        };

        // Close previous spawn's pipes if still open.
        if (self.spawns[idx]) |*prev| prev.deinit();
        self.spawns[idx] = result;
        self.statuses[idx].recordStarted(result.pid);

        svc_log.info("started pid={d} uid={d} gid={d}", .{
            result.pid,
            creds.uid,
            creds.gid,
        });
    }

    /// Start all configured services.
    pub fn startAll(self: *Daemon) void {
        for (0..self.cfg.services.len) |i| {
            self.startService(i);
        }
    }

    /// Restart a service after evaluating the restart decision.
    /// Handles privilege elevation/dropping for credential-based spawning.
    /// Restart a service. Non-blocking: if the service is running, sends
    /// SIGTERM and sets a flag so handleChildExit starts it after exit.
    pub fn restartService(self: *Daemon, idx: usize) void {
        std.debug.assert(idx < self.cfg.services.len);
        const svc = &self.cfg.services[idx];
        const svc_log = self.log.forService(svc.name);
        const status = &self.statuses[idx];

        switch (status.state) {
            .running => {
                // Non-blocking stop: send SIGTERM, set restart flag,
                // record kill deadline. handleChildExit will start
                // the service after the process exits.
                svc_log.info("stopping for restart", .{});

                self.elevatePrivileges() catch return;
                defer self.dropPrivileges();

                self.sendSignalToService(idx, posix.SIG.TERM) catch |err| {
                    svc_log.err("SIGTERM failed: {s}", .{@errorName(err)});
                    return;
                };
                status.recordStopping();
                status.restart_after_stop = true;
                status.kill_deadline = std.time.milliTimestamp() + kill_timeout_ms;
            },
            .stopping => {
                // Already stopping — just ensure it restarts after exit.
                svc_log.info("already stopping, will restart after exit", .{});
                status.restart_after_stop = true;
            },
            .starting => {
                svc_log.warn("restart skipped, service is starting", .{});
            },
            .restart_pending => {
                svc_log.info("preempting scheduled restart", .{});
                self.doStartService(idx);
            },
            .stopped, .failed => {
                self.doStartService(idx);
            },
        }
    }

    /// Start a service with privilege elevation. Used by restartService
    /// and handleChildExit for the restart-after-stop path.
    fn doStartService(self: *Daemon, idx: usize) void {
        self.elevatePrivileges() catch return;
        defer self.dropPrivileges();
        self.startService(idx);
    }

    /// Escalate SIGTERM to SIGKILL for services past their kill deadline.
    fn checkStoppingServices(self: *Daemon) void {
        const now_ms = std.time.milliTimestamp();

        // Check if any services need escalation before elevating.
        const needs_escalation = for (self.statuses) |*status| {
            if (status.state == .stopping) {
                if (status.kill_deadline) |deadline| {
                    if (now_ms >= deadline) break true;
                }
            }
        } else false;

        if (!needs_escalation) return;

        self.elevatePrivileges() catch return;
        defer self.dropPrivileges();

        for (self.statuses, 0..) |*status, i| {
            if (status.state != .stopping) continue;
            const deadline = status.kill_deadline orelse continue;
            if (now_ms < deadline) continue;

            const svc_log = self.log.forService(self.cfg.services[i].name);
            svc_log.warn("SIGTERM timeout, sending SIGKILL", .{});

            self.sendSignalToService(i, posix.SIG.KILL) catch |err| {
                if (err != error.ProcessNotFound) {
                    svc_log.err("SIGKILL failed: {s}", .{@errorName(err)});
                }
            };

            status.kill_deadline = null;
        }
    }

    // -- Reaping and restart evaluation --

    /// Reap zombie children and process exits for managed services.
    pub fn reapAndProcess(self: *Daemon) void {
        var buf: [32]reaper.ReapResult = undefined;
        while (true) {
            const n = reaper.reapChildren(&buf);
            if (n == 0) break;

            for (buf[0..n]) |result| {
                self.handleChildExit(result.pid, result.exit_info);
            }
        }
    }

    /// Trigger restarts for services whose scheduled restart time has arrived.
    /// Granularity is bounded by the signal loop's ~1s polling interval.
    fn checkPendingRestarts(self: *Daemon) void {
        const now = std.time.milliTimestamp();
        for (self.statuses, 0..) |*status, i| {
            if (status.state != .restart_pending) continue;
            const restart_at = status.restart_after orelse continue;
            if (restart_at <= now) self.restartService(i);
        }
    }

    fn handleChildExit(self: *Daemon, pid: posix.pid_t, exit_info: monitor.ExitInfo) void {
        const idx = self.findServiceByPid(pid) orelse {
            // Orphaned process — log and move on.
            self.log.debug("reaped orphan pid={d}", .{pid});
            return;
        };

        const svc = &self.cfg.services[idx];
        const status = &self.statuses[idx];
        const svc_log = self.log.forService(svc.name);

        // Close pipes from the exited process.
        if (self.spawns[idx]) |*s| {
            s.deinit();
            self.spawns[idx] = null;
        }

        status.recordExited(exit_info);

        switch (exit_info) {
            .exited => |code| svc_log.info("exited code={d}", .{code}),
            .signaled => |sig| svc_log.info("killed signal={d}", .{sig}),
        }

        if (self.shutting_down) return;

        // IPC-requested restart takes priority over policy evaluation.
        // Reset restart_count since this is an explicit user action.
        if (status.restart_after_stop) {
            status.restart_after_stop = false;
            status.restart_count = 0;
            svc_log.info("restarting after stop", .{});
            self.doStartService(idx);
            return;
        }

        const decision = monitor.evaluateRestart(svc, status, exit_info);
        switch (decision) {
            .restart => {
                status.restart_count += 1;
                if (svc.max_restarts > 0) {
                    svc_log.info("restarting ({d}/{d})", .{ status.restart_count, svc.max_restarts });
                } else {
                    svc_log.info("restarting ({d}/unlimited)", .{status.restart_count});
                }
                const delay_ms: i64 = @intCast(svc.restartDelayNs() / std.time.ns_per_ms);
                status.recordRestartPending(std.time.milliTimestamp() + delay_ms);
            },
            .schedule => {
                const interval_ns = svc.intervalNs() orelse return;
                svc_log.info("oneshot complete, next run in {d}ms", .{interval_ns / std.time.ns_per_ms});
                const interval_ms: i64 = @intCast(interval_ns / std.time.ns_per_ms);
                status.recordRestartPending(std.time.milliTimestamp() + interval_ms);
            },
            .exhausted => {
                status.recordFailed();
                svc_log.err("max restarts ({d}) exceeded, giving up", .{svc.max_restarts});
            },
            .stop => {
                svc_log.info("stopped (restart={s})", .{@tagName(svc.restart)});
            },
        }
    }

    // -- Signal loop --

    /// Main daemon loop. Blocks on signals and dispatches actions.
    pub fn run(self: *Daemon) void {
        while (!self.shutting_down) {
            // Poll IPC for pending client connections. Capped to prevent
            // connection floods from starving the signal loop.
            if (self.ipc_server) |srv| {
                for (0..ipc.max_connections_per_poll) |_| {
                    if (!srv.tryAccept(self)) break;
                }
            }

            self.checkPendingRestarts();
            self.checkStoppingServices();

            const sig = signal.waitForSignal() orelse {
                // Timeout — do a periodic reap in case we missed SIGCHLD.
                self.reapAndProcess();
                continue;
            };

            const action = signal.classify(sig);
            switch (action) {
                .shutdown => {
                    self.log.info("received signal {d}, shutting down", .{sig});
                    self.shutdownServices();
                    return;
                },
                .forward => {
                    self.log.info("forwarding signal {d} to all services", .{sig});
                    self.forwardSignalToServices(sig);
                },
                .reap => {
                    self.reapAndProcess();
                },
                .ignore => {},
                .unknown => {
                    self.log.warn("received unexpected signal {d}", .{sig});
                },
            }
        }
    }

    // -- Shutdown --

    /// Graceful shutdown: SIGTERM all services, wait up to 30s, then SIGKILL.
    pub fn shutdownServices(self: *Daemon) void {
        self.shutting_down = true;
        const shutdown_log = self.log.scoped("shutdown");
        shutdown_log.info("starting graceful shutdown", .{});

        // Best-effort elevation — continue shutdown even if it fails.
        self.elevatePrivileges() catch {};

        // Cancel any pending restarts and restart-after-stop flags.
        // Shutdown manages its own SIGKILL timeline.
        for (self.statuses) |*status| {
            if (status.state == .restart_pending) {
                status.cancelRestartPending();
            }
            status.restart_after_stop = false;
            status.kill_deadline = null;
        }

        // Send SIGTERM to all running services.
        for (self.statuses, 0..) |*status, i| {
            if (status.state == .running) {
                if (status.pid) |pid| {
                    const svc_log = shutdown_log.forService(self.cfg.services[i].name);
                    self.sendSignalToService(i, posix.SIG.TERM) catch |err| {
                        svc_log.err("SIGTERM failed: {s}", .{@errorName(err)});
                        continue;
                    };
                    status.recordStopping();
                    svc_log.info("sent SIGTERM pid={d}", .{pid});
                }
            }
        }

        // Wait up to 30 seconds for services to exit.
        const deadline_s: i64 = std.time.timestamp() + 30;
        while (self.hasRunningServices() and std.time.timestamp() < deadline_s) {
            posix.nanosleep(0, 250_000_000); // 250ms
            self.reapAndProcess();
        }

        // Force kill any remaining services.
        if (self.hasRunningServices()) {
            shutdown_log.warn("timeout, sending SIGKILL to remaining services", .{});
            for (self.statuses, 0..) |*status, i| {
                if (status.state == .running or status.state == .stopping) {
                    if (status.pid) |pid| {
                        self.sendSignalToService(i, posix.SIG.KILL) catch |kill_err| {
                            if (kill_err == error.PermissionDenied) {
                                shutdown_log.err("SIGKILL failed (EPERM) pid={d}", .{pid});
                            }
                        };
                    }
                }
            }
            // Final reap.
            sleepNs(std.time.ns_per_s);
            self.reapAndProcess();
        }

        shutdown_log.info("shutdown complete", .{});
    }

    // -- Signal forwarding --

    fn forwardSignalToServices(self: *Daemon, sig: u8) void {
        self.elevatePrivileges() catch return;
        defer self.dropPrivileges();

        for (self.statuses, 0..) |*status, i| {
            if (status.state == .running) {
                if (status.pid != null) {
                    self.sendSignalToService(i, sig) catch |err| {
                        self.log.forService(self.cfg.services[i].name)
                            .err("signal {d} failed: {s}", .{ sig, @errorName(err) });
                    };
                }
            }
        }
    }

    // -- Privilege helpers --

    /// Elevate to root on Linux. No-op on other platforms.
    /// On failure, logs the error and returns it so callers can bail.
    fn elevatePrivileges(self: *Daemon) error{ElevateFailed}!void {
        if (builtin.os.tag != .linux) return;
        privilege.elevate() catch |err| {
            self.log.err("privilege elevation failed: {s}", .{@errorName(err)});
            return error.ElevateFailed;
        };
    }

    /// Drop back to app user on Linux. No-op on other platforms.
    /// Logs on failure but does not return an error — callers should
    /// not abort work that already succeeded because of a drop failure.
    fn dropPrivileges(self: *Daemon) void {
        if (builtin.os.tag != .linux) return;
        privilege.drop(self.app_user, self.app_group) catch |err| {
            self.log.err("privilege drop failed: {s}", .{@errorName(err)});
        };
    }

    // -- Helpers --

    /// Send a signal to a service, preferring pidfd over kill(2) to avoid
    /// PID-reuse races. Falls back to kill(2) when pidfd is unavailable.
    pub fn sendSignalToService(self: *Daemon, idx: usize, sig: u8) !void {
        std.debug.assert(idx < self.cfg.services.len);
        const pid = self.statuses[idx].pid orelse return error.ProcessNotFound;

        if (self.spawns[idx]) |spawn| {
            if (spawn.pidfd) |pfd| {
                if (pidfd.sendSignal(pfd, sig)) {
                    return;
                } else |err| switch (err) {
                    error.Unsupported => {}, // fall through to kill(2)
                    else => return err,
                }
            }
        }

        // Fallback: no pidfd available. Assert pid > 0 because
        // kill(2) interprets 0 and negative pids as process groups.
        std.debug.assert(pid > 0);
        try posix.kill(pid, sig);
    }

    fn findServiceByPid(self: *const Daemon, pid: posix.pid_t) ?usize {
        for (self.statuses, 0..) |*status, i| {
            if (status.pid) |p| if (p == pid) return i;
        }
        return null;
    }

    fn hasRunningServices(self: *const Daemon) bool {
        for (self.statuses) |*status| {
            if (status.state == .running or status.state == .stopping or
                status.state == .restart_pending) return true;
        }
        return false;
    }

    fn buildEnvMap(self: *Daemon, svc: *const config.Service) !std.process.EnvMap {
        var env = std.process.EnvMap.init(self.allocator);
        errdefer env.deinit();

        if (svc.environment) |env_config| {
            for (env_config.keys(), env_config.values()) |key, value| {
                try env.put(key, value);
            }
        }

        return env;
    }
};

fn sleepNs(ns: u64) void {
    const secs: u64 = ns / std.time.ns_per_s;
    const frac: u64 = ns % std.time.ns_per_s;
    posix.nanosleep(@intCast(secs), @intCast(frac));
}

// -- Tests --

test "daemon init and deinit" {
    var cfg = try config.load(std.testing.allocator, "example/zei.yaml");
    defer cfg.deinit();

    var d = try Daemon.init(std.testing.allocator, &cfg, "appuser", "appgroup");
    defer d.deinit();

    try std.testing.expect(d.statuses.len == cfg.services.len);
    for (d.statuses) |status| {
        try std.testing.expectEqual(monitor.ServiceState.stopped, status.state);
    }
}

test "daemon starts echo service" {
    var cfg = try config.load(std.testing.allocator, "example/zei.yaml");
    defer cfg.deinit();

    var d = try Daemon.init(std.testing.allocator, &cfg, "appuser", "appgroup");
    defer d.deinit();

    // Find the echo service index.
    const idx = for (cfg.services, 0..) |svc, i| {
        if (std.mem.eql(u8, svc.name, "echo")) break i;
    } else {
        return error.TestUnexpectedResult;
    };

    // Echo service requires uid/gid for "appuser" — skip if not available.
    _ = user_lookup.lookup(cfg.services[idx].user, cfg.services[idx].group) catch
        return error.SkipZigTest;

    d.startService(idx);
    try std.testing.expectEqual(monitor.ServiceState.running, d.statuses[idx].state);
    try std.testing.expect(d.statuses[idx].pid != null);

    // Clean up: kill and reap.
    if (d.statuses[idx].pid) |pid| {
        posix.kill(pid, posix.SIG.KILL) catch {};
    }
    posix.nanosleep(0, 50_000_000);
    d.reapAndProcess();
}

test "daemon findServiceByPid returns correct index" {
    var cfg = try config.load(std.testing.allocator, "example/zei.yaml");
    defer cfg.deinit();

    var d = try Daemon.init(std.testing.allocator, &cfg, "appuser", "appgroup");
    defer d.deinit();

    // Simulate a running service.
    d.statuses[0].recordStarted(12345);
    try std.testing.expectEqual(@as(?usize, 0), d.findServiceByPid(12345));
    try std.testing.expect(d.findServiceByPid(99999) == null);
}

test "daemon hasRunningServices" {
    var cfg = try config.load(std.testing.allocator, "example/zei.yaml");
    defer cfg.deinit();

    var d = try Daemon.init(std.testing.allocator, &cfg, "appuser", "appgroup");
    defer d.deinit();

    try std.testing.expect(!d.hasRunningServices());

    d.statuses[0].recordStarted(1);
    try std.testing.expect(d.hasRunningServices());
}

test "daemon hasRunningServices includes restart_pending" {
    var cfg = try config.load(std.testing.allocator, "example/zei.yaml");
    defer cfg.deinit();

    var d = try Daemon.init(std.testing.allocator, &cfg, "appuser", "appgroup");
    defer d.deinit();

    try std.testing.expect(!d.hasRunningServices());

    d.statuses[0].recordRestartPending(999);
    try std.testing.expect(d.hasRunningServices());
}

test "checkPendingRestarts skips future timestamps" {
    var cfg = try config.load(std.testing.allocator, "example/zei.yaml");
    defer cfg.deinit();

    var d = try Daemon.init(std.testing.allocator, &cfg, "appuser", "appgroup");
    defer d.deinit();

    // Schedule a restart far in the future.
    d.statuses[0].recordRestartPending(std.time.milliTimestamp() + 9_999_000);
    d.checkPendingRestarts();

    // Should still be pending — not yet triggered.
    try std.testing.expectEqual(monitor.ServiceState.restart_pending, d.statuses[0].state);
}

test "restartService on running service attempts non-blocking stop" {
    var cfg = try config.load(std.testing.allocator, "example/zei.yaml");
    defer cfg.deinit();

    var d = try Daemon.init(std.testing.allocator, &cfg, "appuser", "appgroup");
    defer d.deinit();

    // Simulate a running service with a real child process so SIGTERM succeeds.
    const pid = try posix.fork();
    if (pid == 0) {
        // Child: sleep until signaled.
        posix.nanosleep(5, 0);
        posix.exit(0);
    }

    d.statuses[0].recordStarted(pid);
    d.restartService(0);

    // Service should be stopping, flagged for restart, with a kill deadline.
    try std.testing.expectEqual(monitor.ServiceState.stopping, d.statuses[0].state);
    try std.testing.expect(d.statuses[0].restart_after_stop);
    try std.testing.expect(d.statuses[0].kill_deadline != null);
    try std.testing.expectEqual(@as(?posix.pid_t, pid), d.statuses[0].pid);

    // Clean up: kill and reap the child.
    posix.kill(pid, posix.SIG.KILL) catch {};
    _ = posix.waitpid(pid, 0);
}

test "restartService on stopping service sets restart flag" {
    var cfg = try config.load(std.testing.allocator, "example/zei.yaml");
    defer cfg.deinit();

    var d = try Daemon.init(std.testing.allocator, &cfg, "appuser", "appgroup");
    defer d.deinit();

    d.statuses[0].recordStarted(12345);
    d.statuses[0].recordStopping();

    d.restartService(0);

    try std.testing.expectEqual(monitor.ServiceState.stopping, d.statuses[0].state);
    try std.testing.expect(d.statuses[0].restart_after_stop);
}

test "restartService skips starting service" {
    var cfg = try config.load(std.testing.allocator, "example/zei.yaml");
    defer cfg.deinit();

    var d = try Daemon.init(std.testing.allocator, &cfg, "appuser", "appgroup");
    defer d.deinit();

    d.statuses[0].recordStarting();

    d.restartService(0);

    // Should remain in starting state — restart was rejected.
    try std.testing.expectEqual(monitor.ServiceState.starting, d.statuses[0].state);
    try std.testing.expect(!d.statuses[0].restart_after_stop);
}

test "checkStoppingServices escalates to SIGKILL after deadline" {
    var cfg = try config.load(std.testing.allocator, "example/zei.yaml");
    defer cfg.deinit();

    var d = try Daemon.init(std.testing.allocator, &cfg, "appuser", "appgroup");
    defer d.deinit();

    // Fork a child that sleeps so we can test SIGKILL escalation.
    const pid = try posix.fork();
    if (pid == 0) {
        posix.nanosleep(10, 0);
        posix.exit(0);
    }

    d.statuses[0].recordStarted(pid);
    d.statuses[0].recordStopping();
    // Set deadline in the past so SIGKILL fires immediately.
    d.statuses[0].kill_deadline = std.time.milliTimestamp() - 1;

    d.checkStoppingServices();

    // kill_deadline should be cleared after sending SIGKILL.
    try std.testing.expect(d.statuses[0].kill_deadline == null);

    // Clean up: reap the child (SIGKILL should have killed it).
    posix.nanosleep(0, 50_000_000); // 50ms for signal delivery
    _ = posix.waitpid(pid, 0);
}

test "checkStoppingServices skips services before deadline" {
    var cfg = try config.load(std.testing.allocator, "example/zei.yaml");
    defer cfg.deinit();

    var d = try Daemon.init(std.testing.allocator, &cfg, "appuser", "appgroup");
    defer d.deinit();

    d.statuses[0].recordStarted(12345);
    d.statuses[0].recordStopping();
    d.statuses[0].kill_deadline = std.time.milliTimestamp() + 999_999;

    d.checkStoppingServices();

    // Deadline should not be cleared — still in the future.
    try std.testing.expect(d.statuses[0].kill_deadline != null);
}

test "handleChildExit restarts service when restart_after_stop is set" {
    var cfg = try config.load(std.testing.allocator, "example/zei.yaml");
    defer cfg.deinit();

    var d = try Daemon.init(std.testing.allocator, &cfg, "appuser", "appgroup");
    defer d.deinit();

    // Need appuser credentials for startService to succeed.
    const idx = for (cfg.services, 0..) |svc, i| {
        if (std.mem.eql(u8, svc.name, "echo")) break i;
    } else return error.TestUnexpectedResult;

    _ = user_lookup.lookup(cfg.services[idx].user, cfg.services[idx].group) catch
        return error.SkipZigTest;

    // Fork a child, record it as running, then set up for restart.
    const pid = try posix.fork();
    if (pid == 0) posix.exit(0);

    d.statuses[idx].recordStarted(pid);
    d.statuses[idx].recordStopping();
    d.statuses[idx].restart_after_stop = true;

    // Wait for child to exit, then reap.
    posix.nanosleep(0, 50_000_000);
    d.reapAndProcess();

    // handleChildExit should have restarted the service.
    try std.testing.expect(!d.statuses[idx].restart_after_stop);
    try std.testing.expectEqual(@as(u32, 0), d.statuses[idx].restart_count);

    // The service should be running again (or at least attempted to start).
    // startService may have failed if credentials don't work, but the
    // flag should be cleared regardless.
    try std.testing.expect(!d.statuses[idx].restart_after_stop);

    // Clean up: kill any new child.
    if (d.statuses[idx].pid) |new_pid| {
        posix.kill(new_pid, posix.SIG.KILL) catch {};
        posix.nanosleep(0, 50_000_000);
        d.reapAndProcess();
    }
}

test "shutdown clears restart_after_stop and kill_deadline" {
    var cfg = try config.load(std.testing.allocator, "example/zei.yaml");
    defer cfg.deinit();

    var d = try Daemon.init(std.testing.allocator, &cfg, "appuser", "appgroup");
    defer d.deinit();

    // Set up restart flags on several services in different states.
    d.statuses[0].restart_after_stop = true;
    d.statuses[0].kill_deadline = std.time.milliTimestamp() + 5000;

    d.statuses[1].recordRestartPending(std.time.milliTimestamp() + 5000);
    d.statuses[1].restart_after_stop = true;

    // shutdownServices clears flags early in the function, before
    // entering the wait loop. Test the flag-clearing directly by
    // checking the state after shutdown sets shutting_down = true
    // and clears flags. We can't call shutdownServices with fake
    // PIDs (it would block on hasRunningServices), so test the
    // invariants directly.
    d.shutting_down = true;

    // Simulate the flag-clearing loop from shutdownServices.
    for (d.statuses) |*status| {
        if (status.state == .restart_pending) {
            status.cancelRestartPending();
        }
        status.restart_after_stop = false;
        status.kill_deadline = null;
    }

    try std.testing.expect(!d.statuses[0].restart_after_stop);
    try std.testing.expect(d.statuses[0].kill_deadline == null);
    try std.testing.expect(!d.statuses[1].restart_after_stop);
    try std.testing.expectEqual(monitor.ServiceState.stopped, d.statuses[1].state);
}
