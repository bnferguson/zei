# Complete Zig Port of PEI Init System + Zig 0.15.2 Compatibility

## Overview

This PR completes the port of the [pei](https://github.com/bnferguson/pei) init system from Go to Zig, creating a fully functional privilege-escalating init system written in Zig 0.15.2.

**Key Achievement**: ~2,500 lines of working Zig code implementing a complete init system with privilege escalation, process management, and graceful shutdown.

## 📊 Stats

- **43 commits** systematically addressing Zig 0.15.2 API changes
- **30 files changed**, **5,408 insertions**
- **7 core modules** implemented from scratch
- **Docker testing infrastructure** for Linux API validation

## ✨ What's New

### 1. Complete Zig Implementation

Seven core modules implementing full init system functionality:

- **`config.zig`** (365 lines) - YAML configuration parsing with zig-yaml
- **`service.zig`** (82 lines) - Service state management and lifecycle tracking
- **`service_manager.zig`** (368 lines) - Service registry, lookup, and coordination
- **`privilege.zig`** (340 lines) - Setuid-based privilege escalation (setuid/setgid/setgroups)
- **`process.zig`** (393 lines) - Process spawning with user switching and environment setup
- **`monitor.zig`** (270 lines) - Service monitoring with restart policies and backoff
- **`reaper.zig`** (327 lines) - Zombie process reaping (PID 1 responsibility)
- **`main.zig`** (322 lines) - Main event loop with signal handling

### 2. Zig 0.15.2 Compatibility

Comprehensive adaptation to Zig 0.15.2 breaking changes:

#### Standard Library Reorganization
- ✅ `std.os.pid_t` → `std.posix.pid_t`
- ✅ `std.os.exit()` → `posix.exit()`
- ✅ `std.time.sleep()` → `posix.nanosleep(seconds, nanoseconds)`
- ✅ `linux.getErrno()` → `posix.errno()`
- ✅ `std.fmt.allocPrintZ()` → `std.fmt.allocPrintSentinel(..., 0)`

#### ArrayList API Overhaul
- ✅ Now unmanaged by default: `var list: ArrayList(T) = .empty;`
- ✅ All operations require allocator: `.append(allocator, item)`
- ✅ Cleanup requires allocator: `.deinit(allocator)`

#### Signal Handling Updates
- ✅ `posix.empty_sigset` → `posix.sigemptyset()` (function call)
- ✅ `posix.sigaction()` now returns `void` (not error union)
- ✅ Signal constants are `comptime_int`, use directly (no `@intFromEnum`)

#### Pipe API Change
- ✅ `posix.pipe(&fds)` → `const fds = try posix.pipe()` (returns value)

#### Timespec Structure
- ✅ `.tv_sec`/`.tv_nsec` → `.sec`/`.nsec`

#### Build System
- ✅ `build.zig.zon`: String literals → enum literals (`.name = .zei`)
- ✅ `build.zig`: New `root_module` pattern for Zig 0.15

### 3. Docker Testing Infrastructure

Complete Docker setup for testing with real Linux APIs:

```bash
├── Dockerfile                  # Multi-arch build (x86_64/aarch64)
├── docker-compose.yml          # Container orchestration
├── Makefile                    # Convenient build targets
├── test/
│   ├── services-test.yml      # 4 test services (restart policies, failures)
│   ├── simple-test.yml        # Quick smoke test
│   ├── run-docker-test.sh     # Automated test script
│   └── README.md              # Comprehensive testing guide
```

**Usage**:
```bash
make docker-build       # Build image
make docker-test        # Run automated tests
make docker-interactive # Interactive testing
```

### 4. Critical Bug Fixes

#### Signal Handling
- **Fixed**: `rt_sigtimedwait` syscall - was using `syscall3`, needed `syscall4` with sigsetsize
- **Fixed**: Proper error handling for signal timeouts vs errors
- **Result**: ✅ SIGINT/SIGTERM/SIGCHLD all properly received

#### Process Reaping
- **Fixed**: Critical type safety bug - `linux.waitpid` returns `usize`, but checking `pid < 0` never worked
- **Fixed**: Convert to `isize` before comparison to detect -1 (error) properly
- **Result**: ✅ Process reaping works without crashes

### 5. Developer Documentation

Added `.claude/claude.md` with:
- Complete Zig 0.15.2 migration guide
- All 14 common API fixes with examples
- Project architecture notes
- Testing strategies
- Tips for future development

## 🏗️ Architecture

### Service Lifecycle
```
stopped → starting → running → stopping → failed
                        ↓
                   (restart policy)
                        ↓
                    starting
```

### Restart Policies
- **`always`** - Restart on any exit
- **`on-failure`** - Restart only on non-zero exit
- **`never`** - No automatic restart

### Privilege Model
1. Start as root (required for PID 1)
2. Parse configuration as root
3. Fork and execute services as specified user/group
4. Each service runs with dropped privileges

## 🧪 Testing

### Run the Docker Tests

```bash
# Build and test
make docker-build
make docker-test

# Interactive mode
make docker-interactive

# Manual testing
docker run --rm -it \
  -v $(pwd)/test/services-test.yml:/config/services.yml:ro \
  zei:latest --config /config/services.yml
```

### Test Configuration

The test config includes:
- **hello** - Simple service that exits after 5s (tests normal lifecycle)
- **counter** - Counts to 10 then exits (tests `restart: never`)
- **long-running** - Infinite loop (tests `restart: always`)
- **failing-service** - Immediately exits with error (tests `restart: on-failure`)

### Verify Signal Handling

```bash
# Start container
docker run -d --name zei-test \
  -v $(pwd)/test/simple-test.yml:/config/services.yml:ro \
  zei:latest --config /config/services.yml

# Send SIGINT (should see shutdown message)
docker kill --signal=INT zei-test

# Check logs
docker logs zei-test | grep "Received SIGINT"
```

## ✅ What's Working

- ✅ YAML configuration parsing
- ✅ Service registration and lifecycle management
- ✅ Process spawning with privilege dropping
- ✅ User/group switching (setuid/setgid)
- ✅ Environment variable passing
- ✅ Signal handling (SIGINT/SIGTERM/SIGCHLD)
- ✅ Process reaping (prevents zombies)
- ✅ Graceful shutdown
- ✅ Restart policies with backoff
- ✅ Builds on both x86_64 and ARM64

## 🔧 Known Issues

- ⚠️ Memory cleanup during shutdown needs investigation (some allocations not freed)
- ⚠️ More extensive restart policy testing needed
- ⚠️ Unit tests need to be run and potentially updated

## 📝 Configuration Example

```yaml
services:
  - name: web-server
    command:
      - /usr/bin/nginx
      - -g
      - "daemon off;"
    user: www-data
    group: www-data
    restart: always
    environment:
      PORT: "8080"
      ENV: "production"
```

## 🚀 Usage

```bash
# Build locally
zig build

# Run (requires root for PID 1 functionality)
sudo ./zig-out/bin/zei --config config.yml

# Or use Docker for testing
docker run --privileged \
  -v $(pwd)/config.yml:/config/services.yml:ro \
  zei:latest --config /config/services.yml
```

## 📚 Documentation

- **`README.md`** - Project overview and usage
- **`ARCHITECTURE.md`** - Design decisions and architecture
- **`TESTING.md`** - Testing strategy and scenarios
- **`.claude/claude.md`** - Zig 0.15.2 migration guide
- **`test/README.md`** - Docker testing guide

## 🎯 Future Improvements

1. **Logging** - Structured logging with log levels
2. **Advanced Shutdown** - Configurable timeouts, retry logic
3. **Resource Limits** - CPU/memory limits per service
4. **Health Checks** - Service health monitoring
5. **API/CLI** - Runtime service management
6. **Testing** - Comprehensive unit and integration tests

## 🔍 Technical Highlights

### Platform Detection
Uses conditional compilation for Linux-specific features:
```zig
if (builtin.os.tag == .linux) {
    // Use rt_sigtimedwait syscall
} else {
    // Fallback polling for development
}
```

### Type Safety
Careful handling of type conversions:
```zig
// waitpid returns usize, but -1 indicates error
const pid = linux.waitpid(-1, &status, linux.W.NOHANG);
const pid_signed = @as(isize, @bitCast(pid));
if (pid_signed < 0) { /* handle error */ }
```

### Memory Management
Consistent allocator discipline:
```zig
var list: ArrayList(T) = .empty;
defer list.deinit(allocator);
try list.append(allocator, item);
```

## 🙏 Acknowledgments

- Original [pei](https://github.com/bnferguson/pei) implementation in Go
- [zig-yaml](https://github.com/kubkon/zig-yaml) for YAML parsing
- Zig community for excellent documentation

## 📦 Dependencies

- **Zig 0.15.2** (exactly - due to stdlib API changes)
- **zig-yaml** (HEAD version for 0.15.2 compatibility)
- **Docker** (optional, for testing)

---

## Checklist

- [x] All modules implemented (~2,500 lines)
- [x] Builds successfully on Zig 0.15.2
- [x] Docker infrastructure complete
- [x] Signal handling working (SIGINT/SIGTERM/SIGCHLD)
- [x] Process reaping working
- [x] Privilege escalation working
- [x] Configuration parsing working
- [x] Documentation complete
- [ ] All unit tests passing (needs verification)
- [ ] Memory cleanup on shutdown (known issue)

## Breaking Changes

None - this is the initial Zig implementation based on the Go version.

## Migration from Go Version

For users of the original Go `pei`:
- Configuration format is **identical** (YAML)
- Behavior is **compatible**
- Binary name changed: `pei` → `zei` (Zig version)
- Performance characteristics may differ
