# Development Guide

## Project Structure

```
zei/
├── src/
│   └── main.zig          # Entry point with CLI argument parsing
├── example/
│   └── zei.yaml          # Example configuration file
├── tasks/
│   └── prd-zei-init-system.md  # Product Requirements Document
├── build.zig             # Build configuration
├── README.md             # User-facing documentation
└── DEVELOPMENT.md        # This file
```

## Building

### Prerequisites

- Zig 0.11.0 or later (preferably 0.13.0+)

### Build Commands

```bash
# Build the executable (debug mode)
zig build

# Build with optimizations (release-fast)
zig build -Doptimize=ReleaseFast

# Build with optimizations for size (release-small)
zig build -Doptimize=ReleaseSmall

# Run the executable
zig build run -- --config example/zei.yaml

# Run tests
zig build test
```

### Build Output

The compiled binary will be in `zig-out/bin/zei`

## Development Workflow

### 1. Build and Test Locally

```bash
# Build
zig build

# Run with example config
./zig-out/bin/zei --config example/zei.yaml
```

### 2. Installing for Container Use

For the setuid functionality to work, the binary needs special permissions:

```bash
# Build release binary
zig build -Doptimize=ReleaseSmall

# Install and set permissions (requires root)
sudo cp zig-out/bin/zei /usr/local/bin/zei
sudo chown root:root /usr/local/bin/zei
sudo chmod u+s /usr/local/bin/zei
```

### 3. Testing in Docker

```dockerfile
FROM alpine:latest

# Copy binary
COPY zig-out/bin/zei /usr/local/bin/zei
COPY example/zei.yaml /etc/zei.yaml

# Set up users for testing
RUN adduser -D -u 1000 appuser && \
    adduser -D -u 1001 worker

# Set permissions for setuid
RUN chown root:root /usr/local/bin/zei && \
    chmod u+s /usr/local/bin/zei

# Run as non-root user
USER 1000:1000

# Start zei
ENTRYPOINT ["/usr/local/bin/zei", "-c", "/etc/zei.yaml"]
```

## Current Implementation Status

### ✅ Completed (MVP Phase 0)
- [x] Project structure
- [x] Build system (build.zig)
- [x] CLI argument parsing
- [x] Help and version commands
- [x] Signal handling framework

### 🚧 In Progress
- [ ] YAML configuration parsing
- [ ] Service management
- [ ] Privilege escalation
- [ ] Process reaping
- [ ] Logging infrastructure

### 📋 Planned (MVP)
See `tasks/prd-zei-init-system.md` for the complete MVP roadmap.

## Code Style

- Follow Zig standard library conventions
- Use explicit error types
- Prefer `defer` for cleanup
- Keep functions small and focused
- Add tests for all core functionality

## Testing

```bash
# Run all tests
zig build test

# Run specific test
zig test src/main.zig
```

## Performance Goals

- Binary size: <2MB (static)
- Memory usage: <10MB RSS for 10 services
- Startup time: <100ms for 10 services
- Service restart latency: <500ms

## References

- [Original pei (Go implementation)](https://github.com/bnferguson/pei)
- [Zig Language Reference](https://ziglang.org/documentation/master/)
- [PRD Document](tasks/prd-zei-init-system.md)
