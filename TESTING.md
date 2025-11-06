# zei MVP Testing Guide

This guide walks through testing the zei init system MVP.

## Prerequisites

1. **Zig installed** (0.13.0 or later)
2. **Linux system** (zei uses Linux-specific system calls)
3. **User accounts**: Ensure `nobody` user exists (standard on most systems)

## Building zei

```bash
# Navigate to project directory
cd /path/to/zei

# Fetch dependencies (first build only)
zig build

# If you get a hash mismatch error, update build.zig.zon with the correct hash
# The error message will show the expected hash

# Build should complete successfully
```

Expected output:
```
info: Fetching packages...
info: Dependency yaml...
```

## Test 1: Simple Echo Test

Test that zei can start and stop a basic service.

```bash
# Run with simple config
./zig-out/bin/zei --config tests/simple.yaml
```

**Expected behavior:**
1. zei starts and displays banner
2. Service "hello" starts and prints "Hello from zei!"
3. Service exits (restart: never)
4. zei continues running
5. Press Ctrl+C to exit
6. zei shuts down gracefully

**Expected output:**
```
====================================
zei v0.1.0-mvp - Zig Privilege Escalating Init
====================================
Configuration: tests/simple.yaml
PID: 12345
Status: Running as PID 12345 (development mode)
====================================

[init] Loading configuration from tests/simple.yaml...
[init] Loaded 1 service(s)

[init] Initializing service manager...
[init] Registered service: hello

[init] Setting up signal handlers...
[init] Signal handlers ready

[init] Starting all services...
[hello] Starting service...
[hello] Service started (PID 12346)
[init] All services started

[init] Entering main event loop
[init] Press Ctrl+C to initiate shutdown

Reaped managed process PID 12346
[hello] Service exited successfully (code 0)
[hello] Restart policy: never - will not restart

^C
[init] Received SIGINT, initiating shutdown...

[init] Shutting down...
[init] No services to stop
[init] Shutdown complete
```

✅ **Pass criteria:** Service starts, runs, exits cleanly without restart

---

## Test 2: Example Configuration

Test multiple services with different configurations.

```bash
./zig-out/bin/zei --config example/zei.yaml
```

**Expected behavior:**
1. Three services start: echo-service, worker, oneoff
2. echo-service runs continuously (restart: always)
3. worker runs and exits after ~5 minutes (restart: on-failure)
4. oneoff exits immediately (restart: never)
5. Services run as `nobody` user
6. Ctrl+C triggers graceful shutdown

**What to observe:**
- All three services start successfully
- echo-service keeps running (you'll see periodic zombie reaping)
- oneoff exits and doesn't restart
- worker runs for a while then exits
- Restart count increments for echo-service if it crashes

✅ **Pass criteria:** All services start, restart policies work correctly

---

## Test 3: Restart Policy Testing

Test all restart policies in detail.

```bash
./zig-out/bin/zei --config tests/restart-test.yaml
```

**Expected behavior:**
1. **success-exit**: Exits with code 0, should NOT restart (on-failure policy)
2. **failure-exit**: Exits with code 1, SHOULD restart (on-failure policy)
3. **always-restart**: Exits with code 0, SHOULD restart (always policy)
4. **never-restart**: Exits with code 0, should NOT restart (never policy)

**Watch for:**
```
[failure-exit] Service exited with error (code 1)
[failure-exit] Restart policy: on-failure - will restart
[failure-exit] Restarting service (restart #1)...
[failure-exit] Starting service...
[failure-exit] Service started (PID 12349)
```

✅ **Pass criteria:**
- success-exit: exits once, no restart
- failure-exit: restarts continuously
- always-restart: restarts continuously
- never-restart: exits once, no restart

---

## Test 4: Signal Handling

Test that zei properly handles signals.

```bash
./zig-out/bin/zei --config example/zei.yaml &
ZEI_PID=$!

# Wait for startup
sleep 2

# Send SIGTERM
kill -TERM $ZEI_PID

# Wait for shutdown
wait $ZEI_PID
```

**Expected behavior:**
1. zei starts in background
2. SIGTERM triggers shutdown
3. All services receive SIGTERM
4. zei waits up to 5 seconds
5. Any remaining processes get SIGKILL
6. zei exits cleanly

✅ **Pass criteria:** Clean shutdown with proper signal propagation

---

## Test 5: Zombie Prevention

Test that zei doesn't accumulate zombie processes.

```bash
# Start zei
./zig-out/bin/zei --config tests/restart-test.yaml &
ZEI_PID=$!

# Let it run for 30 seconds (services will exit and restart)
sleep 30

# Check for zombie processes
ps aux | grep defunct

# Should see NO zombie processes

# Clean up
kill -TERM $ZEI_PID
```

✅ **Pass criteria:** No `<defunct>` processes in ps output

---

## Test 6: Multi-User Services (Requires Setup)

Test privilege escalation and multi-user support.

### Setup (one-time):
```bash
# Build and install with setuid
sudo zig build -Doptimize=ReleaseSmall
sudo cp zig-out/bin/zei /usr/local/bin/zei
sudo chown root:root /usr/local/bin/zei
sudo chmod u+s /usr/local/bin/zei

# Verify setup
ls -l /usr/local/bin/zei
# Should show: -rwsr-xr-x 1 root root ...
#              ^ note the 's' bit
```

### Test:
```bash
# Run as non-root user
/usr/local/bin/zei --config example/zei.yaml
```

**Expected behavior:**
- zei runs as your user but can spawn processes as `nobody`
- Services run with correct user/group
- Privilege escalation happens transparently

**Verify service users:**
```bash
# In another terminal while zei is running
ps aux | grep -E "echo-service|worker"
# Should show processes running as 'nobody'
```

✅ **Pass criteria:** Services run as specified users despite zei running as non-root

---

## Test 7: Configuration Errors

Test that zei handles bad configurations gracefully.

### Missing file:
```bash
./zig-out/bin/zei --config /nonexistent/file.yaml
```
Expected: Clear error message, no crash

### Invalid YAML:
Create `tests/bad.yaml`:
```yaml
services:
  - name: test
    # missing command field
    restart: always
```

```bash
./zig-out/bin/zei --config tests/bad.yaml
```
Expected: Configuration parse error, no crash

### Invalid user:
Create `tests/baduser.yaml`:
```yaml
services:
  - name: test
    command: /bin/echo "hello"
    user: nonexistent_user_12345
```

```bash
./zig-out/bin/zei --config tests/baduser.yaml
```
Expected: Service fails to start, error logged, zei continues

✅ **Pass criteria:** All errors handled gracefully with clear messages

---

## Test 8: Help and Version

```bash
./zig-out/bin/zei --help
./zig-out/bin/zei --version
```

Expected:
- `--help`: Shows usage information
- `--version`: Shows `zei version 0.1.0-mvp`

---

## Performance Validation

### Startup Time
```bash
time ./zig-out/bin/zei --config tests/simple.yaml &
ZEI_PID=$!
sleep 1
kill -TERM $ZEI_PID
wait $ZEI_PID
```

✅ **Target:** <100ms startup for simple config

### Memory Usage
```bash
./zig-out/bin/zei --config example/zei.yaml &
ZEI_PID=$!
sleep 2

# Check memory
ps -o pid,rss,cmd -p $ZEI_PID

kill -TERM $ZEI_PID
```

✅ **Target:** <10MB RSS for basic usage

### Binary Size
```bash
ls -lh zig-out/bin/zei
```

✅ **Target:** <2MB (with ReleaseSmall optimization)

---

## Common Issues

### Issue: "yaml dependency not found"
**Solution:** Run `zig build` to fetch dependencies. If hash mismatch, update `build.zig.zon` with the correct hash shown in error.

### Issue: "Permission denied" when spawning as different user
**Solution:** Install zei with setuid bit (see Test 6 setup)

### Issue: Services not restarting
**Solution:** Check restart policy in config. Use `always` for continuous restart.

### Issue: "User not found"
**Solution:** Ensure user exists. Check with `id username`. Use existing users like `nobody`.

---

## Success Criteria Summary

✅ All services start successfully
✅ Restart policies work correctly (always, on-failure, never)
✅ Zombie processes are reaped
✅ Graceful shutdown works
✅ Signal handling works (SIGTERM, SIGINT, SIGCHLD)
✅ Multi-user support works (with setuid)
✅ Configuration errors handled gracefully
✅ Performance targets met

---

## Next Steps After Testing

1. **Document any issues** found during testing
2. **Create Docker test** (see instructions below)
3. **Add logging** (Task 7.0) for better observability
4. **Performance tuning** if targets not met
5. **Production hardening** based on findings

---

## Docker Testing (Bonus)

Create `Dockerfile.test`:
```dockerfile
FROM alpine:latest

# Install dependencies
RUN apk add --no-cache zig

# Copy source
WORKDIR /app
COPY . .

# Build
RUN zig build -Doptimize=ReleaseSmall

# Set up permissions
RUN chown root:root /app/zig-out/bin/zei && \
    chmod u+s /app/zig-out/bin/zei

# Create test user
RUN adduser -D -u 1000 testuser

# Run as non-root
USER testuser

# Run zei as PID 1
ENTRYPOINT ["/app/zig-out/bin/zei"]
CMD ["--config", "/app/example/zei.yaml"]
```

Build and run:
```bash
docker build -f Dockerfile.test -t zei-test .
docker run --rm zei-test
```

This tests zei as PID 1 in a real container environment!
