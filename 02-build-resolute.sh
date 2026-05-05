#!/usr/bin/env bash
# Build Armbian Ubuntu 26.04 (resolute) for Orange Pi 5 Pro using the vendor
# kernel. Run this AFTER booting the 24.04 image produced by 01-build-noble.sh,
# NOT directly on stock Orange Pi vendor Ubuntu 22.04 — that kernel lacks
# CONFIG_BINFMT_MISC and the rust-coreutils chroot panic kills the build.
# See README.md.
#
# Output: ~/armbian-build/framework/output/images/Armbian-*_resolute_*.img.xz

set -euo pipefail

config_file="/boot/config-$(uname -r)"
if [[ -r "$config_file" ]] && grep -qE '^# CONFIG_BINFMT_MISC is not set' "$config_file"; then
    echo "ERROR: this kernel was built without CONFIG_BINFMT_MISC."
    echo "       The 26.04 build will panic in chroot. Boot Armbian noble first."
    echo "       (See Step 1 in README.md.)"
    exit 1
fi

if ! mountpoint -q /proc/sys/fs/binfmt_misc/; then
    sudo modprobe binfmt_misc || true
fi

WORK="${WORK:-$HOME/armbian-build}"
mkdir -p "$WORK"
cd "$WORK"

if [[ ! -d framework ]]; then
    git clone --depth=1 https://github.com/armbian/build.git framework
fi

cd framework

exec ./compile.sh \
    BOARD=orangepi5pro \
    BRANCH=vendor \
    RELEASE=resolute \
    BUILD_MINIMAL=yes \
    BUILD_DESKTOP=no \
    KERNEL_CONFIGURE=no \
    COMPRESS_OUTPUTIMAGE=sha,xz \
    EXPERT=yes
