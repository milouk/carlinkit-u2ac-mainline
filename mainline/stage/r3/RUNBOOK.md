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
All of these are on the web UI's Settings tab too (Wi-Fi channel width, Options, Troubleshooting), next to the
Wi-Fi/Bluetooth names, paired phones and startup mode.
- `u2ac-bt-slowbaud`: download the BT patch at 115200 instead of the default 3 Mbaud (kernel patch 0007, as the stock
  firmware does it. ~5 s -> ~1 s). Use it if hci0 does not come up or `[uptime]` stamps show no gain.
- `u2ac-bt-0092`: newer Nexus 6P BT patch instead of the stock 0082 (test LE + pairing).
- `u2ac-wifi-80`: allow the 80 MHz AP (default 40 MHz: ample for AA, ~40 mA less while listening).
- `u2ac-dev` / `u2ac-aa-force`: maintenance / Android Auto forced (`u2ac-aa dev on|off|aa`).
- `u2ac-led-off`: status light dark (the WS2812B draws ~5-20 mA lit).
- `u2ac-ffs-chunk` (contents 512..16384): USB transfer size toward the car. 16384 default. A head unit that
  drops/re-powers USB in a loop (VAG reports, aa-proxy-rs #131/#144): `echo 512 > /run/persist/u2ac-ffs-chunk`.
- `audio_max_unacked` (the "voice commands drop words" tweak) only acts with `mitm = true`. Our build runs aa-proxy-rs
  in passthrough (no head-unit certificates), so it is a no-op here and is not offered in the web UI.
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
marks a boot good once NCM + ssh are up (on a car, or with no host within 1.5 s, once the USB probe has
decided: no NCM then), so a rootfs that boots but is unreachable later is NOT caught by it.
Escape for that case (no NCM, no AP, no UART input): Pi + SOIC clip, `mainline/rescue/FORCE_RECOVERY_SPI.sh`
(copy to the Pi's ~/u2ac_rescue, writes ONLY the bootstate block 0xFF0000 = CCPABOOT -> next boot = recovery,
two-read + U-Boot identity checks, read-back verify). Tested against a fake flashrom: only that block changes.

## Status light (WS2812B on GPIO1_IO03, module u2ac-ws2812, /sys/class/leds/rgb:status)
Stock colours (2024.10.31 /etc/rgbLight.conf): purple steady = starting. Cyan blink 500/100 = Android Auto
waiting for the phone. Blue blink 300/100 = the phone is in (AA TCP up), the car has not switched to Android
Auto yet. Green steady = the car took the accessory and AA is on its screen. Stock blinks it 1000/1000, which
read as "still connecting" in the car, so it is steady since 2026-11-27. Amber blink 1000/500 = fault
(radio, AP or BT did not come up: /run/log/u2ac-aa.log). Dim white steady = maintenance (computer on USB, or
dev mode). By hand: `echo 7f0000 > /sys/class/leds/rgb:status/color` (RRGGBB), `brightness` 0..255, `trigger` timer.

## USB at boot: car or computer (u2ac-usbprobe)
Car test 2026-11-27 (flight log): NCM was on the port from 2 s to 30 s, until aa-proxy-rs took it once the
phone was in, and SYNC 3 said "USB device not supported" for it. Now rcS's board hook (board-rcS.sh
board_usb_probe) first shows aa-proxy-rs's own MTP-stage identity (18d1:4ee1, bcdDevice 0x3008, "aa-proxy",
serial 0123456), served by u2ac-usbprobe (arm-imx6ul-u2ac/tools/u2ac-usbprobe.c, FunctionFS). A head unit asks
it AOA GET_PROTOCOL at once (SYNC 3: 33 ms after SET_CONFIGURATION), a computer never does. Verdict in
/run/u2ac-usbprobe, also in `u2ac-aa status` and the flight log:
- `car`: answered 2, port emptied 0.2 s later, no NCM this boot. The car next sees the MTP stage when the
  phone is in.
- `noaoa` (configured, 3 s silent): NCM as before and u2ac-aa's carrier/ARP test. A car there (one that waits
  for the driver before AOA) gets NCM taken off the port at once.
- `none` (nobody configured it within 1.5 s: a car still booting): rcS goes on (and marks the boot slot)
  without NCM, the probe keeps the port until 10 s. A late host is then a car (`car`) or gets NCM (`noaoa`, `/run/u2ac-usbprobe.how` = noaoa-late).
- `dev` (dev mode) or `failed` (the probe could not run): NCM exactly as before.
Measured on the unit in RAM 2026-11-27: the Mac configures it after 224 ms, `noaoa` at 3.2 s, NCM back.
A pyusb head unit got [2, 0] and the device left the bus 0.2 s later. Maintenance on a computer takes ~3.5 s
longer than before.

## Hands-free guard: incoming calls on SYNC 3 (aa-build patches 0004, 0006)
- 0006 (2026-11-28): the guard starts right after the phone's AA Wireless RFCOMM is accepted (one guard at a time)
  and the bootstrap no longer disconnects the phone (only the AA RFCOMM and the HSP stub close). Bench, real Pixel:
  guard connected 3.9 s after the phone's Bluetooth, before its hotspot join (was after the whole bootstrap,
  34 s after power-on in a car run, SYNC's own HFP ~20 s earlier). An AA restart still ends the guard and
  disconnects the phone first (clean next handshake).
Car test 2026-11-27: on an incoming call the caller could not hear the driver, outgoing calls were fine. The
Pixel's own records (adb `dumpsys telecom`, `bluetooth_manager`) put every call on the car's hands-free link,
never the dongle. The incoming one opened its audio link while still ringing (in-band ringing). SYNC 3's
"Use Phone Ringtone" fixes it, but the car resets that setting every drive, and Android 17 dropped the
developer option that turned in-band ringing off. Android's HeadsetService turns in-band ringing off for
every hands-free device while more than one is connected (`updateInbandRinging`, `+BSIR: 0`). So after the
Bluetooth bootstrap aa-proxy-rs (AA_HFP_GUARD=1, set by u2ac-aa) connects to the phone as a hands-free unit
with no features and sends `AT+ANDROID=SINKAUDIOPOLICY,2,2,2`: never active, no calls, no in-band ringing.
The phone stores that per device (seen in its database: call_establish, set_active_after_connection and
in_band_ringtone all NOT_ALLOWED) and refuses to make the dongle the active device (ActiveDeviceManager
`setHfpActiveDevice`), so calls stay on the car. No SCO listener on the dongle, so no audio can reach it.
A phone that refuses the policy (older Android) is disconnected and left alone.
- Log: `hfp-guard:` lines in aa-proxy-rs.log (flight log). With the car connected, `phone: +BSIR: 0` = in-band
  ringing off. Status: `u2ac-aa status` (hands-free guard: on|off).
- Off: `: > /run/persist/u2ac-hfp-guard-off; persist save`, then reboot.
- Bench 2026-11-27 (real Pixel, carsim): connected 2.7 s after the bootstrap, policy accepted, `+BSIR: 0`.
  After an AA session restart the phone resets the first 3 or 4 handshake attempts (it is still connected
  through the guard), and the reconnect takes the same 15 s as without the guard.

## Flight recorder (car runs survive the ignition)
Car mode writes the logs (u2ac-aa, aa-proxy-rs, bluetoothd, hostapd, dmesg, TCP/USB state) gzip'd into the last
1 MiB of the rootfs MTD (board.env FLIGHTLOG_SIZE, which build.sh keeps the squashfs out of; 8 slots x 128 KiB,
oldest reused, squashfs bytes_used checked before every write; the next slot is erased ahead of time outside
a session, so the write inside one only programs pages, no erase stall):
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

## Start-up time (car runs, flight log; `u2ac-metrics` reports the same steps as u2ac_aa_event_seconds)
- 2026-11-28 drive (rootfs 0cb82a90): car on the port at 2.4 s, radios 5.7, AP 8.9, BT up 12.1, aa-proxy-rs
  first line 13.8, phone on Bluetooth 15.0 (1st try), phone on the hotspot 22.7 (7.3 s, 11.7 s the drive
  before: phone side), Bluetooth wrap-up until 25.4, Android Auto data 27.2. SYNC waited ~24 s for the dongle.
- Causes on our side: xz squashfs reads on the single core (bluetoothd 2.1 s cold / 0.3 s cached, aa-proxy-rs
  2.2 s / 0.01 s; its 4.7 s pre-read lost the race), and aa-proxy-rs finishing the Bluetooth wrap-up (phone
  disconnect ~2.4 s) before it starts USB. Fixes (rootfs 4b1bf7ae): D-Bus at once + the BT stack read first,
  aa-build patch 0005 (wrap-up in the background), "BT: address set" stamp, hostapd -t timestamps.
- Not ours: the phone's hotspot join (two associations per start in both logs) and SYNC's projection start.

## Car-off sleep (u2ac-aa car_sleep; web Options "Sleep when the car is off", flag u2ac-sleep-off)
- After a live AA session, once the car has not used the USB port (UDC not "configured") for 90 s
  (`U2AC_SLEEP_S`) and no session runs: aa-proxy-rs stopped (no more Bluetooth calls pulling the phone onto
  the hotspot), hostapd + udhcpd stopped, wlan0 down, BT controller powered off, light off, a flight-log slot
  ("sleep"). The port then shows the boot's MTP-stage identity (board-rcS.sh `usbprobe_up 3600000 3000`): the
  first host that configures it wakes the dongle by a reboot (car = AOA GET_PROTOCOL, computer = noaoa).
- A car that is on but idle on USB for 90 s (the phone stayed away) also sleeps: it configures the probe at once,
  so that costs one reboot. `u2ac-aa sleep-now` sleeps by hand. Status: `u2ac-aa status`, metric u2ac_sleeping.
- Verified on the unit 2026-11-28 (RAM copy): sleep-now, mockhu saw 18d1:4ee1 at 3.7 s, GET_PROTOCOL -> reboot,
  back in maintenance mode. Selftest: sleeps in car/carncm only. Power saved not measured yet (USB meter).

## Radio watch (u2ac-aa radio_watch, every 5 s in the saver loop; `u2ac-aa watch` runs one check by hand)
- hostapd gone, or wlan0 re-created by brcmfmac's own crash reset (new ifindex) -> AP again (hostapd, address,
  DHCP, txpower). wlan0 missing 60 s -> the SDIO host 2190000.mmc is re-bound. bluetoothd/D-Bus gone -> started
  again, then aa-proxy-rs restarted outside a session. hci0 missing 30 s -> serdev serial0-0 re-bound, the BD
  address set after the kernel's 2 s auto power-off (set inside that window, mgmt lost the controller).
- Each repair at most 8 times a boot, 30 s apart (`U2AC_WATCH_GAP` cs). Amber while a radio is down.
  `: > /run/u2ac-watch/off` stops it for this boot. Repairs show in `u2ac-aa status` and the flight log.
- Verified on the unit 2026-11-27 (RAM): hostapd killed (AP back in 4.4 s), brcmfmac unbind/bind (the re-probe
  hung on the still-running chip, the 60 s SDIO host re-bind recovered it in 1.3 s, then AP again), bluetoothd
  killed (back in 0.3 s), hci_uart_bcm unbind (back with its stable 38:BA:B0 address, twice).
- Not covered: a chip that hangs without the kernel noticing (no crash mailbox, wlan0 stays); only the next
  power cycle helps there.

## Known limits (reviewed 2026-11-27, not fixed on purpose)
- Recovery is not left on its own within one power cycle: 3 boots in a row cut off before rcS marks them good
  (~5-6 s after power-on: the USB probe decided, then NCM + ssh up or no NCM) make the 4th boot a recovery
  visit, and recovery waits
  for a computer. The next power cycle boots the rootfs again (the visit resets the count). Any boot that gets
  past rcS resets the count, so it takes 3 consecutive cut-short boots. Fixing it = the recovery init, i.e. a
  kernel flash.
- A FROZEN aa-proxy-rs (runtime stuck in the kernel, never seen in testing) is only logged by its watchdog
  ("tokio runtime has not ticked"), not killed. The supervisor restarts it only when it exits.
- Power cut during a persist write loses the archive (pairings): writes happen only when something changed
  (verified: a full phone session leaves BlueZ's info/attributes/settings byte-identical, only cache/ changes).
  `persist load` restores an archive completely or not at all (selftest 2c), never the part written before
  the cut, and a save before `state_restore` ran (radios failed at boot) keeps the archived pairings.
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
