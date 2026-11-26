#!/bin/sh
# Pi SPI rescue for an r3 unit whose rootfs boots but is unreachable (no NCM, no AP, no UART input):
# write the CCPABOOT mark into the bootstate partition (flash 0xFF0000) so the next boot stays in the
# recovery initramfs (USB NCM 192.168.50.2, telnet/ssh, flash-kernel/flash-rootfs). Writes ONLY
# 0xFF0000-0xFFFFFF; U-Boot, env, kernel, rootfs and the customer (persist) block are untouched.
# Dongle UNPLUGGED from USB power, SOIC clip on, run on the Pi in ~/u2ac_rescue (needs
# stock_kernel_env_20261126.bin from RESTORE_STOCK_KERNEL.sh for the U-Boot identity check).
# Leave recovery afterwards with `flash_eraseall -q /dev/mtd<N>` (N = bootstate in /proc/mtd), or flash-rootfs.
set -e; cd ~/u2ac_rescue
C="MX25L12835F/MX25L12845E/MX25L12865E"; PR="linux_spi:dev=/dev/spidev0.0,spispeed=1000"
sudo flashrom -p $PR -c "$C" -r fr1.bin; sudo flashrom -p $PR -c "$C" -r fr2.bin
cmp fr1.bin fr2.bin || { echo "ABORT: two reads differ (bad clip contact)"; exit 1; }
cmp -n 196608 fr1.bin stock_kernel_env_20261126.bin || { echo "ABORT: U-Boot region differs: not this unit / bad read"; exit 1; }
[ "$(stat -c %s fr1.bin)" = 16777216 ] || { echo "ABORT: not a 16 MiB read"; exit 1; }
# image = what is on the chip, with the bootstate block = "CCPABOOT" + 0xFF padding
{ head -c 16711680 fr1.bin; printf 'CCPABOOT'; head -c 65528 /dev/zero | tr '\000' '\377'; } > fr_mark.bin
[ "$(stat -c %s fr_mark.bin)" = 16777216 ] || { echo "ABORT: built image size"; exit 1; }
printf "00000000:00feffff rest\n00ff0000:00ffffff bootstate\n" > layout_bs.txt
sudo flashrom -p $PR -c "$C" -l layout_bs.txt -i bootstate -w fr_mark.bin
sudo flashrom -p $PR -c "$C" -r fr_verify.bin
cmp fr_verify.bin fr_mark.bin && echo "DONE: bootstate = CCPABOOT, the next boot is recovery (everything else unchanged)" \
    || echo "VERIFY MISMATCH - stop and tell Claude"
