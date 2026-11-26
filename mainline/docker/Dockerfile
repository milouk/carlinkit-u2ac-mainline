# Build host for the U2AC mainline baseline (ocbm baseline/build.sh needs a Linux host).
FROM debian:trixie
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf gcc make bc bison flex libssl-dev libelf-dev squashfs-tools cpio \
    xz-utils bzip2 device-tree-compiler python3 curl ca-certificates file patch perl kmod pkgconf \
    ncurses-bin git rsync qemu-system-arm lz4 zstd lzop && rm -rf /var/lib/apt/lists/*
WORKDIR /work
