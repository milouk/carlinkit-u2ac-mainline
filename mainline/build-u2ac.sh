#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# build-u2ac.sh [STEP...]: build the U2AC kernel + rootfs in Docker with the exact settings of the flashed r3 image.
#   STEP: fetch userspace kernel rootfs (default: all four, in that order; `rootfs` alone after a change to it)
# Before the first build (README "Build"):
#   ocbm/            = upstream lvalen91/ocbm at OCBM_BASE with ocbm-u2ac.patch applied
#   firmware/fetch-bcm4358.sh run once (the Broadcom Wi-Fi/BT firmware is not redistributed here)
#   keys/authorized_keys (optional): SSH public keys baked into the rootfs; without it SSH takes the password
#                    (build default "baseline": change it with `passwd; persist save` on the unit)
# U2AC_KVER=7.2.15 (default, the hardware-proven series) or 7.3.6. Build tree: docker volume u2ac-build.
# Outputs: out-<KVER>/nousb/ (ccpa-baseline-bcm4358.zimg = the kernel, rootfs.img + .sha256).
set -eu
D=$(cd "$(dirname "$0")" && pwd)
KV=${U2AC_KVER:-7.2.15}
TOP=/build/k$(echo "$KV" | tr -d .)
die() { echo "build-u2ac: $*" >&2; exit 1; }
[ -d "$D/ocbm/baseline/arm-imx6ul-u2ac" ] || die "no ocbm/ with the U2AC board: see README (clone ocbm, apply ocbm-u2ac.patch)"
[ -s "$D/ocbm/baseline/arm-imx6ul-u2ac/rootfs/lib/firmware/brcm/brcmfmac4358-sdio.bin" ] \
    || die "no BCM4358 firmware in the board overlay: run firmware/fetch-bcm4358.sh first"
mkdir -p "$D/out-$KV" "$D/keys"
KEYS=
[ -s "$D/keys/authorized_keys" ] && KEYS=AUTHORIZED_KEYS=/keys/authorized_keys
docker build -q -t u2ac-build "$D/docker" > /dev/null
docker run --rm -v "$D/ocbm:/work/ocbm:ro" -v u2ac-build:/build -v "$D/out-$KV:/out" -v "$D/keys:/keys:ro" u2ac-build \
    sh -c "U2AC_KVER=$KV sh /work/ocbm/baseline/build.sh BOARD=arm-imx6ul-u2ac TOP=$TOP \
        CROSS_COMPILE=arm-linux-gnueabihf- RECOVERY_USB=0 RECOVERY_EXFAT=0 RECOVERY_SSH=1 USB_HOST=0 \
        RADIO_MODULES=1 RADIO_FW=1 RADIO_DT=bcm4358 MTD_UTILS=1 $KEYS SOURCE_DATE_EPOCH=1795737600 \
        ${*:-fetch userspace kernel rootfs} && cp -r $TOP/out/. /out/"
echo "build-u2ac: outputs in out-$KV/nousb/"
