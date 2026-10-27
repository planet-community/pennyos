# Cross-compile environment for the Cosmo mainline kernel (arm64 / MT6771).
# Debian + aarch64 toolchain + kernel build deps. The kernel source lives in a
# case-sensitive Docker volume (the macOS host FS is case-insensitive and corrupts
# case-colliding kernel files), so we build here, not on the host mount.
FROM debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc-aarch64-linux-gnu \
      make gcc g++ \
      bc bison flex \
      libssl-dev libelf-dev \
      cpio kmod \
      python3 \
      git ca-certificates \
      xz-utils zstd \
      device-tree-compiler \
      u-boot-tools \
      android-sdk-libsparse-utils \
    && rm -rf /var/lib/apt/lists/*

ENV ARCH=arm64
ENV CROSS_COMPILE=aarch64-linux-gnu-
WORKDIR /src
