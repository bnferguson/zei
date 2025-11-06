# Product Requirements Document: zei - Zig Init System

## Introduction/Overview

**zei** (Zig Privilege Escalating Init) is a lightweight init system designed to run as PID 1 in OCI containers. It is a Zig port of the Go-based **pei** project, designed to manage multiple processes with different user privileges in a non-root container environment.

### Problem Statement
Container environments often require running multiple services with user separation while adhering to CIS Docker security standards (non-root execution, read-only filesystems). Traditional init systems either require root privileges or don't support multi-user service management efficiently.

### Solution
**zei** provides a minimal, high-performance init system that:
- Runs as a non-privileged user by default
- Uses setuid-based privilege escalation only when needed
- Manages multiple services with different user contexts
- Prevents zombie processes through proper reaping
- Provides structured logging with service identification

### Why Zig?
This port leverages Zig's unique advantages:
- **Performance**: Compiled binary with minimal overhead, faster than Go runtime
- **Safety**: Compile-time memory safety without garbage collection pauses
- **Small footprint**: Smaller binary size ideal for container images
- **Low-level control**: Direct system call access for privilege management

## Goals

### MVP Goals (1-2 Week Timeline)
1. **Service Lifecycle**: Start, monitor, and restart services based on simple policies
2. **Privilege Management**: Escalate to root only when needed to start services as different users
3. **Process Reaping**: Prevent zombie processes by properly reaping child processes
4. **Basic Logging**: Capture and display service output with service identification
5. **Configuration**: Parse YAML configuration files defining services

### Post-MVP Goals (Future Iterations)
6. Service dependencies and ordering
7. Advanced restart policies with delays and limits
8. Structured JSON logging
9. Signal forwarding to services
10. One-shot and scheduled services
11. Health checks and monitoring
12. IPC/control interface

## User Stories

### As a DevOps Engineer
- I want to run multiple services in a single container so that I can simplify my deployment architecture
- I want each service to run as a different user so that I can maintain security boundaries
- I want the container to run as non-root so that I can comply with CIS Docker benchmarks
- I want automatic restart of failed services so that my container remains operational

### As a Security-Conscious Developer
- I want privilege escalation only when absolutely necessary so that I minimize attack surface
- I want to avoid running as root so that container escapes are less damaging
- I want proper process isolation so that one service can't interfere with another

### As a System Administrator
- I want clear service logs with identification so that I can debug issues quickly
- I want the init system to be lightweight so that it doesn't consume container resources
- I want zombie process prevention so that I don't experience PID exhaustion

## Functional Requirements (MVP)

### 1. Configuration Management
**1.1** The system MUST read configuration from a YAML file specified via `-c` or `--config` flag
**1.2** The system MUST support the following service configuration fields:
- `name`: Service identifier (string, required)
- `command`: Command to execute (string or array, required)
- `user`: Username to run as (string, optional, defaults to current user)
- `group`: Group name to run as (string, optional, defaults to user's primary group)
- `working_dir`: Working directory for the service (string, optional)
- `env`: Environment variables (map of string to string, optional)
- `restart`: Restart policy - `always`, `on-failure`, `never` (string, optional, defaults to `always`)

**1.3** The system MUST validate configuration on startup and exit with clear error messages if invalid

### 2. Service Lifecycle Management
**2.1** The system MUST start all configured services on initialization
**2.2** The system MUST monitor running services and detect when they exit
**2.3** The system MUST restart services according to their restart policy:
- `always`: Restart regardless of exit code
- `on-failure`: Restart only if exit code is non-zero
- `never`: Do not restart

**2.4** The system MUST maintain service state including: running status, PID, start time, restart count

### 3. Privilege Management
**3.1** The system MUST run as a non-root user by default
**3.2** The system binary MUST have the setuid bit set to allow privilege escalation
**3.3** The system MUST escalate to root only when necessary to:
- Change user/group ID before starting a service
- Send signals to processes owned by other users

**3.4** The system MUST drop privileges immediately after completing privileged operations
**3.5** The system MUST verify target users and groups exist before attempting to start services

### 4. Process Reaping
**4.1** The system MUST register as a subreaper or run as PID 1 to receive all orphaned processes
**4.2** The system MUST reap zombie processes by calling waitpid() on SIGCHLD signals
**4.3** The system MUST handle reaping of both managed services and orphaned processes

### 5. Logging
**5.1** The system MUST capture stdout and stderr from each service
**5.2** The system MUST prefix each log line with the service name (e.g., `[service-name] log message`)
**5.3** The system MUST write all service logs to its own stdout/stderr
**5.4** The system MUST log service lifecycle events (started, stopped, restarted) to stdout

### 6. Shutdown Handling
**6.1** The system MUST handle SIGTERM and SIGINT signals for graceful shutdown
**6.2** The system MUST send SIGTERM to all running services on shutdown
**6.3** The system MUST wait for services to exit (with timeout) before terminating
**6.4** The system MUST send SIGKILL to services that don't exit within the timeout period

### 7. Error Handling
**7.1** The system MUST continue operating if individual services fail to start
**7.2** The system MUST log detailed error messages for all failure scenarios
**7.3** The system MUST not crash if a service exits unexpectedly
**7.4** The system MUST handle missing executables gracefully

## Non-Goals (Out of Scope for MVP)

### Explicitly NOT Included in MVP
1. **Service Dependencies**: Services start in configuration order, but no dependency checking
2. **Restart Limits**: No `max_restarts` or `restart_delay` - services restart indefinitely
3. **One-shot Services**: No `oneshot: true` support - all services are long-running
4. **Scheduled Services**: No interval-based or cron-like scheduling
5. **JSON Logging**: Only plain text logging in MVP
6. **Signal Forwarding**: No SIGHUP or custom signal forwarding to services
7. **Health Checks**: No active health checking or HTTP endpoints
8. **IPC/Control Interface**: No runtime control or status queries
9. **Service Output to Files**: No file-based logging, only stdout/stderr
10. **Multiple Configuration Formats**: Only YAML, no JSON or Zig-native config
11. **Hot Reload**: No configuration reload without restart

### Future Considerations
These features are candidates for post-MVP iterations based on user feedback and priorities.

## Design Considerations

### Configuration Example
```yaml
services:
  - name: web
    command: /usr/bin/nginx -g "daemon off;"
    user: www-data
    group: www-data
    working_dir: /var/www
    restart: always
    env:
      PORT: "8080"
      LOG_LEVEL: "info"

  - name: worker
    command: ["/usr/bin/python3", "/app/worker.py"]
    user: worker
    restart: on-failure

  - name: monitor
    command: /usr/bin/monitor
    restart: never
```

### Binary Installation
The zei binary should be:
1. Statically linked (no dynamic dependencies)
2. Have setuid bit set (`chmod u+s /usr/local/bin/zei`)
3. Owned by root (`chown root:root /usr/local/bin/zei`)

### Container Integration
```dockerfile
FROM alpine:latest
COPY zei /usr/local/bin/zei
RUN chmod u+s /usr/local/bin/zei && \
    chown root:root /usr/local/bin/zei
USER 1000:1000
ENTRYPOINT ["/usr/local/bin/zei", "-c", "/etc/zei.yaml"]
```

## Technical Considerations

### Zig-Specific Optimizations

**1. Compile-Time Configuration**
- Use `comptime` for feature flags (e.g., enable/disable logging verbosity)
- Validate configuration structure at compile time where possible
- Optimize away unused code paths

**2. Memory Management**
- Use arena allocators for service state (batch free on shutdown)
- Minimize allocations in hot paths (signal handlers, process monitoring)
- Zero-allocation logging where possible using fixed buffers

**3. Error Handling**
- Leverage Zig's explicit error types for all failure modes
- Use error unions (`!T`) for fallible operations
- Provide detailed error context without try-catch overhead

**4. System Interface**
- Direct system calls via `std.os` (no libc overhead where possible)
- Use Zig's cross-platform abstractions for Linux-specific features
- Efficient signal handling with signalfd or similar

**5. Concurrency Model**
- Event loop using epoll/kqueue for process monitoring
- Async I/O for log capture (non-blocking pipes)
- Consider Zig's async/await for future enhancements

### Build System
- Use `build.zig` for compilation
- Support static linking by default
- Provide release builds optimized for size and speed
- Include capability to strip debugging symbols

### Dependencies
- **Minimal external dependencies**: Prefer Zig standard library
- **YAML parsing**: Use or create a lightweight YAML parser for Zig
- **No runtime dependencies**: Static binary only

### Platform Support
- **Primary target**: Linux x86_64
- **Secondary targets**: Linux ARM64 (for ARM containers)
- **Not supported initially**: macOS, Windows, BSD (future consideration)

### Privilege Escalation Implementation
```zig
// Pseudocode for privilege escalation
fn startServiceAsUser(service: Service) !void {
    const saved_uid = std.os.linux.getuid();
    const saved_gid = std.os.linux.getgid();

    // Escalate to root (via setuid binary)
    try std.os.linux.setuid(0);

    // Change to target user/group
    try std.os.linux.setgid(service.gid);
    try std.os.linux.setuid(service.uid);

    // Execute service command
    try std.os.execve(service.command, service.args, service.env);

    // Note: execve never returns on success
    // On error, attempt to restore original privileges
    std.os.linux.setuid(saved_uid) catch {};
    std.os.linux.setgid(saved_gid) catch {};
}
```

## Success Metrics

### Performance Metrics
1. **Startup Time**: zei must start all services in <100ms for 10 services
2. **Memory Footprint**: <10MB RSS for managing 10 services
3. **Binary Size**: <2MB statically linked binary
4. **CPU Usage**: <1% CPU when services are running normally
5. **Service Restart Latency**: Restart failed service within <500ms of detection

### Safety Metrics
1. **Zero Crashes**: No segfaults or panics during normal operation
2. **Memory Safety**: No memory leaks over 24-hour continuous operation
3. **Privilege Leaks**: No unintended privilege retention (audit with strace)
4. **Zombie Prevention**: Zero zombie processes after 1000 service restarts
5. **Resource Cleanup**: All file descriptors and handles properly closed

### Comparative Benchmarks (vs pei)
- **Startup**: 2-3x faster than pei
- **Memory**: 50-70% smaller footprint than pei
- **Binary size**: 60-80% smaller than pei binary

### Testing Requirements
1. Unit tests for all core modules (>80% coverage)
2. Integration tests for multi-service scenarios
3. Stress tests with rapid service failures
4. Privilege escalation security tests
5. Signal handling tests (SIGTERM, SIGCHLD, etc.)

## Open Questions

1. **YAML Parser**: Should we use an existing Zig YAML library or write a minimal parser for our specific use case?
   - Existing libraries: May have more features than needed
   - Custom parser: More control but more implementation time

2. **Async vs Sync**: Should the MVP use async/await or traditional event loops?
   - Async: More modern, potentially cleaner code
   - Sync with epoll: More proven, less complexity for MVP

3. **Logging Buffer Size**: What's the optimal buffer size for capturing service output?
   - Larger: Less likelihood of blocking services
   - Smaller: Less memory usage

4. **Setuid Binary Security**: What additional hardening should we implement?
   - Restrict execution to specific groups?
   - Additional capability filtering?

5. **Configuration Validation**: How strict should YAML validation be?
   - Strict: Reject unknown fields (safer)
   - Lenient: Ignore unknown fields (more compatible with future versions)

## Appendix: Comparison with pei

| Feature | pei (Go) | zei MVP (Zig) | zei Future |
|---------|----------|---------------|------------|
| Service management | ✓ | ✓ | ✓ |
| Privilege escalation | ✓ | ✓ | ✓ |
| Basic restart policies | ✓ | ✓ | ✓ |
| Restart limits/delays | ✓ | ✗ | ✓ |
| Service dependencies | ✓ | ✗ | ✓ |
| One-shot services | ✓ | ✗ | ✓ |
| JSON logging | ✓ | ✗ | ✓ |
| Signal forwarding | ✓ | ✗ | ✓ |
| Performance | Good | Excellent | Excellent |
| Memory usage | ~20MB | <10MB | <10MB |
| Binary size | ~8MB | <2MB | <2MB |

---

**Document Version**: 1.0
**Last Updated**: 2025-11-06
**Status**: Draft - Ready for Implementation Planning
