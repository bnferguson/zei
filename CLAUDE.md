# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is zei?

zei is a lightweight container init system (PID 1 supervisor) written in Zig. It manages child processes inside Docker containers: spawning services with per-service credentials, reaping zombies, forwarding signals, handling graceful shutdown, and providing a CLI/IPC interface for runtime control.

## Build & Test

zei is **Linux-only** — it's a container init system and will not compile on other platforms. A `comptime` assertion in `main.zig` enforces this. Build and test via Docker:

```sh
make docker-build                  # build Docker image
make docker-test                   # run unit tests inside Linux container
make docker-e2e                    # run end-to-end tests via test/e2e.sh
```

Zig version: **0.15.2**. The project links libc (`link_libc = true`) for POSIX user/group lookup (`getpwnam`, `getgrnam`), `setreuid`/`setregid`, and `sigtimedwait`.

Unit tests live alongside their source in each `.zig` file (no separate test directory). Many tests load `example/zei.yaml` and some require the `appuser` user to exist (they return `SkipZigTest` when it doesn't). The `comptime` block in `main.zig` forces all modules to be analyzed and their tests discovered.

E2E tests (`test/e2e.sh`) run on the host, spinning up Docker containers and verifying behavior via `docker exec`. They require Docker.

## Architecture

zei has two modes determined at startup in `main.zig`:

1. **Daemon mode** (PID 1): blocks signals, loads config, spawns services, drops privileges, enters the signal loop.
2. **CLI mode** (not PID 1): sends JSON commands to the daemon over a Unix socket (`/run/zei/zei.sock`), or falls back to reading the config file directly.

### Key modules

- **`daemon.zig`** — Central orchestrator. Owns service statuses and spawn results. Runs the signal loop (`run`), dispatches reap/restart/shutdown. Handles privilege elevation around restarts and signal forwarding.
- **`config.zig`** — YAML config parser using `zig-yaml`. Loads services into an arena allocator. Includes duration parsing (`5s`, `100ms`, `2m`, `1h`).
- **`monitor.zig`** — Service state machine (`stopped` → `starting` → `running` → `stopping` → `failed`) and the pure `evaluateRestart` function that decides restart/stop/exhausted/schedule based on policy, exit info, and restart count.
- **`signal.zig`** — Blocks managed signals at startup, then `waitForSignal` dequeues them via `sigtimedwait`. Classifies signals into actions: shutdown, forward, reap, ignore.
- **`ipc.zig`** — Unix socket server (non-blocking accept, blocking per-request). JSON request/response protocol. Commands: `list`, `status`, `restart`, `signal`. Also contains the client-side `sendRequest` used by CLI.
- **`cli.zig`** — Subcommand dispatch (`list`, `status`, `restart`, `signal <svc:SIG>`, `help`). Talks to daemon via IPC, falls back to config-only display.
- **`process.zig`** — Thin wrapper around `std.process.Child` for spawning with uid/gid and piped stdout/stderr.
- **`privilege.zig`** — suid-root privilege cycling via `setreuid`/`setregid`. The pattern: drop to app user after startup, elevate before spawning/restarting, drop again after. Uses `@cImport` for libc.
- **`reaper.zig`** — Non-blocking `waitpid` loop that drains all exited children per call, parsing wait status into `ExitInfo`.
- **`user_lookup.zig`** — libc `getpwnam`/`getgrnam` wrappers for resolving usernames to uid/gid.
- **`service_logger.zig`** / **`logger.zig`** — Structured logging with scoped loggers and per-service prefixes.

### Config format

YAML with a `services` map. Each service has: `command` (required), `user`, `group`, `restart` (`always`/`on-failure`/`never`), `max_restarts`, `restart_delay`, `oneshot`, `interval`, `environment`, `depends_on`, `stdout`/`stderr`, `json_logs`. See `example/zei.yaml`.

### Privilege model

The binary runs suid-root in containers. Real UID is parked at root while effective UID is set to the app user. `privilege.elevate()` / `privilege.drop()` swap effective UID for spawning services as different users. The daemon's `elevatePrivileges`/`dropPrivileges` helpers check whether the suid pattern is active (`getuid() != geteuid()`) before cycling — when running as plain root (e.g., in tests), they are no-ops.

### IPC protocol

JSON over Unix socket at `/run/zei/zei.sock`. Request: `{"command":"...", "service":"...", "signal":"..."}`. Response: `{"success":bool, "message":"...", "services":{...}}`. The server is non-blocking for accept but switches connections to blocking for the request/response exchange.

## Dependencies

Single external dependency: [zig-yaml](https://github.com/kubkon/zig-yaml) v0.2.0, pinned by tag in `build.zig.zon`.
