# r3 install runbook (from r2 recovery, dongle on the Mac's USB)

> The author's install log for one unit. `backup/...` paths are that unit's private flash dumps: take your own
> before anything else (`flash-r3.sh` reads the staging base from `U2AC_BACKUP`), and expect your hashes to differ.

Inputs: `<KV>/kernel-part.img` + `<KV>/rootfs.img` (each with .sha256, kernel and rootfs MUST be the same KV,
the rootfs carries that kernel's modules). Both staged vs backup/mainline_r2_20261126 (r2 kernel 5c5d518b…):
- **7.2.15 = default** (same series as the hardware-proven 7.2.10 + 5 weeks of stable fixes, ~355 KB headroom)
- 7.3.6 = latest stable (patch 0004 rebased in patches-7.3/, SYSCTL rename, ~340 KB headroom, QEMU-booted only) Recovery login root / `baseline` over NCM 192.168.50.2.

**Helper:** `mainline/stage/r3/flash-r3.sh preflight | kernel [--go] | wait | check | rootfs [--go] | verify`
(Mac side, copies with sha256 proof, runs the on-unit --dry-run, flash is written ONLY with --go, KV=7.3.6 for
the other kernel). Steps 1-5 below are exactly these.

0. **Rehearsal (r2 RAM), now largely covered by the emulator dry run (mainline/selftest):** unpack r3 rootfs to /tmp/r3, chroot, `u2ac-aa start` in dev mode
   (`: > /run/persist/u2ac-dev`), confirm wlan0 + AP-ENABLED + bluetoothd + hci0. Module order fixed
   (brcmfmac, wcc, then sdhci_esdhc_imx). r2's btbcm wants brcm/BCM.hcd (r3's patch 0006 asks BCM4358A3.hcd).
1. Preflight on unit: `sha256sum /dev/mtd0 /dev/mtd1 /dev/mtd2` == 11609a5b… / 9eb24cc9… / 5c5d518b…
   (else re-dump and re-stage: `stage_kernel.py --mtd0 cur_uboot256k.bin --mtd1 <mtd2 dump> …`).
2. `scp -O 7.2.15/kernel-part.img root@192.168.50.2:/tmp/`, then `flash-kernel --dry-run /tmp/kernel-part.img <sha>`
   then `setsid flash-kernel /tmp/kernel-part.img <sha> &` (writes mtd2, erases env, reboots,
   power-loss window ~30 s = Pi SPI rescue `~/u2ac_rescue/RESTORE_STOCK_KERNEL.sh`).
3. r3 boots to RECOVERY (rootfs MTD still holds the stock JFFS2 = not a baseline squashfs). Check
   `cat /proc/mtd` shows rootfs/customer/bootstate, `/proc/version` 7.2.15, cpufreq present.
4. `scp -O 7.2.15/rootfs.img root@192.168.50.2:/tmp/`, then `flash-rootfs /tmp/rootfs.img <sha from .sha256>`, then
   `reboot`. **This overwrites the stock 2024.10.31 rootfs** (backup:
   backup/mainline_r1_20261126/mtd3_stock_rootfs_2024.10.31.bin = flash 0x380000-0xffffff).
5. Rootfs boot with the Mac attached = **maintenance mode** (computer on USB answers on NCM): ssh
   `root@192.168.50.2` with the id_rsa key (or `baseline`). `u2ac-aa status`, `cat /run/log/u2ac-aa.log`,
   `iw phy phy0 channels | grep -A3 5180` (VHT80? -> hostapd-80.conf), dmesg for "Firmware rejected country".
6. Phone test: `u2ac-aa aa-now` (NCM drops) or unplug -> car. Pixel: pair "AutoKit" (BT), wireless AA.
   Calls: phone must already be paired with the car (direct HFP). Dongle never takes HFP.

Back to stock (from recovery): restore mtd2 (kernel) from backup/pre_mainline_20261126/mtd1.bin via
`flash-kernel --restore`, env from env-stock.bin, and flash 0x380000-0xffffff (rootfs+customer+bootstate)
from mtd3_stock_rootfs_2024.10.31.bin. Or the Pi SPI full-image path.

## Toggles after the install (persisted: `: > /run/persist/<flag>; persist save`, then reboot)
- `u2ac-bt-slowbaud`: download the BT patch at 115200 instead of the default 3 Mbaud (kernel patch 0007, as the stock
  firmware does it. ~5 s -> ~1 s). Use it if hci0 does not come up or `[uptime]` stamps show no gain.
- `u2ac-bt-0092`: newer Nexus 6P BT patch instead of the stock 0082 (test LE + pairing).
- `u2ac-wifi-80`: allow the 80 MHz AP (default 40 MHz: ample for AA, ~40 mA less while listening).
- `u2ac-dev` / `u2ac-aa-force`: maintenance / Android Auto forced (`u2ac-aa dev on|off|aa`).
- `u2ac-led-off`: status light dark (the WS2812B draws ~5-20 mA lit).
- `u2ac-ffs-chunk` (contents 512..16384): USB transfer size toward the car. 16384 default. A head unit that
  drops/re-powers USB in a loop (VAG reports, aa-proxy-rs #131/#144): `echo 512 > /run/persist/u2ac-ffs-chunk`.
- Field notes (ROUND2_AA_SOFTWARE.md): voice commands drop words -> try `audio_max_unacked = 1` in config.toml.
  Confirm `iw reg get` shows GR. Never let aa-proxy-rs generate hostapd.conf (its template has TKIP = 54 Mbps cap).
Web UI: http://10.0.0.1 (AP) or http://192.168.50.2 (USB). aa-proxy-rs's own UI (no login, has shell-command
settings) listens on 127.0.0.1:8080 only: `ssh -L 8080:127.0.0.1:8080 root@10.0.0.1`, then http://localhost:8080.
SSH over the AP (10.0.0.1) is KEY-ONLY (`-s`): the AP password is the vendor default and root's the documented dev
default. Over USB (192.168.50.2) key or password. Change the AP password in the web UI (the phone learns it over BT).
Recovery login: no sftp-server in recovery any more -> use `scp -O`.
Recovery on request: `reboot-recovery` (or the web UI button) = ONE recovery boot (boot-slot request), the next
boot is the rootfs again. The old persistent CCPABOOT mark is now only flash-rootfs's "write unfinished" guard.

Mode detection: "computer on USB" = usb0 carrier + 192.168.50.100 answers ARP (or ping). A head unit that
runs cdc_ncm + DHCP (some Linux/Android units) would look like a computer and stay in maintenance: fix it
from the phone over Wi-Fi, web UI -> Mode -> "Android Auto always" (`u2ac-aa dev aa`). Note the guard: rcS
marks a boot good once NCM + ssh are up, so a rootfs that boots but is unreachable later is NOT caught by it.
Escape for that case (no NCM, no AP, no UART input): Pi + SOIC clip, `mainline/rescue/FORCE_RECOVERY_SPI.sh`
(copy to the Pi's ~/u2ac_rescue, writes ONLY the bootstate block 0xFF0000 = CCPABOOT -> next boot = recovery,
two-read + U-Boot identity checks, read-back verify). Tested against a fake flashrom: only that block changes.

## Status light (WS2812B on GPIO1_IO03, module u2ac-ws2812, /sys/class/leds/rgb:status)
Stock colours (2024.10.31 /etc/rgbLight.conf): purple steady = starting. Cyan blink 500/100 = Android Auto
waiting for the phone. Blue blink 300/100 = the phone is in (AA TCP up), the car has not switched to Android
Auto yet. Green blink 1000/1000 = the car took the accessory (AA on its screen). Amber blink 1000/500 = fault
(radio, AP or BT did not come up: /run/log/u2ac-aa.log). Dim white steady = maintenance (computer on USB, or
dev mode). By hand: `echo 7f0000 > /sys/class/leds/rgb:status/color` (RRGGBB), `brightness` 0..255, `trigger` timer.

## Flight recorder (car runs survive the ignition)
Car mode writes the logs (u2ac-aa, aa-proxy-rs, bluetoothd, hostapd, dmesg, TCP/USB state) gzip'd into the last
1 MiB of the rootfs MTD (8 slots x 128 KiB, oldest reused, squashfs bytes_used checked before every write):
90 s after start, 60 s into each live AA session, 5 s after a session ends, every 2 min while no session if
aa-proxy-rs logged. Back on the Mac (maintenance): `ssh root@192.168.50.2 u2ac-aa flightlog` (list),
`u2ac-aa flightlog last` (or SEQ) prints one. Off: `: > /run/persist/u2ac-flightlog-off; persist save`.

## Car test without the car (mainline/carsim)
`mainline/carsim/run.sh [--consent S] [--bin aa-build/out/aa-proxy-rs] [--hu --no-zlp]`, dongle in maintenance:
the Mac plays the head unit over USB (pyusb: AOA GET_PROTOCOL/strings/[consent wait]/START, VERSION_REQUEST,
echo frames 64..16384 B, 3 MB bulk), fakephone on the dongle plays the phone (aa-proxy-rs direct-TCP mode).
RAM only, NCM comes back after --dur. Logs in carsim/out/. 2026-11-26 it reproduced the car failure: v1.3.0
waits 6 s for ACCESSORY_START (MTP stage) and io_loop 8 s for the switch, so a car that asks the driver
first (SYNC 3 "Enable Android Auto?") got the gadget torn down and the phone dropped (then the BT handshake
again = the cyan blinking until a manual connect). aa-build patch 0003: AA_MTP_WAIT_SECS (90), AA_ENABLE_WAIT_SECS
(30), AA_USB_READY_SECS (300, main now reports a failed USB setup at once), AOA/ep0 events logged at info, and
car->dongle reads per max packet again (a car without zero-length packets stalled 512/4096/8192-B frames).

## Re-flash the rootfs later (from the r3 rootfs, dongle on the Mac)
`flash-r3.sh to-recovery` (one recovery boot, writes a bootstate request), then `wait`, `check`,
`rootfs [--go]`, `verify`. The kernel stays. The rootfs's modules must come from the same kernel tree.

## Before staging a new build
`sh mainline/selftest/run.sh mainline/out-<KV>/nousb/rootfs.img` (Docker, armv7 under qemu-user, no dongle):
binaries load, boot slots under the RECOVERY busybox, web UI endpoints + auth + injection, `u2ac-aa start`
dry run (car / computer / dev). Must end `selftest: 0 failure(s)`.

## Known limits (reviewed 2026-11-27, not fixed on purpose)
- Recovery is not left on its own within one power cycle: 3 boots in a row cut off before rcS marks them good
  (~5-6 s after power-on: NCM + ssh up, no host needed) make the 4th boot a recovery visit, and recovery waits
  for a computer. The next power cycle boots the rootfs again (the visit resets the count). Any boot that gets
  past rcS resets the count, so it takes 3 consecutive cut-short boots. Fixing it = the recovery init, i.e. a
  kernel flash.
- A FROZEN aa-proxy-rs (runtime stuck in the kernel, never seen in testing) is only logged by its watchdog
  ("tokio runtime has not ticked"), not killed. The supervisor restarts it only when it exits.
- Power cut during a persist write loses the archive (pairings): writes happen only when something changed
  (verified: a full phone session leaves BlueZ's info/attributes/settings byte-identical, only cache/ changes).
- The repo rebuilds the flashed rootfs: fresh upstream OCBM_BASE + ocbm-u2ac.patch -> identical tree (626
  entries, contents, links, modes. 2026-11-27). Only file times differ (mksquashfs keeps checkout mtimes).

## After the first car test (measured experiments, one at a time, audit/ROUND2_*.md)
- CPU: during a session u2ac-aa sets `performance` + cpuidle state2 off, `ondemand` otherwise (log: "cpu: session").
- NOR at 49.5 MHz fast-read (DT, ~0.7-1 s boot): first measure reads 5x sha256 vs the image (ROUND2_BOOT 3.4).
- zstd rootfs (-no-fragments, 12.26 of 12.98 MB, ~2 s boot, needs SQUASHFS_ZSTD back in the kernel).
- Idle policy (ROUND2_POWER §1: AP off after 10 min without a phone, probe known phones, ~6x less idle draw).
- aa-proxy-rs: pipelined FFS writes, RX chunk 4096 (ROUND2_PERFORMANCE #3/#10). brcmfmac single-IRQ + idletime (#5/#7).
- Boot order (measured 11-26 on the unit: radios up 6.6 s, BT up 11.7 s in maintenance): the aa-proxy-rs
  pre-read (15 MB from the xz squashfs) runs alongside the module loads and bluetoothd's start, and squashfs
  has one decompressor. Try starting it after `radios up` and compare the `[uptime]` stamps.
- Overcommit: measure aa-proxy-rs VmSize/VmRSS. v1.3.0 dropped the 1 GiB arena, so overcommit_memory=1 may go.
- Known phones: u2ac-aa seeds /etc/aa-proxy-rs/known_devices at every boot from the BlueZ pairings that hold a
  link key (aa-proxy-rs dials only that list, its own record comes only after a full BT handshake).
- timeout_secs = 20 (upstream 10): the stall check (both directions must move within timeout_secs). The effective
  silence limit is 15 s: io_tokio.rs read_input_data has a fixed 15 s read timeout per direction.
- Measured 2026-11-27 with the real Pixel (carsim PHONE=1, the Mac as the car): auto-dial from known_devices ->
  BT up 18 s -> phone TCP 29 s -> car AOA + VERSION_RESPONSE from the Pixel. The Pixel closes its TCP if the car
  sends nothing for ~10 s, so a first-time SYNC "Enable Android Auto?" answered after >10 s costs one automatic
  round (re-dial ~20-40 s). The car remembers the answer, the second round goes through.
- Phone: keep "Phone calls" ON for AutoKit on the Pixel (the dongle wakes the phone through its HSP AG). The daily
  phone first in /etc/aa-proxy-rs/known_devices (an absent first entry costs ~5 s each boot).
