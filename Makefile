.PHONY: help build test test-interactive docker-build docker-test docker-clean clean

help:
	@echo "Zei Init System - Make targets"
	@echo ""
	@echo "Local builds (requires Zig 0.15.2):"
	@echo "  build              - Build the project locally"
	@echo "  test               - Run local unit tests"
	@echo "  clean              - Clean local build artifacts"
	@echo ""
	@echo "Docker builds and tests:"
	@echo "  docker-build       - Build Docker image"
	@echo "  docker-test        - Run automated Docker tests"
	@echo "  docker-interactive - Run Docker container in interactive mode"
	@echo "  docker-clean       - Remove Docker containers and images"
	@echo ""
	@echo "Combined:"
	@echo "  all                - Build locally and run tests"

# Local builds
build:
	zig build

test:
	zig build test

clean:
	rm -rf zig-cache zig-out .zig-cache

# Docker builds
docker-build:
	docker build -t zei:latest .

docker-test: docker-build
	@echo "Starting zei in Docker for 15 seconds..."
	docker run --rm -d \
		--name zei-test \
		-v $(PWD)/test/services-test.yml:/config/services.yml:ro \
		zei:latest --config /config/services.yml
	@sleep 15
	@echo ""
	@echo "Logs from zei:"
	@docker logs zei-test
	@echo ""
	@echo "Stopping container..."
	@docker stop zei-test

docker-interactive: docker-build
	docker run --rm -it \
		--name zei-interactive \
		-v $(PWD)/test/services-test.yml:/config/services.yml:ro \
		zei:latest --config /config/services.yml

docker-compose-up: docker-build
	docker-compose up

docker-compose-down:
	docker-compose down

docker-clean:
	docker rm -f zei-test zei-interactive 2>/dev/null || true
	docker rmi zei:latest 2>/dev/null || true

# Combined
all: build test
