FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG KERNEL_VERSION=unknown

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      bc \
      bison \
      build-essential \
      ca-certificates \
      ccache \
      clang \
      cpio \
      curl \
      dwarves \
      file \
      flex \
      kmod \
      libelf-dev \
      libssl-dev \
      lld \
      llvm \
      python3 \
      rsync \
      xz-utils \
      zstd \
      zsh

WORKDIR /workspace

LABEL msl.kernel_builder=1
LABEL msl.kernel_version_hint=${KERNEL_VERSION}
