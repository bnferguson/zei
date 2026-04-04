const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

const config = @import("config.zig");
const logger = @import("logger.zig");
const monitor = @import("monitor.zig");
const privilege = @import("privilege.zig");
const process = @import("process.zig");
const reaper = @import("reaper.zig");
const signal = @import("signal.zig");
const user_lookup = @import("user_lookup.zig");

pub const Daemon = struct {
    cfg: *config.Config,
    statuses: []monitor.ServiceStatus,
    spawns: []?process.SpawnResult,
    log: logger.Logger,
    app_user: []const u8,
    app_group: []const u8,
    allocator: std.mem.Allocator,
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
        @memset(spawns, null);

        return .{
            .cfg = cfg,
            .statuses = statuses,
            .spawns = spawns,
            .log = logger.Logger.initFromEnv().scoped("daemon"),
            .app_user = app_user,
            .app_group = app_group,
            .allocator = allocator,
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
    fn restartService(self: *Daemon, idx: usize) void {
        const svc = &self.cfg.services[idx];
        const svc_log = self.log.forService(svc.name);

        // On Linux as PID 1, we need to elevate before spawning
        // with different credentials. On macOS (testing), skip.
        if (builtin.os.tag == .linux) {
            privilege.elevate() catch |err| {
                svc_log.err("elevate failed for restart: {s}", .{@errorName(err)});
                return;
            };
        }

        self.startService(idx);

        if (builtin.os.tag == .linux) {
            privilege.drop(self.app_user, self.app_group) catch |err| {
                svc_log.err("drop failed after restart: {s}", .{@errorName(err)});
            };
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

        const decision = monitor.evaluateRestart(svc, status, exit_info);
        switch (decision) {
            .restart => {
                status.restart_count += 1;
                if (svc.max_restarts > 0) {
                    svc_log.info("restarting ({d}/{d})", .{ status.restart_count, svc.max_restarts });
                } else {
                    svc_log.info("restarting ({d}/unlimited)", .{status.restart_count});
                }
                // NOTE: blocking sleep delays signal handling for the duration.
                // Acceptable for short restart delays in a container init system.
                // For long delays, consider timestamp-based scheduling.
                const delay_ns = svc.restartDelayNs();
                sleepNs(delay_ns);
                self.restartService(idx);
            },
            .schedule => {
                const interval_ns = svc.intervalNs() orelse return;
                svc_log.info("oneshot complete, next run in {d}ms", .{interval_ns / std.time.ns_per_ms});
                sleepNs(interval_ns);
                self.restartService(idx);
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

        if (builtin.os.tag == .linux) {
            privilege.elevate() catch |err| {
                shutdown_log.err("elevate failed for shutdown: {s}", .{@errorName(err)});
            };
        }

        // Send SIGTERM to all running services.
        for (self.statuses, 0..) |*status, i| {
            if (status.state == .running) {
                if (status.pid) |pid| {
                    const svc_log = shutdown_log.forService(self.cfg.services[i].name);
                    posix.kill(pid, posix.SIG.TERM) catch |err| {
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
            for (self.statuses) |*status| {
                if (status.state == .running or status.state == .stopping) {
                    if (status.pid) |pid| {
                        posix.kill(pid, posix.SIG.KILL) catch |kill_err| {
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
        if (builtin.os.tag == .linux) {
            privilege.elevate() catch |err| {
                self.log.err("elevate failed for signal forwarding: {s}", .{@errorName(err)});
                return;
            };
        }

        for (self.statuses, 0..) |*status, i| {
            if (status.state == .running) {
                if (status.pid) |pid| {
                    posix.kill(pid, sig) catch |err| {
                        self.log.forService(self.cfg.services[i].name)
                            .err("signal {d} failed: {s}", .{ sig, @errorName(err) });
                    };
                }
            }
        }

        if (builtin.os.tag == .linux) {
            privilege.drop(self.app_user, self.app_group) catch |err| {
                self.log.err("drop failed after signal forwarding: {s}", .{@errorName(err)});
            };
        }
    }

    // -- Helpers --

    fn findServiceByPid(self: *const Daemon, pid: posix.pid_t) ?usize {
        for (self.statuses, 0..) |*status, i| {
            if (status.pid != null and status.pid.? == pid) return i;
        }
        return null;
    }

    fn hasRunningServices(self: *const Daemon) bool {
        for (self.statuses) |*status| {
            if (status.state == .running or status.state == .stopping) return true;
        }
        return false;
    }

    fn buildEnvMap(self: *Daemon, svc: *const config.Service) !std.process.EnvMap {
        var env = std.process.EnvMap.init(self.allocator);
        errdefer env.deinit();

        if (svc.environment) |env_config| {
            var it = env_config.map.iterator();
            while (it.next()) |entry| {
                try env.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        return env;
    }

    fn sleepNs(ns: u64) void {
        const secs: u64 = ns / std.time.ns_per_s;
        const frac: u64 = ns % std.time.ns_per_s;
        posix.nanosleep(@intCast(secs), @intCast(frac));
    }
};

// -- Tests --

test "daemon init and deinit" {
    var cfg = try config.load(std.testing.allocator, "example/zei.toml");
    defer cfg.deinit();

    var d = try Daemon.init(std.testing.allocator, &cfg, "appuser", "appgroup");
    defer d.deinit();

    try std.testing.expect(d.statuses.len == cfg.services.len);
    for (d.statuses) |status| {
        try std.testing.expectEqual(monitor.ServiceState.stopped, status.state);
    }
}

test "daemon starts echo service" {
    var cfg = try config.load(std.testing.allocator, "example/zei.toml");
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
    var cfg = try config.load(std.testing.allocator, "example/zei.toml");
    defer cfg.deinit();

    var d = try Daemon.init(std.testing.allocator, &cfg, "appuser", "appgroup");
    defer d.deinit();

    // Simulate a running service.
    d.statuses[0].recordStarted(12345);
    try std.testing.expectEqual(@as(?usize, 0), d.findServiceByPid(12345));
    try std.testing.expect(d.findServiceByPid(99999) == null);
}

test "daemon hasRunningServices" {
    var cfg = try config.load(std.testing.allocator, "example/zei.toml");
    defer cfg.deinit();

    var d = try Daemon.init(std.testing.allocator, &cfg, "appuser", "appgroup");
    defer d.deinit();

    try std.testing.expect(!d.hasRunningServices());

    d.statuses[0].recordStarted(1);
    try std.testing.expect(d.hasRunningServices());
}
