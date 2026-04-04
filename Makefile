.PHONY: test docker-build docker-test docker-shell

test:
	zig build test --summary all

docker-build:
	docker build -t zei-dev .

docker-test: docker-build
	docker run --rm zei-dev

docker-shell: docker-build
	docker run --rm -it zei-dev /bin/sh
