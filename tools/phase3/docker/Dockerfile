# CyberDog Phase 3 kernel build container — native arm64 build of L4T r35.6.4
FROM ubuntu:20.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential bc bison flex libssl-dev libncurses5-dev \
    kmod cpio rsync wget curl xxd git python3 python3-pip \
    u-boot-tools device-tree-compiler libyaml-dev pkg-config \
    ca-certificates less vim-tiny file busybox-static \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /work
