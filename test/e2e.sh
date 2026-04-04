#!/bin/sh
#
# End-to-end test suite for zei.
# Run via: make docker-e2e
#
# This script runs on the HOST, launching Docker containers with zei as PID 1,
# then uses `docker exec` to exercise the CLI and verify behavior.

set -e

IMAGE="zei:latest"
CONTAINER="zei-e2e"
PASS=0
FAIL=0

cleanup() {
    echo ""
    echo "--- Cleanup ---"
    docker rm -f "$CONTAINER" 2>/dev/null || true
}
trap cleanup EXIT

pass() {
    PASS=$((PASS + 1))
    echo "  PASS: $1"
}

fail() {
    FAIL=$((FAIL + 1))
    echo "  FAIL: $1"
}

check_output() {
    desc="$1"
    pattern="$2"
    shift 2
    output=$("$@" 2>&1) || true
    if echo "$output" | grep -q "$pattern"; then
        pass "$desc"
    else
        fail "$desc (expected '$pattern' in output)"
        echo "    got: $(echo "$output" | head -5)"
    fi
}

# ---------- Build ----------
echo "=== Building Docker image ==="
docker build -t "$IMAGE" . || { echo "Docker build failed"; exit 1; }

# ---------- Test 1: Simple service ----------
echo ""
echo "=== Test: Simple service config ==="
docker run -d --name "$CONTAINER" "$IMAGE" -c /test/simple.toml
sleep 3

check_output "list shows echo service" "echo" \
    docker exec "$CONTAINER" /zei -c /test/simple.toml list

check_output "status shows running" "running" \
    docker exec "$CONTAINER" /zei -c /test/simple.toml status echo

docker rm -f "$CONTAINER" >/dev/null 2>&1

# ---------- Test 2: Multi-service ----------
echo ""
echo "=== Test: Multi-service config ==="
docker run -d --name "$CONTAINER" "$IMAGE" -c /test/multi.toml
sleep 4

check_output "list shows echo service" "echo" \
    docker exec "$CONTAINER" /zei -c /test/multi.toml list

check_output "list shows worker service" "worker" \
    docker exec "$CONTAINER" /zei -c /test/multi.toml list

check_output "list shows monitor service" "monitor" \
    docker exec "$CONTAINER" /zei -c /test/multi.toml list

docker rm -f "$CONTAINER" >/dev/null 2>&1

# ---------- Test 3: Privilege drop ----------
echo ""
echo "=== Test: Privilege drop ==="
docker run -d --name "$CONTAINER" "$IMAGE" -c /test/simple.toml
sleep 3

# After drop(), real UID = 0 (parked for elevate), effective UID = appuser (1000).
# /proc/1/status Uid line: real effective saved filesystem
# We check the effective UID (second field).
PROC_EUID=$(docker exec "$CONTAINER" sh -c 'cat /proc/1/status 2>/dev/null | grep "^Uid:" | awk "{print \$3}"' 2>&1) || true
if [ "$PROC_EUID" = "1000" ]; then
    pass "PID 1 effective uid=1000 (appuser)"
else
    fail "PID 1 effective uid=1000 (got '$PROC_EUID')"
fi

docker rm -f "$CONTAINER" >/dev/null 2>&1

# ---------- Test 4: Restart behavior ----------
echo ""
echo "=== Test: Restart behavior ==="
docker run -d --name "$CONTAINER" "$IMAGE" -c /test/restart.toml
sleep 8

check_output "crasher restarts on failure" "crasher" \
    docker exec "$CONTAINER" /zei -c /test/restart.toml list

docker rm -f "$CONTAINER" >/dev/null 2>&1

# ---------- Test 5: IPC restart command ----------
echo ""
echo "=== Test: IPC restart command ==="
docker run -d --name "$CONTAINER" "$IMAGE" -c /test/simple.toml
sleep 3

check_output "restart command succeeds" "restart" \
    docker exec "$CONTAINER" /zei -c /test/simple.toml restart echo

sleep 3

check_output "service still running after restart" "running" \
    docker exec "$CONTAINER" /zei -c /test/simple.toml status echo

docker rm -f "$CONTAINER" >/dev/null 2>&1

# ---------- Test 6: Graceful shutdown ----------
echo ""
echo "=== Test: Graceful shutdown ==="
docker run -d --name "$CONTAINER" "$IMAGE" -c /test/simple.toml
sleep 3

# Give 35 seconds — the daemon's internal shutdown timeout is 30s.
docker stop --time 35 "$CONTAINER" >/dev/null 2>&1
EXIT_CODE=$(docker inspect "$CONTAINER" --format='{{.State.ExitCode}}' 2>/dev/null || echo "unknown")

if [ "$EXIT_CODE" = "0" ]; then
    pass "graceful shutdown exits 0"
else
    fail "graceful shutdown exits 0 (got $EXIT_CODE)"
fi

docker rm -f "$CONTAINER" >/dev/null 2>&1

# ---------- Test 7: Zombie reaping ----------
echo ""
echo "=== Test: Zombie reaping ==="
docker run -d --name "$CONTAINER" "$IMAGE" -c /example/zei.toml
sleep 15

# Count zombie processes (state Z in /proc/*/stat). Exclude self.
# Allow up to 1 zombie (could be in-flight between creation and next reap cycle).
ZOMBIES=$(docker exec "$CONTAINER" sh -c 'count=0; for f in /proc/[0-9]*/stat; do read -r line < "$f" 2>/dev/null && case "$line" in *") Z "*) count=$((count+1)) ;; esac; done; echo $count') || ZOMBIES="error"
if [ "$ZOMBIES" = "0" ] || [ "$ZOMBIES" = "1" ]; then
    pass "zombies reaped ($ZOMBIES in-flight)"
else
    fail "zombies not reaped (found $ZOMBIES)"
fi

docker rm -f "$CONTAINER" >/dev/null 2>&1

# ---------- Summary ----------
echo ""
echo "================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
