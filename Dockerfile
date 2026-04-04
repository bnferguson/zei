FROM alpine:3.21

RUN apk add --no-cache xz curl

ARG TARGETARCH
RUN case "$TARGETARCH" in \
      amd64) ZIG_ARCH=x86_64 ;; \
      arm64) ZIG_ARCH=aarch64 ;; \
      *) echo "Unsupported architecture: $TARGETARCH" && exit 1 ;; \
    esac && \
    curl -fsSL "https://ziglang.org/download/0.15.2/zig-${ZIG_ARCH}-linux-0.15.2.tar.xz" | \
    tar -xJ -C /usr/local && \
    ln -s /usr/local/zig-${ZIG_ARCH}-linux-0.15.2/zig /usr/local/bin/zig

# Test users for privilege and user-lookup tests
RUN addgroup -g 1000 appgroup && \
    adduser -D -u 1000 -G appgroup appuser

WORKDIR /app
COPY . .

CMD ["zig", "build", "test", "--summary", "all"]
