# zei

A small, fast init system for containers. zei runs as PID 1 inside Docker. It manages your services, reaps zombies, and shuts down cleanly.

## Why?

Most containers run one process. When you need more than one, problems show up fast:

- Zombie processes pile up because nothing calls `waitpid`
- SIGTERM to PID 1 never reaches your app
- You can't run services as different users without extra tools
- Graceful shutdown is harder than it should be

zei handles all of this in one static binary. No runtime, no extra files in the container.

## Install

zei is written in Zig 0.15.2. Build from source:

```sh
zig build
```

This puts the binary at `zig-out/bin/zei`. Copy it into your container image.

### Docker

The included `Dockerfile` builds zei for Linux and sets it as the entrypoint:

```sh
docker build -t my-app .
docker run --rm my-app -c /path/to/zei.yaml
```

## Config

zei reads a YAML file. By default it looks at `/etc/zei/zei.yaml`, or you can pass `-c <path>`.

```yaml
version: "1.0"

services:
  web:
    command: ["node", "server.js"]
    user: appuser
    group: appuser
    restart: always
    max_restarts: 5
    restart_delay: 2s

  worker:
    command: ["python", "worker.py"]
    user: worker
    group: worker
    restart: on-failure
    max_restarts: 10
    restart_delay: 5s

  healthcheck:
    command: ["sh", "-c", "curl -sf http://localhost:3000/health"]
    user: monitor
    group: monitor
    oneshot: true
    interval: 30s
    depends_on: ["web"]
```

### Service options

| Option | Default | What it does |
|---|---|---|
| `command` | (required) | The command to run, as a list |
| `user` | `root` | Run the process as this user |
| `group` | `root` | Run the process as this group |
| `restart` | `never` | Restart policy: `always`, `on-failure`, or `never` |
| `max_restarts` | `0` (unlimited) | Stop restarting after this many attempts |
| `restart_delay` | `1s` | Wait this long before restarting (`5s`, `100ms`, `2m`, `1h`) |
| `oneshot` | `false` | Run once and exit (combine with `interval` to repeat) |
| `interval` | — | For oneshot services: wait this long, then run again |
| `depends_on` | — | List of services that should start first |
| `environment` | — | Map of environment variables |
| `working_dir` | — | Working directory for the process |
| `stdout` / `stderr` | — | Redirect output (eg `/dev/stdout`) |
| `json_logs` | `false` | Parse child output as JSON log lines |

## CLI

When zei is running as PID 1, you can talk to it from inside the container:

```sh
zei list                    # show all services and their status
zei status web              # detailed status for one service
zei restart worker          # restart a service
zei signal web:HUP          # send a signal to a service
```

The CLI talks to the daemon over a Unix socket at `/tmp/zei.sock`. If the daemon isn't running, `list` and `status` fall back to reading the config file.

You can use signal names with or without the `SIG` prefix: `HUP`, `TERM`, `KILL`, `USR1`, `USR2`.

## How it works

zei starts as PID 1, blocks signals, loads your config, and spawns each service with the right user and group. Then it drops privileges and sits in a signal loop:

- **SIGCHLD**: reap exited children and decide whether to restart them
- **SIGTERM / SIGINT / SIGQUIT**: start graceful shutdown (SIGTERM to all services, wait 30s, then SIGKILL)
- **SIGHUP / SIGUSR1 / SIGUSR2**: forward to all managed services

### Privilege model

The zei binary uses the suid bit. This lets it start as a non-root user but still spawn services as different users. It goes to root only when it needs to spawn or signal a process, then drops back down. The real UID stays at root while the effective UID runs as your app user.

> [!NOTE]
> The privilege cycling only applies on Linux. On macOS (useful for running tests locally), zei skips the elevation/drop calls.

## Development

You need [Zig 0.15.2](https://ziglang.org/download/).

```sh
zig build                          # build
zig build test --summary all       # run unit tests
```

Unit tests live next to their source in each `.zig` file. Some tests need a local `appuser` account and will skip if it's missing.

### Docker tests

Some tests only work on Linux because they need PID 1, privilege dropping, and zombie reaping. Run them through Docker:

```sh
make docker-test    # unit tests in a Linux container
make docker-e2e     # end-to-end tests (starts containers, exercises the CLI)
```

The e2e suite (`test/e2e.sh`) builds the image, starts zei with different configs, and uses `docker exec` to check that things work.

### Project layout

```
src/            Zig source (all modules, tests inline)
example/        Sample configs and helper scripts for Docker testing
test/           E2E test configs and the test runner script (e2e.sh)
Dockerfile      Multi-stage build: builder, test, and runtime stages
Makefile        Shortcuts for build, test, and Docker commands
```

## License

[MIT](LICENSE)
