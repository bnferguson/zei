# Setup Instructions

## Prerequisites

- Zig 0.15.2

Install Zig from: https://ziglang.org/download/

## Initial Setup

### 1. Fetch Dependencies

The project uses `kubkon/zig-yaml` for YAML parsing. To fetch it:

```bash
# Option 1: Let Zig fetch it automatically on first build
zig build

# Option 2: Manually fetch and update build.zig.zon
zig fetch --save=yaml https://github.com/kubkon/zig-yaml/archive/refs/heads/main.zip
```

**Note:** On first build, if the hash in `build.zig.zon` is incorrect, Zig will tell you the correct hash. Update the `.hash` field in `build.zig.zon` with the provided value.

### 2. Build the Project

```bash
# Debug build
zig build

# Release build (optimized for speed)
zig build -Doptimize=ReleaseFast

# Release build (optimized for size - recommended for containers)
zig build -Doptimize=ReleaseSmall
```

The compiled binary will be in `zig-out/bin/zei`.

### 3. Run Tests

```bash
zig build test
```

### 4. Run the Application

```bash
# Using zig build run
zig build run -- --config example/zei.yaml

# Or run the binary directly
./zig-out/bin/zei --config example/zei.yaml
```

## Setting Up for Container Use

For the setuid functionality to work properly:

```bash
# Build release binary
zig build -Doptimize=ReleaseSmall

# Install with correct permissions (requires root)
sudo cp zig-out/bin/zei /usr/local/bin/zei
sudo chown root:root /usr/local/bin/zei
sudo chmod u+s /usr/local/bin/zei
```

## Development Workflow

1. Make changes to the code
2. Run `zig build test` to verify tests pass
3. Run `zig build` to compile
4. Test with `./zig-out/bin/zei --config example/zei.yaml`

## Troubleshooting

### Error: "dependency 'yaml' not found"

Run `zig build` and follow the hash error message to update `build.zig.zon`.

### Error: Hash mismatch

Zig will print the expected hash. Copy it and update the `.hash` field in `build.zig.zon`:

```zig
.hash = "1220abcdef...", // Replace with the hash from the error message
```

### Error: Zig version too old

This project requires Zig 0.13.0 or later. Download the latest version from https://ziglang.org/download/

## Next Steps

See `DEVELOPMENT.md` for the full development guide and `tasks/tasks-mvp-implementation.md` for the implementation roadmap.
