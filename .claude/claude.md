# Claude Development Notes

This document contains learnings and patterns for future Claude sessions working on this project.

## Zig 0.15.2 API Compatibility Guide

This project targets Zig 0.15.2. Many tutorials and examples online target older versions (0.11-0.13). Here are the key breaking changes and how to handle them:

### Build System Changes

**build.zig.zon**
```zig
// ❌ OLD (0.13)
.{
    .name = "zei",  // String literal
    .version = "0.1.0",
}

// ✅ NEW (0.15.2)
.{
    .name = .zei,  // Enum literal (no quotes!)
    .version = "0.1.0",
    .fingerprint = 0x...,  // Required field
}
```

**build.zig**
```zig
// ❌ OLD (0.13)
const exe = b.addExecutable(.{
    .name = "zei",
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});

// ✅ NEW (0.15.2)
const exe = b.addExecutable(.{
    .name = "zei",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
```

### Standard Library Reorganization

#### std.os → std.posix Migration

Many OS functions moved from `std.os` to `std.posix`:

```zig
const posix = std.posix;

// ✅ Types
std.posix.pid_t          // was: std.os.pid_t
std.posix.fd_t

// ✅ Functions
posix.fork()
posix.pipe()             // Returns [2]fd_t, not output parameter!
posix.close()
posix.dup2()
posix.execve()
posix.exit()             // was: std.os.exit()
posix.waitpid()
posix.nanosleep()        // was: std.time.sleep()

// ❌ Still in std.os.linux (Linux-specific)
const linux = std.os.linux;
linux.kill()
linux.waitpid()          // Returns usize, cast to pid_t
linux.setuid()
linux.setgid()
linux.timespec
```

#### pipe() API Change

```zig
// ❌ OLD (0.13)
var fds: [2]posix.fd_t = undefined;
try posix.pipe(&fds);

// ✅ NEW (0.15.2)
const fds = try posix.pipe();  // Returns value directly
```

#### exit() Function

```zig
// ❌ OLD
os.exit(1);

// ✅ NEW
posix.exit(1);
```

### ArrayList Changes (Unmanaged by Default)

ArrayList is now unmanaged by default. You must pass the allocator to all operations:

```zig
const std = @import("std");

// ❌ OLD (0.13)
var list = std.ArrayList(T).init(allocator);
try list.append(item);
const slice = try list.toOwnedSlice();
list.deinit();

// ✅ NEW (0.15.2)
var list: std.ArrayList(T) = .empty;  // or = std.ArrayList(T){};
try list.append(allocator, item);      // Pass allocator!
const slice = try list.toOwnedSlice(allocator);
list.deinit(allocator);

// For const lists that need deinit, they must be var or mutable pointer
var result = functionThatReturnsArrayList();
defer result.deinit(allocator);  // Needs mutable reference
```

### Signal Handling Changes

#### Signal Sets

```zig
const posix = std.posix;

// ❌ OLD (0.13)
var mask = posix.empty_sigset;  // Constant

// ✅ NEW (0.15.2)
var mask = posix.sigemptyset();  // Function call
```

#### Signal Functions

```zig
// ❌ OLD (0.13)
try posix.sigaddset(&mask, @intFromEnum(posix.SIG.TERM));
try posix.sigprocmask(...);
try posix.sigaction(...);

// ✅ NEW (0.15.2)
posix.sigaddset(&mask, posix.SIG.TERM);  // SIG is comptime_int, no cast needed
posix.sigprocmask(...);                   // Returns void, no try
posix.sigaction(...);                     // Returns void, no try
```

#### Signal Constants

```zig
// ❌ OLD - Signal enums needed casting
const sig_num = @intFromEnum(posix.SIG.TERM);

// ✅ NEW - Signals are comptime_int, use directly
linux.kill(pid, posix.SIG.TERM);  // No @intFromEnum needed
if (sig == posix.SIG.TERM) { ... }
```

#### sigtimedwait Missing (Platform-Specific Solution)

```zig
// sigtimedwait is not available as a high-level function in 0.15.2
// Solution: Use platform-specific syscall on Linux, polling on other platforms

const builtin = @import("builtin");
const linux = std.os.linux;
const posix = std.posix;

if (builtin.os.tag == .linux) {
    // Use direct syscall on Linux
    var timeout = linux.timespec{
        .sec = 1,      // Note: fields changed from tv_sec to sec
        .nsec = 0,
    };
    const sig = linux.syscall3(
        .rt_sigtimedwait,
        @intFromPtr(&mask),
        @intFromPtr(@as(?*anyopaque, null)),
        @intFromPtr(&timeout)
    );
} else {
    // Fallback for testing on macOS
    posix.nanosleep(1, 0);
}
```

### Time-Related Changes

#### timespec Structure

```zig
const linux = std.os.linux;

// ❌ OLD (0.13)
var ts = linux.timespec{
    .tv_sec = 1,
    .tv_nsec = 0,
};

// ✅ NEW (0.15.2)
var ts = linux.timespec{
    .sec = 1,    // Removed 'tv_' prefix
    .nsec = 0,
};
```

#### Sleep Function

```zig
// ❌ OLD (0.13)
std.time.sleep(100 * std.time.ns_per_ms);

// ✅ NEW (0.15.2)
posix.nanosleep(0, 100_000_000);  // (seconds, nanoseconds)
// For 100ms: 0 seconds, 100 million nanoseconds
```

### String Formatting Changes

```zig
const allocator = std.heap.page_allocator;

// ❌ OLD (0.13)
const str = try std.fmt.allocPrintZ(allocator, "{s}={s}", .{k, v});

// ✅ NEW (0.15.2)
const str = try std.fmt.allocPrintSentinel(
    allocator,
    "{s}={s}",
    .{k, v},
    0  // Sentinel value at the end
);
```

### Error Handling Changes

```zig
// ❌ OLD (0.13)
const linux = std.os.linux;
const err = linux.getErrno(result);

// ✅ NEW (0.15.2)
const posix = std.posix;
const err = posix.errno(result);
```

### Catch Block with Fallback Value

```zig
// ❌ OLD - This doesn't compile in 0.15.2
const value = someFunction() catch |err| {
    handleError(err);
    false;  // ERROR: value ignored
};

// ✅ NEW - Use labeled break
const value = someFunction() catch |err| blk: {
    handleError(err);
    break :blk false;
};
```

### Type Casting Patterns

#### waitpid Return Type

```zig
// linux.waitpid returns usize, but PIDs are i32
const pid = linux.waitpid(-1, &status, linux.W.NOHANG);

if (pid < 0) {
    // Handle error
} else if (pid > 0) {
    // Cast to pid_t for use with other functions
    const pid_i32: std.posix.pid_t = @intCast(pid);
    const was_managed = manager.hasPid(pid_i32);
}
```

### Common Import Pattern

```zig
const std = @import("std");
const builtin = @import("builtin");  // For platform detection
const posix = std.posix;
const linux = std.os.linux;
```

### Dependencies and External Libraries

When using external libraries (like zig-yaml), they must also be compatible with Zig 0.15.2:

```bash
# Check library compatibility
# Many libraries tag releases for specific Zig versions
# If no 0.15.2 tag exists, try HEAD or latest commit

# In build.zig.zon:
.dependencies = .{
    .yaml = .{
        .url = "https://github.com/kubkon/zig-yaml/archive/<commit>.tar.gz",
        .hash = "...",  # Run zig build, it will tell you the correct hash
    },
}
```

### Testing Considerations

When writing tests for 0.15.2:

```zig
test "example" {
    const allocator = std.testing.allocator;

    // ArrayList needs allocator
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(allocator);

    try list.append(allocator, 42);

    // Expectations remain the same
    try std.testing.expectEqual(@as(i32, 42), list.items[0]);
}
```

### Quick Reference: Most Common Fixes

1. `std.os.pid_t` → `std.posix.pid_t`
2. `std.os.exit()` → `std.posix.exit()`
3. `std.time.sleep()` → `posix.nanosleep(seconds, nanoseconds)`
4. `ArrayList.init(allocator)` → `var list: ArrayList(T) = .empty;`
5. `list.append(item)` → `list.append(allocator, item)`
6. `list.deinit()` → `list.deinit(allocator)`
7. `posix.empty_sigset` → `posix.sigemptyset()`
8. `try posix.sigaction()` → `posix.sigaction()` (no try)
9. `@intFromEnum(posix.SIG.TERM)` → `posix.SIG.TERM` (direct use)
10. `linux.getErrno()` → `posix.errno()`
11. `std.fmt.allocPrintZ()` → `std.fmt.allocPrintSentinel(..., 0)`
12. `try posix.pipe(&fds)` → `const fds = try posix.pipe()`
13. `.tv_sec`/`.tv_nsec` → `.sec`/`.nsec`
14. Catch with value: use `catch |err| blk: { break :blk value; }`

## Project-Specific Notes

### Architecture

This is a Linux init system (PID 1) with:
- YAML-based service configuration
- Setuid-based privilege escalation
- Automatic service restart with backoff
- Zombie process reaping
- Graceful shutdown handling

### Platform Support

- **Primary target**: Linux (required for PID 1 functionality)
- **Development/testing**: macOS (with platform-specific workarounds for signal handling)

### Key Design Patterns

1. **Service lifecycle**: stopped → starting → running → stopping → failed
2. **Restart policies**: always, on-failure, never
3. **Privilege model**: Start as root, services run as specified user/group
4. **Process reaping**: Continuous waitpid loop with WNOHANG

### Testing Strategy

- Unit tests for each module
- Integration tests in TESTING.md
- Docker-based system testing (see test/ directory)

## Tips for Future Claude Sessions

1. **Always check Zig version first**: `zig version` before starting work
2. **Build incrementally**: Fix errors one at a time, the compiler is helpful
3. **Platform-specific code**: Use `builtin.os.tag` for conditional compilation
4. **External dependencies**: May need HEAD version for 0.15.2 compatibility
5. **Allocator discipline**: Every `init`/`alloc`/`append` should have corresponding `deinit`/`free`
6. **Error handling**: Zig is strict about unused error values and ignored values
7. **Documentation**: Official std docs at https://ziglang.org/documentation/0.15.2/std/

## Build Commands

```bash
# Clean build
zig build

# Run tests
zig build test

# Run with specific target
zig build -Dtarget=x86_64-linux

# Install
zig build install
```

## Debugging Tips

1. **Compilation errors**: Read carefully, Zig errors are very descriptive
2. **Segfaults**: Usually allocator issues or null pointer dereference
3. **Type mismatches**: Check if types changed between versions (e.g., usize vs i32)
4. **Signal handling**: Remember Linux-specific syscalls may not work on macOS
