# Build stage: compile zei binary
FROM alpine:3.21 AS builder

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

ARG TARGETARCH
WORKDIR /app
COPY . .
RUN case "$TARGETARCH" in \
      amd64) ZIG_TARGET=x86_64-linux ;; \
      arm64) ZIG_TARGET=aarch64-linux ;; \
      *) ZIG_TARGET=native ;; \
    esac && \
    zig build -Dtarget=$ZIG_TARGET -Doptimize=ReleaseSafe

# Build zombie_maker
FROM alpine:3.21 AS zombie-builder

RUN apk add --no-cache gcc musl-dev make
WORKDIR /app
COPY example/zombie-maker/ .
RUN make && chmod +x zombie_maker

# Unit test stage (used by `docker build --target test`)
FROM builder AS test
CMD ["zig", "build", "test", "--summary", "all"]

# Runtime stage
FROM alpine:3.21

# Create non-root users and groups matching pei's test users
RUN adduser -D -u 1000 appuser \
    && adduser -D -u 1001 worker \
    && adduser -D -u 1002 monitor \
    && adduser -D -u 1003 zombie

COPY --from=builder /app/zig-out/bin/zei /zei
COPY --from=zombie-builder /app/zombie_maker /usr/local/bin/zombie_maker
COPY example/signal-handler.sh /example/signal-handler.sh
COPY example/json-logger.sh /example/json-logger.sh
COPY example/ /example/
COPY test/ /test/

# setuid so zei can escalate privileges when run as appuser
RUN chown root:root /zei && \
    chmod u+s /zei && \
    chown zombie:zombie /usr/local/bin/zombie_maker && \
    chmod +x /example/signal-handler.sh && \
    chmod +x /example/json-logger.sh && \
    chmod +x /test/*.sh 2>/dev/null || true

USER appuser

ENTRYPOINT ["/zei"]
