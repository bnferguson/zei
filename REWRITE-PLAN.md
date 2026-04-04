# Rewrite pei (Go) as zei (Zig) — Full Feature Parity

## Context

`pei` is a ~1,600-line Go init system for OCI containers. It manages multiple services as PID 1, handles privilege escalation via setuid, reaps zombies, and provides a CLI over Unix socket IPC. The previous Zig attempt (`zei` on `main`) was an MVP that never implemented IPC, CLI, structured logging, oneshot services, or JSON log parsing. This rewrite starts fresh on the `rewrite` branch targeting full parity with idiomatic Zig 0.15.2.

**Key decisions:**
- **Config format:** TOML (not YAML — drops the zig-yaml dependency)
- **User/group lookup:** Link libc for `getpwnam`/`getgrnam` (C interop exercise)
- **Scope:** Full feature parity with Go `pei`

## Module Layout

```
src/
  main.zig          — Entry point, flag parsing, daemon vs CLI routing
  config.zig        — TOML config parsing (Service, Config structs)
  daemon.zig        — Core daemon: service lifecycle orchestration
  process.zig       — Process spawning, pipe setup, credential setting
  privilege.zig     — setreuid/setregid privilege escalation/dropping
  user_lookup.zig   — libc getpwnam/getgrnam wrappers
  monitor.zig       — Service monitoring, restart policy evaluation
  reaper.zig        — Zombie reaping via waitpid
  signal.zig        — Signal mask setup, handler dispatch
  ipc.zig           — Unix socket server + request/response protocol
  cli.zig           — CLI commands (list, status, restart, signal, help)
  logger.zig        — Structured logging (text/JSON, component-scoped)
  service_logger.zig — Service stdout/stderr capture + JSON log parsing
build.zig
build.zig.zon
```

## Session Checklist

Each session is designed to produce a compilable, testable increment. Sessions build on each other sequentially. At the start of each session, read this file and check off completed items.

### Session 1: Project Skeleton + Config Parsing
- [x] Initialize build.zig and build.zig.zon for Zig 0.15.2
- [x] Find/evaluate a TOML library for Zig 0.15.2 (sam701/zig-toml @ zig-0.15 branch)
- [x] Define `Config` and `Service` structs matching pei's fields:
  - name, command, user, group, working_dir, environment
  - restart (always/on-failure/never), max_restarts, restart_delay
  - depends_on, stdout, stderr, interval, oneshot, json_logs
- [x] Implement `config.load(allocator, path) -> Config`
- [x] Write unit tests: valid config, missing file, oneshot, env vars, json_logs, duration parsing
- [x] Create example config file (`example/zei.toml`)
- [x] Verify: `zig build test` passes

### Session 2: Logging
- [x] Implement structured logger (text and JSON output modes)
- [x] Read `ZEI_LOG_LEVEL` (debug/info/warn/error) and `ZEI_LOG_FORMAT` (text/json) from env
- [x] Component-scoped logging (`logger.scoped("reaper")` adds component field)
- [x] Service-scoped logging (`logger.forService("echo")` adds service field)
- [x] Write unit tests for level filtering and format output
- [x] Verify: `zig build test` passes

### Session 3: Privilege Management + User Lookup (C Interop)
- [x] Implement libc bindings for `getpwnam`, `getgrnam` in user_lookup.zig
- [x] `lookup(username, groupname) -> Credentials{uid, gid}`
- [x] Implement `drop(username, groupname)` — setregid then setreuid (GID first for CAP_SETGID)
- [x] Implement `elevate()` — setreuid then setregid (UID first to restore CAP_SETGID)
- [x] Handle partial failure recovery with rollback
- [x] Errno checking on getpwnam/getgrnam (distinguish not-found from system error)
- [x] Docker test environment with Zig 0.15.2, appuser/appgroup for privilege tests
- [x] Write unit tests + Docker round-trip test (drop to appuser, verify, elevate back)
- [x] Verify: `zig build test` passes (macOS + Docker)

### Session 4: Process Spawning
- [x] Implement process.zig: spawn child with piped stdout/stderr via std.process.Child
- [x] Set child credentials via uid/gid fields (setuid/setgid before exec)
- [x] Build argv from config command slice
- [x] Set environment variables on child
- [x] Set working directory
- [x] Return pid + pipe file handles (caller reaps via waitpid in reaper loop)
- [x] Write unit tests (echo, stderr, cwd, env vars, exit codes, uid/gid)
- [x] Verify: `zig build test` passes (macOS + Docker)

### Session 5: Service Monitor + Restart Logic
- [x] Implement ServiceState enum (stopped, starting, running, stopping, failed)
- [x] Implement ServiceStatus struct (running, pid, exit_code, restarts, started_at)
- [x] Restart policy evaluation: always, on-failure (non-zero exit), never
- [x] Max restart limit checking
- [x] Restart delay (configurable per service)
- [x] Oneshot service support (run once per interval)
- [x] Write unit tests for each restart policy scenario
- [x] Verify: `zig build test` passes

### Session 6: Zombie Reaper
- [x] Implement reaper.zig: `reapChildren()` using waitpid with WNOHANG
- [x] Parse exit status (normal exit vs signal death)
- [x] Return list of reaped PIDs with exit info
- [x] Integration with service manager (identify managed vs orphaned children)
- [x] Write unit tests (fork+exit a child, verify reaping)
- [x] Verify: `zig build test` passes

### Session 7: Signal Handling
- [x] Set up signal mask: block SIGTERM, SIGINT, SIGQUIT, SIGHUP, SIGUSR1, SIGUSR2, SIGCHLD, SIGPIPE
- [x] Implement signal dispatch:
  - SIGTERM/SIGINT/SIGQUIT -> initiate graceful shutdown
  - SIGHUP/SIGUSR1/SIGUSR2 -> forward to all services
  - SIGCHLD -> trigger reaper
  - SIGPIPE -> ignore
- [x] Use `sigtimedwait` on Linux, fallback polling on macOS
- [x] Write tests for signal mask setup
- [x] Verify: `zig build test` passes

### Session 8: Daemon Core (Tying It Together)
- [x] Implement daemon.zig: `Daemon` struct holding config, service statuses, spawn results
- [x] `startAll()` / `startService()`: lookup creds, build env, spawn, track status
- [x] `reapAndProcess()`: reap zombies, match to services, evaluate restart decisions
- [x] `restartService()`: elevate -> spawn -> drop (Linux only)
- [x] `shutdownServices()`: SIGTERM all -> 30s timeout -> SIGKILL
- [x] `forwardSignalToServices()`: elevate -> signal each -> drop
- [x] `run()`: signal loop dispatching shutdown/forward/reap actions
- [x] Single-threaded design (no mutex needed — signal loop is synchronous)
- [x] Write tests: init/deinit, start echo service, findServiceByPid, hasRunningServices
- [x] Verify: `zig build test` passes

### Session 9: Service Output Capture + JSON Log Parsing
- [x] Implement service_logger.zig: read from stdout/stderr pipes line-by-line
- [x] Route output through structured logger with service context (name, pid, user, stream)
- [x] JSON log parsing when `json_logs = true`:
  - Extract level from `level`/`severity`/`lvl` field
  - Extract message from `msg`/`message`/`text`/`content` field
  - Preserve remaining fields as service context
  - Fallback to plain text on parse failure
- [x] drainPipe() for non-blocking pipe reading with remainder buffering
- [x] Write unit tests for plain text and JSON log parsing
- [x] Verify: `zig build test` passes

### Session 10: IPC Server
- [x] Implement ipc.zig: Unix domain socket server at `/tmp/zei.sock`
- [x] Define request/response protocol (JSON over socket, matching pei's format):
  - IPCRequest: command, service, signal
  - IPCResponse: success, message, services, service
- [x] Handle commands: list, status, restart, signal
- [x] Signal command: elevate privileges, send signal, drop privileges
- [x] Clean up socket on shutdown
- [x] Non-blocking accept for integration with daemon signal loop
- [x] Client helper sendRequest() for CLI
- [x] Write unit tests for request parsing and response encoding
- [x] Verify: `zig build test` passes

### Session 11: CLI Client
- [x] Implement cli.zig: parse subcommands (list, status, restart, signal, help)
- [x] `list`: connect to IPC, display service table (name, status, PID, restarts, uptime)
- [x] `status [service]`: detailed status for one or all services
- [x] `restart <service>`: send restart request
- [x] `signal <service:signal>`: send signal (HUP, TERM, KILL, USR1, USR2)
- [x] `help`: usage information
- [x] Fallback to config-only display when daemon not running
- [x] Format uptime as human-readable (e.g., "2h30m")
- [x] Wire into main.zig: route to CLI when not PID 1
- [x] Write unit tests for formatting and argument parsing
- [x] Verify: `zig build test` passes

### Session 12: Main Entry Point + Integration
- [x] Implement main.zig: flag parsing (-c config path, -help)
- [x] Route: PID 1 + root -> daemon mode; otherwise -> CLI mode
- [x] Read `ZEI_APP_USER` / `ZEI_APP_GROUP` env vars (default: "appuser")
- [x] Wire all modules together
- [x] Verify full build: `zig build`

### Session 13: Docker + System Testing
- [ ] Write Dockerfile (Alpine, Zig 0.15.2, create test users)
- [ ] Write docker-compose.yml
- [ ] Write Makefile (build, test, docker-build, docker-run, run-local, run-dev)
- [ ] Create test configs (simple echo, multi-service, restart test)
- [ ] End-to-end test: build in Docker, run as PID 1, verify via CLI
- [ ] Test privilege escalation/dropping
- [ ] Test zombie reaping
- [ ] Test graceful shutdown (SIGTERM -> wait -> SIGKILL)
- [ ] Test IPC commands from CLI

### Session 14: Polish + README
- [ ] Review all modules against idiomatic Zig standards
- [ ] Ensure proper allocator discipline (every alloc has a corresponding free)
- [ ] Error handling audit: no silent failures
- [ ] Write README.md
- [ ] Write example configs with comments
- [ ] Final `zig build test` + Docker test pass

## Key Reference Files

**Go source (pei):** `/Users/bnferguson/dev/pei/`
- `daemon.go` (646 lines) — core logic, service lifecycle, signal handling, shutdown
- `ipc.go` (214 lines) — Unix socket IPC protocol
- `cli.go` (216 lines) — CLI commands and formatting
- `config.go` (62 lines) — YAML config structs
- `privilege.go` (81 lines) — setreuid/setregid privilege management
- `service_logger.go` (191 lines) — output capture + JSON log parsing
- `logger.go` (56 lines) — slog-based structured logging
- `main.go` (98 lines) — entry point and routing

**Zig 0.15.2 notes:** `/Users/bnferguson/dev/zei/.claude/CLAUDE.md`

## Verification

Each session ends with `zig build test`. Final verification:
1. `zig build` produces static binary
2. `zig build test` — all unit tests pass
3. Docker build + run as PID 1 with test config
4. CLI commands work: `zei list`, `zei status`, `zei restart <svc>`, `zei signal <svc:TERM>`
5. Graceful shutdown on SIGTERM
6. Zombie processes reaped
7. Services restart per policy
8. Privilege drop confirmed (main process runs as appuser after startup)
