# U2AC round 2: car power-on to "phone connected to Android Auto" (audit, 2026-11-26)

Read-only review. No device was touched, nothing was flashed, no repository file except this one was changed, the Docker
volumes were only mounted read-only. Measurements below were made on copies in the session scratchpad (not kept).

Legend: **VERIFIED** = read in code/config/log, or measured on the built artefacts (`out-7.2.15/nousb/rootfs.img`,
`aa-build/out/aa-proxy-rs`). **INFERRED** = reasoning, scaled or typical figures that need an on-unit measurement.
"Kernel src" = `u2ac-build:/build/k7215/linux-7.2.15`. "aa src" = `u2ac-aa-src:/src/aa-proxy-rs` (v1.3.0, 41e245a).
Times are seconds from power applied to the dongle. `T_u` = the moment `u2ac-aa start` runs.

## Already done (not re-proposed)

Checked in the current tree: `known_devices` persisted (u2ac-aa `state_restore`/`sync_dir aa-etc`), btmgmt waits for the
mgmt index, bluetoothd log poll instead of `sleep 2`, BT in parallel with the AP, `hci_uart` loaded first, `u2ac-aa`
started from `board_early` in parallel with NCM/SSH, `performance` governor during boot, boot-slot counter (no erase on
the normal path), `quiet` in bootargs, XZ BCJ decoders, HZ=250, supervised aa-proxy-rs with OOM protection, 16 KiB FFS
transfers, `dtim_period=1`, opt-in early-baud patch 0007. **Not done yet, carried over and now measured:** SYSTEM_TUNING
F7 (flat insmod list), F8 (pre-read aa-proxy-rs), F13 (NOR speed / zstd).

---

## 0. Ranked changes

"In target" = what the item contributes when the whole target set is applied (leave-one-out). "Alone today" = applied by
itself to the current build. The items interact, so the columns do not add up.

| # | Change | In target | Alone today | Risk | Basis |
|---|--------|-----------|-------------|------|-------|
| 1 | BT patch download at 3 Mbaud (flag on by default, or DT compatible `brcm,bcm4329-bt`) | **3.0-3.6 s** | 1-2 s (then item 2 gates) | Low | VERIFIED code, vendor script. INFERRED timing |
| 2 | Car/computer decision from the UDC state with 0.01 s clock (2 s after `configured`, not 5 s after udhcpd) | **2.5-3.0 s** | 0 (BT gates today) | Low (script) / Med (aa-proxy-rs gate patch) | VERIFIED logic |
| 3 | Rootfs `zstd -22`, 256K, `-no-fragments` (+`CONFIG_SQUASHFS_ZSTD=y`) | **2.0-2.5 s** | 2.5-3 s | Low-Med (kernel + rootfs reflash, in that order) | VERIFIED sizes. INFERRED A7 speed |
| 4 | Pre-read `/usr/bin/aa-proxy-rs` in the background | 0.7-0.9 s | **3-4 s** | Very low | VERIFIED 45/60 blocks touched. INFERRED rates |
| 5 | NOR `m25p,fast-read` at 49.5 MHz (= U-Boot's own rate) | 0.7-1.0 s | ~0.9 s | Low-Med (signal integrity, verify) | VERIFIED code/datasheet. INFERRED current clock |
| 6 | Initramfs UART window 1 s -> 0.2 s (+ `FEATURE_SH_READ_FRAC`) | 0.8 s | 0.8 s | Low | VERIFIED |
| 7 | Flat, ordered insmod list instead of `mod_load` | 0.5-0.8 s | 0.5-0.9 s | Low | VERIFIED 598 execs measured |
| 8 | Poll granularity 0.25 s -> 0.05 s | 0.2-0.4 s | 0.2-0.4 s | Very low | VERIFIED |
| 9 | Do not gate aa-proxy-rs on `ap_up`. Start dbus-daemon early. `performance` from the initramfs | 0-0.6 s | small | Low | VERIFIED order |
| 10 | USB side: `legacy = false` (HU-dependent) / run the AOA dance in parallel with the phone's Wi-Fi join (patch) | 0.7-1.5 s / 1.5-3 s | same | HU-dependent / Med | VERIFIED code order |
| 11 | Phone side: `bt_connect_max_delay_secs = 2`, daily phone first in `known_devices`, "Phone calls" allowed for the dongle | 0 when the phone is there. 3-5 s in edge cases | same | Very low | VERIFIED code |
| - | U-Boot `bootdelay=3` (out of brief scope: U-Boot fixed) | 3 s | 3 s | **High** | VERIFIED env value. INFERRED effect |

**Estimated result:** first BT page of the phone ~18.5 s -> ~9 s. "phone connected" (TCP accepted + HU accessory up)
~23.5-32 s -> ~14-22 s. The remaining time is U-Boot (~4.7 s, fixed) and the phone's own reconnect (~4-10 s).

---

## 1. Current timeline (estimated)

| From power-on | Phase | Basis |
|---|---|---|
| 0.0-0.4 | ROM, HAB check, DCD, U-Boot init | INFERRED |
| 0.4-3.4 | U-Boot autoboot countdown: update env `bootdelay = 3`, U-Boot 2015.04 has keyed autoboot ("Press SPACE to abort autoboot in %d seconds") | VERIFIED value (decrypted update env, mtd0+0x20000) and strings. INFERRED that it runs (no U-Boot UART capture exists) |
| 3.4-4.1 | `sf read 0x80800000 0x40000 0x304bf8` (3,165,176 B, fixed length) + 3 DCP head blocks | VERIFIED `norboot`. INFERRED speed |
| 4.1-4.4 | LZO self-decompression (5.97 MB Image) | INFERRED (KERNEL_AUDIT §1a) |
| 4.4-4.7 | kernel to `/init` with `quiet` | INFERRED: r1 dmesg 0.86 s, of which ~0.6 s was console replay (the r1/r2 gaps 0.28->0.63 s / 0.27->0.73 s sit in the first printk after console registration) |
| 4.7-6.0 | initramfs: identity, `bootslot_scan` x2, squashfs mount, **`read -t 1`**, slot write, switch_root | VERIFIED `initramfs/init:80` |
| 6.0-6.1 | rootfs `/init` -> busybox init -> rcS -> `board_early` -> `u2ac-aa start` (**T_u**) | INFERRED |
| T_u+0.25 | `/run/persist.loaded` seen (0.25 s poll) | VERIFIED |
| +0.25-1.2 | `mod_load hci_uart`: 484 external execs (MEASURED under qemu-user: 296 tr, 148 grep, 28 awk, 12 insmod) plus a shell fork per `$(...)`, ~0.9 MB of .ko read from xz squashfs | VERIFIED count. INFERRED 1-1.5 ms per exec on the A7 |
| +1.2-7.0 | BT setup at **115200**: 55,331 B patch = 4.8 s on the wire, +0.61 s fixed sleeps (hci_bcm.c:309 110 ms, btbcm.c 100+50+250+100 ms), +~217 command round trips | VERIFIED code + arithmetic |
| +1.2-2.4 | rfcomm, brcmfmac chain, sdhci (114 more execs measured), SDIO enumeration, 557 KB firmware -> wlan0 | VERIFIED counts. INFERRED (r2 dmesg: host -> `wl0` 0.28 s from RAM) |
| +2.5-3.9 | `ap_up`: hostapd, 20/40 scan of ch36/40, ENABLED poll, udhcpd, httpd, dropbear | VERIFIED order. INFERRED durations |
| +7.0-7.9 | `bt_up` remainder: btmgmt x2, dbus-daemon, bluetoothd, log poll | INFERRED |
| +7.9 | `computer_on_usb` returns at once: its 5 s window (from the udhcpd-ncm pid mtime, ~T_u+0.8) ended at ~+5.8-6.8 | VERIFIED logic |
| +7.9-11.7..12.8 | aa-proxy-rs exec to BT init: **45 of 60** 256K blocks touched (MEASURED, below) = ~4.0 MB compressed NOR + ~11.5 MB xz | VERIFIED touch count. INFERRED rates |
| ~18-19 | **first page of the phone** | sum |
| +4-10 | page + auth + HSP connect 1.5-3 s. Phone opens AA RFCOMM 0.5-2 s. WifiStart/Info. Phone joins Wi-Fi + DHCP 2-5 s. `WifiConnectStatus` | VERIFIED sequence (bluetooth.rs `send_params`). INFERRED durations |
| +1.5-3 | USB, **only after WifiConnectStatus**: `legacy` MTP stage -> HU AOA start -> 500 ms settle -> accessory gadget -> HU enumerates | VERIFIED main.rs order. INFERRED durations |
| **~23.5-32** | phone connected (TCP accepted, HU accessory up). Projection follows after the AA handshake | |

## 2. Target timeline (items 1-9, U-Boot unchanged)

| From power-on | Phase |
|---|---|
| 0.0-4.7 | unchanged (U-Boot, kernel) |
| 4.7-5.2 | initramfs with a 0.2 s window (-0.8 s) -> T_u ≈ 5.3 |
| T_u+0.05 | persist loaded (0.05 s poll). `state_restore`. dbus-daemon started in the background |
| +0.05-0.35 | 13 flat BT insmods (zstd + fast NOR make the .ko reads cheaper) |
| +0.35-1.5 | BT setup at 3 Mbaud (~1.1 s: 0.19 s wire + 0.61 s fixed + round trips) |
| +0.35-1.1 | 9 Wi-Fi insmods, SDIO, firmware -> wlan0. pre-read of aa-proxy-rs starts. `ap_up` in the background (AP ≈ +2.0-2.5) |
| +1.5-1.9 | btmgmt public-addr, bluetoothd |
| +2.5-3.0 | car decision (script variant, with the aa-proxy-rs gate patch aa-proxy-rs starts at +1.9 instead) |
| +2.5/3.0-3.3/4.0 | aa-proxy-rs (mostly page-cached) -> BT init |
| **~8.6-9.3** | **first page of the phone** (from ~18.5) |
| +4-10 | phone side (unchanged) |
| +1.5-3 | USB (`legacy = false`: +0.8-1.5, concurrency patch: hidden behind the phone's Wi-Fi join) |
| **~14-22** | phone connected (with `bootdelay` 0 as well: ~11-19) |

---

## 3. Findings and exact changes

### 3.1 BT patch at 115200 (rank 1)

- **Why it is slow (VERIFIED, kernel src `drivers/bluetooth/hci_bcm.c`).** `brcm,bcm43540-bt` matches
  `bcm4354_device_data = { .no_early_set_baudrate = true }` (1576-1602). `bcm_open` sets `hu->oper_speed` only
  `if (!no_early_set_baudrate && !use_autobaud_mode)` (508), so `hci_uart_setup` (hci_serdev.c 197-211) never switches to
  `max-speed` before `bcm_setup`, and `btbcm_initialize` downloads the patch at `init_speed = 115200` (bcm_proto 1307).
  The speed is raised only after the download (bcm_setup, `bcm_set_baudrate(oper_speed)`). The quirk came from
  "Bluetooth: hci_bcm: Disallow set_baudrate for BCM4354" (Chromebook BCM4354: no higher speed without patchram).
- **No DT property overrides it (VERIFIED).** `bcm_of_probe` reads only `brcm,requires-autobaud-mode`, `max-speed`,
  `brcm,bt-pcm-int-params` and the `host-wakeup` IRQ (1233-1243). The only DT lever is the **compatible**: every
  compatible without match data (`brcm,bcm4329-bt`, `-4330-bt`, `-4334-bt`, `bcm4335a0`) gets the early switch.
  `brcm,bcm4329-bt` is in the binding enum. The firmware name comes from the subversion (0x240f -> BCM4358A3, patch 0006),
  not from the compatible, so nothing else changes.
- **The 4358A3 ROM takes 3 Mbaud before the patch (VERIFIED).** Stock `attach_bluetooth.sh` (fingerprint scripts.txt:176):
  `brcm_patchram_plus --patchram .../BCM4358A3.hcd --baudrate 3000000 --use_baudrate_for_download ...`.
- **Fallback is benign (VERIFIED, hci_serdev.c 205-211):** if `0xfc18` fails, "Failed to set baudrate" is logged and the host
  stays at 115200, which is today's behaviour.
- **Change, step A (rootfs only, test first):** `touch /run/persist/u2ac-bt-earlybaud; u2ac-aa persist; reboot`, then
  `dmesg | grep -iE 'bcm|hci0|baud'` (no "Failed to set baudrate", "BCM4358A3 ... build" about 1 s after "BCM: chip id").
  Then make it the default in `u2ac-aa` `radio_up`:
  ```
  -    EB=; [ -e "$P/u2ac-bt-earlybaud" ] && EB=bcm_force_early_baud=1
  +    EB=bcm_force_early_baud=1; [ -e "$P/u2ac-bt-115200" ] && EB=     # opt-out flag
  ```
  **Step B (clean, next kernel flash):** `dts/radio-bcm4358.dtsi` `compatible = "brcm,bcm4329-bt";` (comment why), then
  drop patch 0007.
- **Saving:** BT setup ~5.8 s -> ~1.1 s (INFERRED round trips). **It only pays with 3.2:** with fast BT, the 5 s
  computer window becomes the gate.

### 3.2 Car-vs-computer window (rank 2)

VERIFIED (`u2ac-aa computer_on_usb`): it waits until `$(date +%s) - $(stat -c %Y /run/udhcpd-ncm.pid) >= 5`. Both clocks
have 1 s resolution, so the real window is 4-6 s, counted from udhcpd start (~T_u+0.8). Today BT finishes later, so it
costs nothing. After 3.1 it would hold aa-proxy-rs until ~T_u+5.8-6.8.

**Variant A (script, low risk):** a computer configures the gadget and activates the NCM data interface within about a
second. Decide from the UDC state (`/sys/class/udc/*/state`, VERIFIED strings "configured" / "not attached", udc/core.c
1839) with a centisecond clock:
```
cs() { read -r _u _ < /proc/uptime; _c=${_u#*.}; echo $(( ${_u%.*} * 100 + ${_c#0} )); }
computer_on_usb() {
    U=; for u in /sys/class/udc/*; do case $(readlink -f "$u") in */2184200.usb/*) U=$u ;; esac; done
    t=$(cs)
    until ip -4 addr show usb0 2>/dev/null | grep -q 192.168.50.2; do
        [ $(( $(cs) - t )) -ge 1000 ] && return 1; sleep 0.05; done
    t=$(cs); tc=
    until [ "$(cat /sys/class/net/usb0/carrier 2>/dev/null)" = 1 ]; do
        now=$(cs)
        [ -z "$tc" ] && [ "$(cat "$U/state" 2>/dev/null)" = configured ] && tc=$now
        if [ -n "$tc" ]; then [ $((now - tc)) -ge 200 ] && return 1      # configured, no NCM in 2 s: car
        else [ $((now - t)) -ge 150 ] && return 1; fi                    # never configured: no computer
        sleep 0.05
    done
    for _i in 1 2 3; do                                                  # unchanged from today
        arping -q -f -c 1 -w 1 -I usb0 192.168.50.100 > /dev/null 2>&1 && return 0
        ping -c 1 -W 1 192.168.50.100 > /dev/null 2>&1 && return 0
    done
    return 1
}
```
Risk: a slow Windows host on its first plug-in (driver install) is taken for a car. `u2ac-aa dev on` already covers that.

**Variant B (gate patch, medium):** take the decision off the critical path. aa-proxy-rs removes all gadgets at the top of
every main-loop iteration (main.rs `usb.init()`), but `wait_for_accessory_session` sweeps them again itself
(usb_functionfs.rs `teardown_active` + `sweep_stray_gadgets`, VERIFIED). A small patch (env `AA_DEFER_USB_INIT=1`: skip
the first `usb.init()`. Env `AA_USB_GATE=/run/u2ac-usb.go`: poll for that file every 50 ms at the top of
`enable_usb_if_present`) lets u2ac-aa start aa-proxy-rs as soon as BT is up. It then runs `computer_on_usb` in parallel:
car -> `touch /run/u2ac-usb.go`, computer -> kill the `aa_run` loop. The USB step comes only after the phone's
`WifiConnectStatus` (≥4 s later), so the gate is always open in time in the car. Extra saving over A: ~0.3-0.6 s.

### 3.3 aa-proxy-rs page-in (ranks 3, 4, 5)

- **MEASURED** (qemu-user, the current rootfs, `/proc/<pid>/pagemap` of the file mappings, run until the BT-init retry
  loop): file 15,712,292 B = 60 blocks of 256K. Touched: **45 blocks (75%)**. At 128K granularity 79/120, at 64K 122/240,
  at 1M 14/15. Fault-around (64 KiB) inflates only the 64K figure. More code runs after BT init, so 45 is a lower bound.
  `webserver = ""` changes it to 44, so it is not a boot lever.
- **Cost today (INFERRED):** ~4.0 MB compressed over the NOR (~2.8 MB/s, §3.4) ≈ 1.4 s, plus ~11.5 MB of kernel xz at
  4-6 MB/s ≈ 2-3 s. The A7 rate is scaled from Bootlin's 5.4 MB/s kernel xz on a 1 GHz A9. QSPI reads are PIO
  (`memcpy_fromio`, VERIFIED spi-fsl-qspi.c 581-586), so NOR time is CPU time too.
- **Pre-read (rank 4).** Today the BT download leaves ~5 s of near-idle CPU, which hides all of it. Add in `start()` once
  the modules are in:
  `nice -n 10 cat /usr/bin/aa-proxy-rs > /dev/null 2>&1 &`
  The cost is 15.7 MB of reclaimable page cache. Use nice 10, not 19: squashfs here is `DECOMP_SINGLE` (one mutex-held
  decompressor, VERIFIED config), so a starved pre-reader would hold other faults for up to a block.
  `CONFIG_SQUASHFS_DECOMP_MULTI` (2 decompressors on UP, decompressor_multi.c:29) removes that, optional.
- **zstd (rank 3), MEASURED image sizes** (same tree, `mksquashfs 4.6.1 -all-root`, partition 12,976,128 B):

  | variant | bytes | fits |
  |---|---:|---|
  | xz `-Xbcj arm -b 256K` (today, reproduces `rootfs.img` exactly) | 10,321,920 | yes |
  | xz 256K `-no-fragments` | 10,448,896 | yes |
  | xz 1M / 128K / 64K | 9,797,632 / 10,653,696 / 10,989,568 | yes |
  | **zstd -22, 256K** | **12,128,256** | yes (848 KB free) |
  | **zstd -22, 256K, `-no-fragments`** | **12,255,232** | yes (721 KB free) |
  | zstd -22 1M / zstd -19 128K / zstd -15 128K | 11,595,776 / 12,435,456 / 12,562,432 | yes |
  | gzip -9 256K / lzo -9 / lz4hc | 13,524,992 / 14,585,856 / 15,683,584 | **no** |

  The board.env comment "zstd did not fit (15.0 MB vs 12.4 MB)" is stale. Decompressing aa-proxy-rs on the arm64 host:
  xz 203 ms, zstd 24 ms (8.5x), gzip 84 ms, lz4 9 ms (MEASURED). On the A7, INFERRED zstd ≈ 30-60 MB/s vs xz 4-6 MB/s.
  zstd also cuts later page-cache refault stalls during a session (~20-40 ms per xz block).
  **Change:** `kernel/base.fragment` `CONFIG_SQUASHFS_ZSTD=y` (keep `SQUASHFS_XZ`, KERNEL_AUDIT puts it at ~18-25 KB,
  and the zImage has 358,093 B spare: 2,799,883 of 3,157,976). Then `board.env`:
  `SQUASHFS_COMP=zstd` and `SQUASHFS_OPTS="-Xcompression-level 22 -b 262144 -no-fragments"`.
  Flash order: **kernel first** (it still mounts the xz rootfs), then the rootfs.
- **Fragments (fold into 3).** VERIFIED: 16 fragment blocks. "always-use-fragments" off, so only files < 256 KiB are in
  them. `SQUASHFS_FRAGMENT_CACHE_SIZE=3`. A packing simulation reproduces the 16 fragments (3.05 MB of small files). The
  boot touches 52 of those files (1.72 MB) in 12 fragments: ≥12, and ~19 with the 3-entry cache, full 256 KiB
  decompressions (INFERRED 3-5 MB of xz ≈ 0.4-1 s over the boot). Seven of them sit in the module-loading path.
  `-no-fragments` (+127 KB) removes this. If staying on xz, use it too (`-Xbcj arm -b 262144 -no-fragments`).
- **Block size:** keep 256K. 1M shrinks xz but makes every random fault decompress 1 MB. 64K/128K cut aa-proxy-rs work
  only ~15-30% and cost space.
- **Thumb-2 aa-proxy-rs (optional, INFERRED 0.2-0.4 s after zstd):** `RUSTFLAGS="... -C target-feature=+thumb-mode"` or
  the `thumbv7neon-unknown-linux-musleabihf` target. Text ~20-30% smaller, which means fewer blocks. With xz use
  `-Xbcj armthumb` (decoder already in the kernel). Needs a build test.

### 3.4 NOR read speed (rank 5)

- **Today (VERIFIED code, INFERRED clock):** DT `spi-max-frequency = <29000000>`, 1-bit, no `m25p,fast-read`, so READ
  0x03 (core.c 3122-3135). imx6ul QSPI has `QUADSPI_QUIRK_4X_INT_CLK` (spi-fsl-qspi.c 248), so it requests
  29 MHz × 4 = 116 MHz. The `qspi1_sel` mux is `CLK_SET_RATE_NO_REPARENT` (clk.h 397) and the podf divider rounds down,
  so the root becomes 396/4 = 99 MHz and SCK ≈ **24.75 MHz**. The stock kernel left `qspi1` at **198 MHz**
  (fingerprint clk.txt:180-182), i.e. SCK 49.5 MHz, the rate U-Boot also uses (INFERRED).
- **Per-op overhead (VERIFIED):** mtdblock reads **one 512-byte sector per `mtd_read`** (mtd_blkdevs.c 68,
  mtdblock.c 234). Each op reprograms the LUT, reads the AHB window and resets the AHB buffer with `udelay(1)`
  (spi-fsl-qspi.c 671-731). INFERRED effective rate: ~2.8 MB/s today, ~5.2 MB/s at 49.5 MHz fast-read.
- **Datasheet (VERIFIED, MX25L12805D rev 1.2):** x1 only. READ to **33 MHz**, FAST_READ to **50 MHz**. The MX25L12835F
  (DTS comment and top README) is faster. JEDEC c2 20 18 is shared, so the probe cannot tell them apart. Patch 0004 skips
  SFDP.
- **Change (dts/imx6ull-ccpa-baseline.dts `flash@0`):**
  ```
  -		spi-max-frequency = <29000000>;
  +		/* x4 internal clock: qspi1 198 MHz (396 MHz PFD2 / 2, the stock/U-Boot rate) = 49.5 MHz SCK.
  +		 * FAST_READ is rated 50 MHz on MX25L12805D (READ only 33 MHz). */
  +		spi-max-frequency = <49500000>;
  +		m25p,fast-read;
  ```
  The divider never exceeds the request, so SCK ≤ 49.5 MHz whatever parent U-Boot leaves (VERIFIED rounding).
  **Verify:** `devmem 0x020C401C 32` (CSCMR1: QSPI1_CLK_SEL bits 9:7, QSPI1_PODF bits 28:26, before and after). After
  `echo 3 > /proc/sys/vm/drop_caches`, run `time dd if=/dev/mtdblock3 of=/dev/null bs=64k count=160` and
  `dd if=/dev/mtdblock3 bs=4096 count=2520 | sha256sum` 5x against the image's own sha256 (10,321,920 B = 2520 × 4096).
  A bad sample point shows up as a mismatch or as SQUASHFS errors, then fall back. No brick path: U-Boot reads the kernel
  with its own settings, and recovery runs from RAM.
- **Quad 1-1-4: not recommended now.** About 0.3-0.5 s more on the critical path, but HIGH risk. The 12805D has no quad
  mode at all. It needs the chip marking confirmed as 12835F, WP#/HOLD# (pins 3/7) traced to QSPI_A_DATA02/03 (DT muxes
  them, VERIFIED qspigrp), a U2AC-only flash_info entry with `SPI_NOR_QUAD_READ` and the non-volatile QE write
  (Macronix SR bit 6, macronix.c 72). A wrong guess gives an unreadable rootfs.

### 3.5 Module loading (rank 7)

MEASURED (qemu-user, real `modules.dep`, the shipped `radio-lib.sh`): `mod_load` runs **598 external execs** (hci_uart 484,
rfcomm 32, brcmfmac 20, wcc 17, sdhci_esdhc_imx 45), plus a shell fork per command substitution. The busybox shell has
`FEATURE_SH_NOFORK`/`PREFER_APPLETS` off (VERIFIED busybox-full .config), so every `tr`/`grep`/`sleep` is fork+exec.
Replace with fixed lists (order from modules.dep, VERIFIED), falling back to `mod_load`:
```
M=/lib/modules/$(uname -r)/kernel
ins() { for k in $1; do insmod "$M/$k.ko" 2>/dev/null; done; }          # EEXIST from autoload is fine
ins "crypto/crypto crypto/crypto_algapi crypto/kpp crypto/ecc crypto/ecdh_generic lib/crypto/libcryptoutils
     lib/crypto/libaes lib/crc/crc16 net/bluetooth/bluetooth drivers/bluetooth/btbcm lib/crc/crc-ccitt"
insmod "$M/drivers/bluetooth/hci_uart.ko" $EB || mod_load hci_uart $EB || return 1       # BT patch starts here
ins "net/bluetooth/rfcomm/rfcomm drivers/mmc/core/mmc_core net/wireless/cfg80211
     drivers/net/wireless/broadcom/brcm80211/brcmutil/brcmutil"
insmod "$M/drivers/net/wireless/broadcom/brcm80211/brcmfmac/brcmfmac.ko" feature_disable=0x10 || mod_load brcmfmac feature_disable=0x10 || return 1
ins "drivers/net/wireless/broadcom/brcm80211/brcmfmac/wcc/brcmfmac-wcc drivers/mmc/host/sdhci
     drivers/mmc/host/sdhci-pltfm drivers/mmc/host/cqhci drivers/mmc/host/sdhci-esdhc-imx"   # host LAST (wcc first)
```
Better long term: have build.sh emit these lists from modules.dep after `depmod`. **Built-in radios: no.** The radio
modules are 972,979 B text + 19,729 B data (MEASURED), ≈ 510 KB of LZO, which does not fit the 358 KB spare. Built-in
brcmfmac would also probe before the rootfs holds its firmware, and it would undo the radios-off-at-boot recovery design.
After the flat list, built-in would save only ~0.2-0.4 s.

### 3.6 Initramfs UART window (rank 6)

`read -t 1` (init:80) is a fixed 1 s. **Trap (VERIFIED):** the recovery busybox has `# CONFIG_FEATURE_SH_READ_FRAC is not
set`. Its `read -t 0.2` returns "invalid timeout" (shell_common.c 96-99), which would silently drop the window. Change:
add `FEATURE_SH_READ_FRAC` to `common/busybox/recovery.applets`, then `if read -t 0.2 _ < /dev/console; then` and the
message "switching in 0.2 s, hold Enter on the UART for recovery". Autorepeat (~30 Hz) beats 0.2 s after the drain at
line 77. `reboot-recovery` and the 3-failure slot rule still cover the rest. Optional, same file: write `performance` to
`cpu0/cpufreq/scaling_governor` right after the mounts (u2ac-aa switches to ondemand later, set ondemand in the recovery
branch). INFERRED 0.1-0.2 s.

### 3.7 Kernel init

`quiet` is in (VERIFIED DTS). Nothing else on the kernel side is worth much. No deferred probes appear in the r1/r2 logs,
and the radios are modules, so async probe buys nothing on UP. The spi-nor probe itself takes 1.4 ms (r2). `lpj` is not
needed. `CONFIG_KERNEL_LZ4` now fits (≈ +5%, ~2.95 MB < 3,157,976, KERNEL_AUDIT measured +167 KB when the spare was
30 KB) for about -0.1 s (INFERRED). Low priority.

### 3.8 hostapd and the AP

VERIFIED (hostapd 2.12 `hw_features.c` 621-658): on 5 GHz the 20/40 check scans only the affected channels (36/40), and
it is skipped only by `no_pri_sec_switch`, which has no config key. INFERRED 0.1-0.3 s on brcmfmac. Instead of patching
hostapd, take the AP off the critical path. aa-proxy-rs needs only wlan0's MAC (`init_wifi_config`, VERIFIED main.rs
464-494. The IP falls back to `wlan_subnet.1` = 10.0.0.1). The phone joins Wi-Fi ≥3 s after paging starts. **Hazard
(VERIFIED):** if wlan0 is missing, `init_wifi_config` fails, `wifi_config = None` and the BT handshake is skipped
entirely (main.rs 1260). Keep the wlan0 wait. Change in `start()`: `( ap_up && say "AP up" || say "AP did not come up" ) &`
and `bt_up` in the foreground.

### 3.9 dbus-daemon, bluetoothd, polls (ranks 8, 9)

- Every wait polls at 0.25 s (persist, wlan0, hci0, mgmt index, bluetoothd log, hostapd_cli): avg ~0.12 s each on the
  path. Use `sleep 0.05` with 5x the counts (busybox sleep takes fractions: FANCY_SLEEP=y).
- `state_restore` does not need the radios. Run it right after `persist.loaded`, then start `dbus-daemon --system --fork`
  there, parallel to the BT download (machine-id comes from `state_restore`). INFERRED 0.1-0.2 s.
- Optional (INFERRED 0.3-0.5 s, needs a test): start bluetoothd early with `[Policy] AutoEnable=false` in
  `/etc/bluetooth/main.conf`. aa-proxy-rs powers the adapter itself (bluetooth.rs `set_powered(true)`, VERIFIED). The
  public-addr step must still come before that power-on.
- aa-proxy-rs retries BT init every **1 s** if the adapter is not on D-Bus yet (main.rs ~994, VERIFIED). Start it after
  the bluetoothd "management interface" line as today, or patch the retry to 200 ms.

### 3.10 aa-proxy-rs startup and the USB side (rank 10)

VERIFIED from aa src: config parse is negligible. `startup_delay = 0`. There are no fixed sleeps before BT init. Then come
BT init, companion profiles, HSP profile, `usb.init()`, the connect loop and `send_params`. `send_params` waits for
`WifiStartResponse` **and `WifiConnectStatus`** (bluetooth.rs 6395-6433), and only after that is the USB gadget started
(main.rs 1316-1327). So the HU-side AOA dance is **serialized after the phone's Wi-Fi join**.
- `legacy = true`: the MTP stage waits up to 6 s for ACCESSORY_START, tries twice, then settles 1 s
  (usb_functionfs.rs 352-405). **If the car never sends ACCESSORY_START, that is ~14 s per connection.** Check
  `/run/log/aa-proxy-rs.log` for "no ACCESSORY_START seen in MTP stage". Try `  legacy = false` on this car: it skips one
  enumeration plus 500 ms (INFERRED 0.7-1.5 s, HU-dependent).
- Concurrency patch (medium, INFERRED 1.5-3 s): in the main loop, `tokio::join!` the `enable_usb_if_present` future with
  `aa_handshake` (they borrow different objects). The HU then waits in accessory mode for the phone. Upstream's
  `change_usb_order` already ships a longer HU-first gap, so HUs tolerate it, but test on this car.

### 3.11 Phone side and reconnect settings (rank 11)

VERIFIED (bluetooth.rs 419-430, 6040-6090, 6264-6360, main.rs 1262): with `connect = "00:00:00:00:00:00"` only the
`known_devices` entries are dialled (persisted, done), **in file order, starting at index 0 every boot**. Each round
makes 3 `connect_profile(HSP_AG)` attempts per device (≤20 s each). Between rounds the backoff starts at 1 s and doubles
up to `bt_connect_max_delay_secs` (5 here). `quick_reconnect` only acts after a session (`profile_connected`), so it has
no cold-boot effect. `advertise` does not matter when the dongle is the initiator.
- `  bt_connect_max_delay_secs = 2`: cuts the worst-case gap from 5 s to 2 s when the phone shows up late (driver still
  walking up). No cost otherwise.
- Keep the daily phone **first** in `/etc/aa-proxy-rs/known_devices` (or alone). An absent phone listed first costs one
  page timeout (~5.1 s, INFERRED BlueZ default) every boot.
- The dongle dials the phone's **HSP AG**. If "Phone calls" is switched off for AutoKit in the phone's BT settings
  (tempting, to keep calls on the car), the dial fails and only a manual tap connects. Check this on the Pixel.
- Pixel timing (INFERRED, measure): page + auth + SDP + RFCOMM 1-3 s. AA RFCOMM 0.5-2 s. Wi-Fi join on the 5 GHz
  ch36 non-DFS channel + DHCP 2-5 s. TCP. The `read_message` stage logs carry ms elapsed times.
  `WifiConnectStatus`'s elapsed time is the phone's Wi-Fi join. The car's own boot can also dominate: note when the HU
  first enumerates the gadget.

### 3.12 U-Boot (outside the brief: U-Boot is fixed)

The decrypted update env (mtd0+0x20000) holds `bootdelay=3`. U-Boot 2015.04 here is built with keyed autoboot. If the
runtime env (0x30000, a different encrypted format) matches, ~3 s of every boot is a countdown. Changing it means
re-encrypting the update env (format and key are in `stage_kernel.py`) in the U-Boot partition and erasing env:
**HIGH risk**, SOIC-clip recovery only. First measure power-on to the initramfs banner on the Pi and subtract the
kernel uptime.

### 3.13 Evaluated and rejected

Radios built in (size, firmware, design, §3.5). `SH_NOFORK`/`PREFER_APPLETS` busybox (would shadow `/usr/sbin/passwd`
with the applet, VERIFIED collision). `webserver = ""` (44 vs 45 blocks). lz4/lzo/gzip rootfs (do not fit, MEASURED).
HT20 to skip the scan (off path after §3.8). FastConnectable (dongle-initiated reconnect). A multi-sector mtdblock read
patch (~8% at fast-read, not worth a kernel patch).

---

## 4. Proposed `u2ac-aa start()` shape (sketch, untested)

```
start() {
    : > "$LOG"; say start; <governor performance, vm sysctls, /tmp remount as today>
    n=0; until [ -e /run/persist.loaded ] || [ $n -ge 200 ]; do sleep 0.05; n=$((n + 1)); done
    state_restore
    dbus-daemon --system --fork; <oom -500>
    radio_up_flat                                  # §3.5: BT list -> hci_uart (EB default on) -> Wi-Fi list; wlan0 wait 0.05 s
    nice -n 10 cat /usr/bin/aa-proxy-rs > /dev/null 2>&1 &     # §3.3
    ( ap_up && say "AP up" || say "AP did not come up" ) & app=$!    # §3.8
    bt_up || say "D-Bus/BlueZ did not start"       # mgmt-index + log polls at 0.05 s; no dbus start inside
    <dev / computer_on_usb (§3.2 A) / aa_run as today>   # or §3.2 B: aa_run first, decision in parallel
    wait $app
    <ondemand tuning, saver loop as today>
}
```

## 5. Measure on the unit (read-only), before and after each step

```
dmesg | grep -iE 'bcm|hci0|baud|brcmf|squashfs'          # BT setup span, firmware, decompression errors
grep . /run/log/u2ac-aa.log                              # uptime-stamped phases
grep -E 'Trying to connect|Successfully connected|RFCOMM|Sending parameters|TCP server|USB Manager|stage' \
     /run/log/aa-proxy-rs.log                            # phone and HU phases (ms timestamps; note `date` vs uptime once)
devmem 0x020C401C 32                                     # QSPI clock source/divider (§3.4)
echo 3 > /proc/sys/vm/drop_caches; time cat /usr/bin/aa-proxy-rs > /dev/null    # NOR + decompression cost
echo 3 > /proc/sys/vm/drop_caches; time dd if=/dev/mtdblock3 of=/dev/null bs=64k count=160   # raw NOR
grep -A3 aa-proxy-rs /proc/$(pidof aa-proxy-rs)/smaps | grep Rss                 # on-unit touched text
bootchartd (in the image) for one cold boot                                      # full chart
```
Power-on to kernel: start a timestamped capture of the Pi UART, apply power, take the initramfs banner time, and
subtract the kernel's uptime at `/init` (~0.3 s). That splits U-Boot (incl. any countdown) from Linux.

## Sources

Local: `ocbm/baseline/arm-imx6ul-u2ac/{initramfs/init,board.env,dts/*.dts*,kernel/*.fragment,patches/000{4,6,7}*,
rootfs/usr/sbin/u2ac-aa,rootfs/lib/baseline/radio-lib.sh,rootfs/usr/share/u2ac/*}`, `ocbm/baseline/common/{rootfs/etc/init.d/rcS,
rootfs/init,rootfs/etc/inittab,shared/{mtd.sh,net-up,ssh-up,persist},busybox/recovery.applets}`, `ocbm/baseline/build.sh`,
`boot1/{dmesg.txt,r2_wifi_dmesg.txt}`, `qemu-final-7.2.15.log`, `qemu-r3-7215.log`, `out-7.2.15/{build-rootfs.log,nousb/*}`,
`aa-build/{build.sh,out/aa-proxy-rs}`, `../fingerprint_20261125/fp/{scripts.txt,clk.txt,dmesg.txt}`, update env decrypted
from `../backup/pre_mainline_20261126/mtd0.bin` with `stage_kernel.py` `read_env` (values only, nothing written).
Kernel src: `drivers/bluetooth/{hci_bcm.c,hci_serdev.c,btbcm.c}`, `drivers/spi/spi-fsl-qspi.c`, `drivers/mtd/{mtd_blkdevs.c,
mtdblock.c,spi-nor/core.c,spi-nor/macronix.c}`, `drivers/clk/imx/{clk-imx6ul.c,clk.h}`, `fs/squashfs/{file.c,block.c,
decompressor_multi.c,Kconfig}`, `drivers/usb/gadget/udc/core.c`, `arch/arm/boot/dts/nxp/imx/imx6ul.dtsi`,
`Documentation/devicetree/bindings/net/bluetooth/brcm,bluetooth.yaml`, `kbuild/nousb/.config`.
Userspace src (u2ac-build): hostapd 2.12 `src/ap/hw_features.c`. busybox 1.38.0 `shell/shell_common.c` and both `.config`s.
aa src: `src/{main.rs,bluetooth.rs,usb_functionfs.rs,proxy.rs,config.rs}`, `Cargo.toml`.
Web: kernel patch "Bluetooth: hci_bcm: Disallow set_baudrate for BCM4354"
(https://lore.kernel.org/linux-bluetooth/20191107232713.48577-2-abhishekpandit@chromium.org/). Bootlin ARM xz kernel
decompression benchmarks (https://bootlin.com/blog/arm-xz-kernel-decompression-benchmarks/). Macronix MX25L12805D
datasheet rev 1.2, Table 6 (https://www.mikrocontroller.net/attachment/618703/MX25L12805D__3V__128Mb__v1.2.pdf).
