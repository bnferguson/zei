# Dockerfile for building and testing zei init system
FROM debian:bookworm-slim

# Install dependencies
RUN apt-get update && apt-get install -y \
    wget \
    xz-utils \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Zig 0.15.2
# Auto-detect architecture and download appropriate binary
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then \
        ZIG_ARCH="x86_64"; \
    elif [ "$ARCH" = "aarch64" ]; then \
        ZIG_ARCH="aarch64"; \
    else \
        echo "Unsupported architecture: $ARCH" && exit 1; \
    fi && \
    wget https://ziglang.org/download/0.15.2/zig-${ZIG_ARCH}-linux-0.15.2.tar.xz && \
    tar -xf zig-${ZIG_ARCH}-linux-0.15.2.tar.xz && \
    mv zig-${ZIG_ARCH}-linux-0.15.2 /usr/local/zig && \
    ln -s /usr/local/zig/zig /usr/local/bin/zig && \
    rm zig-${ZIG_ARCH}-linux-0.15.2.tar.xz

# Verify Zig installation
RUN zig version

# Create non-root user for running zei main process
# The main process will drop to this user after initialization
RUN groupadd -r zei && useradd -r -g zei zei

# Set working directory
WORKDIR /zei

# Copy source files
COPY build.zig build.zig.zon ./
COPY src/ ./src/

# Build the project
RUN zig build

# The binary is now at /zei/zig-out/bin/zei
# Make it accessible globally
RUN ln -s /zei/zig-out/bin/zei /usr/local/bin/zei

# Set entrypoint
ENTRYPOINT ["/usr/local/bin/zei"]
CMD ["--config", "/config/services.yml"]
