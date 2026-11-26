#!/bin/sh
# Runs ON THE DONGLE (stock 2024.10.31 firmware, root), detached: setsid nohup sh /tmp/mlx/install.sh > /tmp/mlx/log 2>&1 &
# Installs the host-staged mainline kernel partition, erases ONLY the U-Boot env block, reboots.
# Every step is gated; on any failure BEFORE the env erase it puts the stock kernel back and does NOT reboot.
# Inputs in /tmp/mlx: kernel-part.img, mtd1-stock.bin, busybox (static recovery busybox), flash_erase (static mtd-utils)
# The four hashes pin ONE unit's dumps and staged image (the author's defaults below): for another unit export
# PLAN_SHA (staged kernel-part.img), STOCK1_SHA (its mtd1 dump), STOCK0_SHA (its mtd0 dump), ERASED_BLOCK_SHA
# (sha256 of one erased 64 KiB block), all from its own dumps and stage_kernel.py output.
set -u
cd /tmp/mlx || exit 9
BB=/tmp/mlx/busybox; FE=/tmp/mlx/flash_erase
PLAN_SHA=${PLAN_SHA:-ee576d76140c9fe0da69c87e999f1ed9d34cc6d8df77fdd3054b00d589e93072}
STOCK1_SHA=${STOCK1_SHA:-9e12e1fa9a5bc87ff4fd30a29cec066edb3a5423d566cf8fe087a6121bee6f70}
STOCK0_SHA=${STOCK0_SHA:-9c010f64229932493282f8f1343859e4ea35a161682070a18b0230600c2c7211}
ERASED_BLOCK_SHA=${ERASED_BLOCK_SHA:-71189f7fb6aed638640078fba3a35fda6c39c8962e74dcc75935aac948da9063}
s() { sha256sum "$1" | cut -d' ' -f1; }
say() { echo "[$(date +%T)] $*"; }
stop() { say "STOP: $*"; exit 1; }

say "0. preflight"
[ "$(s kernel-part.img)" = "$PLAN_SHA" ] || stop "kernel-part.img sha mismatch"
[ "$(s mtd1-stock.bin)" = "$STOCK1_SHA" ] || stop "mtd1-stock.bin sha mismatch"
[ "$(s /dev/mtd1)" = "$STOCK1_SHA" ] || stop "/dev/mtd1 is not the dumped stock kernel (stale plan, re-dump + re-stage)"
[ "$(s /dev/mtd0)" = "$STOCK0_SHA" ] || stop "/dev/mtd0 changed since the dump"
[ "$(head -c 196608 kernel-part.img | sha256sum)" = "$(head -c 196608 /dev/mtd1 | sha256sum)" ] || stop "head differs"
$BB flashcp -h >/dev/null 2>&1; $FE --help >/dev/null 2>&1 || stop "flash_erase does not run"
say "preflight OK"

say "1. write kernel partition (flashcp erase+write+verify)"
if ! $BB flashcp -v kernel-part.img /dev/mtd1 || [ "$(s /dev/mtd1)" != "$PLAN_SHA" ]; then
    say "kernel write FAILED or verify mismatch -> restoring stock kernel"
    $BB flashcp -v mtd1-stock.bin /dev/mtd1
    [ "$(s /dev/mtd1)" = "$STOCK1_SHA" ] && stop "stock kernel restored, NOT rebooting, unit is as before" \
        || stop "!!! STOCK RESTORE ALSO FAILED - DO NOT POWER OFF, tell Claude !!!"
fi
say "kernel partition == plan ($PLAN_SHA)"

say "2. erase ONLY the env block (mtd0 @0x30000, 1 block)"
$FE /dev/mtd0 0x30000 1
E=$(dd if=/dev/mtd0 bs=65536 skip=3 count=1 2>/dev/null | sha256sum | cut -d' ' -f1)
U=$(head -c 196608 /dev/mtd0 | sha256sum | cut -d' ' -f1); U0=$(head -c 196608 /tmp/mlx/mtd0-head.bin | sha256sum | cut -d' ' -f1)
if [ "$E" != "$ERASED_BLOCK_SHA" ] || [ "$U" != "$U0" ]; then
    say "env erase not verified (env=$E uboot_same=$([ "$U" = "$U0" ] && echo yes || echo NO)) -> restoring stock kernel, not rebooting"
    $BB flashcp -v mtd1-stock.bin /dev/mtd1
    stop "env block state unexpected - DO NOT POWER OFF, tell Claude"
fi
say "env erased, U-Boot unchanged"

say "3. reboot: U-Boot heweiencrypt converts the staged head, then boots mainline (watch UART2)"
sync; sleep 2; echo b > /proc/sysrq-trigger
