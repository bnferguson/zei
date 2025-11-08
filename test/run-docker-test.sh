#!/bin/bash
# Test script for zei init system in Docker

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "=== Zei Init System - Docker Test ==="
echo ""

# Build the Docker image
echo "Building Docker image..."
docker build -t zei:latest .

echo ""
echo "=== Running Tests ==="
echo ""

# Test 1: Basic startup
echo "Test 1: Basic startup and service initialization"
echo "-----------------------------------------------"
docker run --rm \
    -v "$PROJECT_DIR/test/services-test.yml:/config/services.yml:ro" \
    --name zei-test-1 \
    zei:latest --config /config/services.yml &

CONTAINER_PID=$!
sleep 10
docker stop zei-test-1 2>/dev/null || true
wait $CONTAINER_PID 2>/dev/null || true

echo ""
echo "Test 1 completed."
echo ""

# Test 2: Signal handling
echo "Test 2: Signal handling (SIGTERM)"
echo "---------------------------------"
docker run --rm \
    -v "$PROJECT_DIR/test/services-test.yml:/config/services.yml:ro" \
    --name zei-test-2 \
    zei:latest --config /config/services.yml &

CONTAINER_PID=$!
sleep 5
echo "Sending SIGTERM to container..."
docker kill --signal=TERM zei-test-2 2>/dev/null || true
wait $CONTAINER_PID 2>/dev/null || true

echo ""
echo "Test 2 completed."
echo ""

# Test 3: Interactive mode
echo "Test 3: Interactive mode (manual testing)"
echo "----------------------------------------"
echo "Starting container in interactive mode..."
echo "You can manually test:"
echo "  - Watch service logs"
echo "  - Send signals (Ctrl+C for SIGINT)"
echo "  - Verify restart policies"
echo ""
echo "Press Enter to start, Ctrl+C to stop..."
read

docker run --rm -it \
    -v "$PROJECT_DIR/test/services-test.yml:/config/services.yml:ro" \
    --name zei-test-interactive \
    zei:latest --config /config/services.yml

echo ""
echo "=== All tests completed ==="
