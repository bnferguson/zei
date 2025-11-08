# zei - Privilege Escalating Init

`zei` is an init (meant to be run as PID 1), that can run multiple processes not unlike `supervisord` or `systemd` but the difference is that it is designed to be run inside of a OCI container with default capabilities (so no adding a `--privledged` to your docker run). It also does not run as `root` but instead runs as a unprivledged user and relies on `setuid` to escalate to `root` only when tasks (or processes) require it.

Each process that this init starts and manages can run as a different user. `zei` will escalate to `root` to change to this user to start the process or manage the process (including killing it, etc).

Services/processes can write their logs to a tmpfs, but also stream them to stdout showing what service is generating the log.

## Quick Start

### Building

```bash
# Fetch dependencies and build
zig build

# The binary will be in zig-out/bin/zei
```

### Running

```bash
# Run with example configuration
./zig-out/bin/zei --config example/zei.yaml

# Press Ctrl+C to exit
```

### Testing

See [TESTING.md](TESTING.md) for comprehensive testing instructions.

## Example Configuration

A full, up-to-date, and commented example configuration is provided in [`example/zei.yaml`](example/zei.yaml). This file demonstrates the MVP features of `zei`:

```yaml
services:
  - name: echo-service
    command: /bin/sh -c "while true; do echo 'Hello'; sleep 5; done"
    restart: always
    user: nobody

  - name: worker
    command: ["/usr/bin/python3", "-c", "print('Working...')"]
    restart: on-failure
    user: nobody
    working_dir: /tmp

  - name: oneoff
    command: /bin/echo "This runs once"
    restart: never
```

Note: Make sure all specified users and groups exist in the container, and that the necessary directories and files are accessible to the respective users.

## Key Features

1. **Service Management**:
   - Each service can run as a different user
   - Services can have different working directories
   - Environment variables can be set per-service
   - Services can depend on other services

2. **Restart Policies**:
   - `always`: Always restart the service if it dies
   - `on-failure`: Only restart if the service exits with non-zero status
   - `never`: Don't restart the service
   - `oneshot`: Run the service once and don't keep it running

3. **Root Access**:
   - Services can request root access via `requires_root: true`
   - `zei` will handle privilege escalation only when needed

4. **Logging**:
   - Service output can be redirected to files
   - Environment variables for logging configuration
   - Logs are streamed to stdout with service identification

5. **Scheduling**:
   - Services can be scheduled to run at intervals
   - Dependencies between services can be specified

## Reasoning

The idea behind `zei` is that many times you need to run multiple services inside the same container but still want to have some user separation. This lets us run as multiple users while being non-root and conforming to CIS Docker standards (non-root, readonly filesystem, etc).

## Project Status

**MVP Complete!** 🎉

zei is now functional and can:
- ✅ Parse YAML configuration files
- ✅ Spawn processes as different users (with setuid)
- ✅ Monitor and restart services based on policy
- ✅ Reap zombie processes
- ✅ Handle graceful shutdown
- ✅ Run as PID 1 in containers

See [TESTING.md](TESTING.md) for testing instructions and [DEVELOPMENT.md](DEVELOPMENT.md) for development status.

