BINARY_NAME = zei
DOCKER_IMAGE = zei
DOCKER_TAG = latest
CONFIG_FILE = example/zei.toml

.PHONY: build test clean docker-build docker-test docker-run docker-e2e docker-shell help

build:
	zig build

test:
	zig build test --summary all

clean:
	rm -rf zig-out .zig-cache

docker-build:
	docker build -t $(DOCKER_IMAGE):$(DOCKER_TAG) .

docker-test: docker-build
	docker build --target test -t $(DOCKER_IMAGE)-test .
	docker run --rm $(DOCKER_IMAGE)-test

docker-run: docker-build
	docker run --rm --name $(BINARY_NAME) \
		$(DOCKER_IMAGE):$(DOCKER_TAG) -c /example/zei.toml

docker-run-detached: docker-build
	docker run -d --name $(BINARY_NAME) \
		$(DOCKER_IMAGE):$(DOCKER_TAG) -c /example/zei.toml

docker-e2e: docker-build
	sh test/e2e.sh

docker-shell: docker-build
	docker run --rm -it \
		--entrypoint /bin/sh \
		$(DOCKER_IMAGE):$(DOCKER_TAG)

docker-clean:
	docker rm -f $(BINARY_NAME) 2>/dev/null || true

help:
	@echo "Available targets:"
	@echo "  build          - Build zei with zig build"
	@echo "  test           - Run unit tests"
	@echo "  clean          - Remove build artifacts"
	@echo "  docker-build   - Build Docker image"
	@echo "  docker-test    - Run unit tests in Docker (Linux)"
	@echo "  docker-run     - Run zei as PID 1 in Docker"
	@echo "  docker-run-detached - Run in background"
	@echo "  docker-e2e     - Run end-to-end tests in Docker"
	@echo "  docker-shell   - Open shell in Docker container"
	@echo "  docker-clean   - Remove Docker container"
	@echo "  help           - Show this help"
