#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# fetch-bcm4358.sh [OCBM_DIR]: install the BCM4358 Wi-Fi/Bluetooth firmware the U2AC image needs.
#
# The files are Broadcom's, shipped by Carlinkit in its own U2AC_AUTOKIT 2023.10.14.1711 update image, and are not
# redistributed by this project. This script downloads that image from the public mirror kept by
# ludwig-v/wireless-carplay-dongle-reverse-engineering, decrypts it (AES-128-CBC, the key/IV documented there),
# takes the vendor's bcm4358 bundle and installs three files, each sha256-checked, into the board overlay:
#   <ocbm>/baseline/arm-imx6ul-u2ac/rootfs/lib/firmware/brcm/
#     brcmfmac4358-sdio.bin  <- fw_bcm4358_ag_apsta.bin   (Wi-Fi 7.112.100.4)
#     brcmfmac4358-sdio.txt  <- nvram_4358.txt            (board file, P301)
#     BCM4358A3.hcd          <- BCM4358A3.hcd             (Bluetooth patch 0082)
# OCBM_DIR defaults to mainline/ocbm (the upstream checkout with ocbm-u2ac.patch applied).
# The optional newer Bluetooth patch (/run/persist/u2ac-bt-0092, BCM4358A3-0092-nexus6p.hcd from the Nexus 6P's
# vendor image) is not fetched: without it that toggle simply keeps the stock patch.
set -eu
URL=https://raw.githubusercontent.com/ludwig-v/wireless-carplay-dongle-reverse-engineering/master/Firmware/U2AC/_AUTOKIT/2023.10.14.1711/U2AC_AUTOKIT_Update.img
IMG_SHA=c6ab3f21c0353cd3f9fb5da0fc00b36e180e121ff00bc6ef6e9cfa57c5a1eb34
D=$(cd "$(dirname "$0")" && pwd)
OCBM=${1:-$D/../ocbm}
DST=$OCBM/baseline/arm-imx6ul-u2ac/rootfs/lib/firmware/brcm
die() { echo "fetch-bcm4358: $*" >&2; exit 1; }
sha() { if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -c1-64; }
[ -d "$OCBM/baseline/arm-imx6ul-u2ac" ] || die "no U2AC board under $OCBM: clone ocbm and apply ocbm-u2ac.patch first"
for c in curl openssl tar od; do command -v $c > /dev/null 2>&1 || die "needs $c"; done
T=$(mktemp -d "${TMPDIR:-/tmp}/fetch-bcm4358.XXXXXX")
trap 'rm -rf "$T"' EXIT

echo "fetch-bcm4358: downloading the vendor U2AC_AUTOKIT 2023.10.14.1711 image (13 MB)"
curl -fsSL --retry 3 -o "$T/update.img" "$URL" || die "download failed: $URL"
[ "$(sha "$T/update.img")" = "$IMG_SHA" ] || die "the image's sha256 is not the pinned $IMG_SHA (mirror changed?)"

# AES-128-CBC, key = IV = the 16 ASCII bytes "CarPlayiHXF1o74i"; the last partial block is not encrypted, so no
# padding check (-nopad): the gzip'd tar inside is read only as far as the bundle we need
K=$(printf 'CarPlayiHXF1o74i' | od -An -tx1 | tr -d ' \n')
n=$(wc -c < "$T/update.img"); head -c $((n / 16 * 16)) "$T/update.img" > "$T/update.blocks"   # whole blocks only
openssl enc -d -aes-128-cbc -nopad -K "$K" -iv "$K" -in "$T/update.blocks" -out "$T/update.tgz" 2> /dev/null \
    || die "decryption failed"
tar -xzf "$T/update.tgz" -C "$T" ./bcm4358_rootfs.tar.gz 2> /dev/null || true   # the archive's tail is cut off
[ -s "$T/bcm4358_rootfs.tar.gz" ] || die "no bcm4358_rootfs.tar.gz in the image"
mkdir -p "$T/b" && tar -xzf "$T/bcm4358_rootfs.tar.gz" -C "$T/b" || die "cannot unpack the bcm4358 bundle"
S=$T/b/lib/firmware/bcm

mkdir -p "$DST"
while read -r src dst want; do
    [ -f "$S/$src" ] || die "the bundle has no $src"
    [ "$(sha "$S/$src")" = "$want" ] || die "$src: sha256 differs from the pinned $want"
    cp "$S/$src" "$DST/$dst" && chmod 644 "$DST/$dst"
    echo "fetch-bcm4358: $dst ($want)"
done << EOF
fw_bcm4358_ag_apsta.bin brcmfmac4358-sdio.bin 4a2731a43d397678f0e733835b847fffda4aeea41e3ba3baf2f9adc81e479710
nvram_4358.txt brcmfmac4358-sdio.txt 46fd22aef5e05c05f854eed22fdfe266d80314bfd841a6271756df3e6200912f
BCM4358A3.hcd BCM4358A3.hcd 2eb24c4ead62bfffb6461fd5efed49281ea13ee0bb4f7205132ad926c12a9c36
EOF
echo "fetch-bcm4358: installed into $DST"
