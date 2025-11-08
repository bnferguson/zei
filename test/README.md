# Docker Testing for Zei Init System

This directory contains Docker-based tests for the zei init system, allowing you to test with real Linux APIs.

## Prerequisites

- Docker installed and running
- Docker Compose (optional, for docker-compose method)

## Quick Start

### Method 1: Using the test script (Recommended)

```bash
cd test
./run-docker-test.sh
```

This will:
1. Build the Docker image
2. Run automated tests
3. Optionally start interactive mode for manual testing

### Method 2: Using docker-compose

```bash
# From project root
docker-compose up
```

Stop with `Ctrl+C` or:
```bash
docker-compose down
```

### Method 3: Manual Docker commands

Build the image:
```bash
docker build -t zei:latest .
```

Run with test config:
```bash
docker run --rm -it \
    -v $(pwd)/test/services-test.yml:/config/services.yml:ro \
    zei:latest --config /config/services.yml
```

## Test Scenarios

### Test Configuration (services-test.yml)

The test configuration includes:

1. **hello** - Simple service that exits after 5 seconds
   - User: nobody
   - Restart: on-failure
   - Tests basic service startup

2. **counter** - Counts to 10 then exits
   - User: nobody
   - Restart: never
   - Tests service lifecycle and normal exit

3. **long-running** - Infinite loop service
   - User: nobody
   - Restart: always
   - Tests long-running services and restart policy

4. **failing-service** - Immediately fails
   - User: nobody
   - Restart: on-failure
   - Tests restart policy on failure

### What to Test

1. **Service Startup**
   - All services start successfully
   - Correct user switching (root → nobody)
   - Environment variables are passed

2. **Process Reaping**
   - Services that exit are properly reaped
   - No zombie processes accumulate
   - Restart policies are respected

3. **Signal Handling**
   - SIGTERM triggers graceful shutdown
   - All services receive SIGTERM
   - Timeout followed by SIGKILL works

4. **Restart Policies**
   - `always` - Service restarts on any exit
   - `on-failure` - Service restarts only on non-zero exit
   - `never` - Service does not restart

5. **Backoff Logic**
   - Rapid restarts trigger backoff
   - Restart count increases
   - Backoff delay grows exponentially

## Debugging Tips

### View logs from a running container

```bash
docker logs -f zei-test
```

### Attach to a running container

```bash
docker exec -it zei-test /bin/bash
```

### Check running processes

```bash
docker exec zei-test ps aux
```

### Send signals manually

```bash
# SIGTERM
docker kill --signal=TERM zei-test

# SIGINT
docker kill --signal=INT zei-test
```

### Check for zombie processes

```bash
docker exec zei-test ps aux | grep defunct
```

## Creating Custom Test Configs

Create a new YAML file in this directory:

```yaml
services:
  - name: my-test-service
    command: /path/to/command
    user: nobody
    restart: on-failure
    environment:
      MY_VAR: "value"
```

Run with your config:

```bash
docker run --rm -it \
    -v $(pwd)/test/my-config.yml:/config/services.yml:ro \
    zei:latest --config /config/services.yml
```

## Known Limitations

- The container must run as `privileged` to allow proper user switching
- On some systems, you may need to adjust Docker daemon settings for init process testing
- Signal handling may differ slightly in containerized environment vs bare metal

## Troubleshooting

### "Permission denied" when running services

The container needs privileged mode for setuid/setgid:
```bash
docker run --privileged ...
```

### Services don't start

Check logs:
```bash
docker logs zei-test
```

Verify the config file is mounted:
```bash
docker exec zei-test cat /config/services.yml
```

### Container exits immediately

Check if the config file path is correct:
```bash
docker run --rm zei:latest --help
```

## CI/CD Integration

Example GitHub Actions workflow:

```yaml
name: Docker Test
on: [push, pull_request]

jobs:
  docker-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Build and test
        run: |
          docker build -t zei:test .
          docker run --rm \
            -v $PWD/test/services-test.yml:/config/services.yml:ro \
            zei:test --config /config/services.yml &
          sleep 10
          docker stop $(docker ps -q --filter ancestor=zei:test)
```
