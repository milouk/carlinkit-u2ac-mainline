# U2AC kernel config audit (Linux 7.2.15 / 7.3.6, i.MX6ULL, 128 MiB, 16 MiB NOR)

Audited 2026-11-26 (read-only, no device or build was touched). Inputs: `kernel-7.2.15.config`, `kernel-7.3.6.config`,
`ocbm/baseline/arm-imx6ul-u2ac/kernel/*.fragment`, the board DTS + `radio-bcm4358.dtsi`, the build logs and output images in
`out-7.2.15/`, `out-7.3.6/`, `boot1/` (r1 dmesg and /proc), and the kernel's own Kconfig and driver sources for v7.2.15 and v7.3.6
(fetched from git.kernel.org stable).

Labels: **VERIFIED** = read in the Kconfig/source/config/dmesg or measured on the built artefacts. **INFERRED** = reasoned or
scaled from published numbers. Needs a build or an on-device check. "LZO bytes" = bytes saved or added in the LZO zImage.

The 7.2.15 and 7.3.6 `.config` files differ only in the sysctl symbol rename (`PROC_SYSCTL` became part of `SYSCTL`) and
symbols that appear in one series only. Every recommendation below applies to both series unless it says otherwise. I diffed
`Kconfig.preempt` and `arch/arm/Kconfig` between the two series: there are no changes that matter here.

---

## 0. Headline findings (read these first)

| # | Severity | Finding | Fix |
|---|---|---|---|
| F1 | **CRITICAL** | The rootfs is built with `mksquashfs -Xbcj arm`, but the kernel has `# CONFIG_XZ_DEC_ARM is not set`. **MEASURED:** 67 of the 126 XZ streams in `rootfs.img` (both 7.2.15 and 7.3.6) carry the ARM BCJ filter (filter id 0x07), and the superblock's comp-opts flags are 0x8 = arm. **VERIFIED** in `lib/xz/xz_dec_stream.c`: without `XZ_DEC_BCJ`, any block that uses a BCJ filter returns `XZ_OPTIONS_ERROR`. `squashfs_xz_comp_opts()` ignores the flags, so the mount succeeds and the reads fail later. About half the rootfs data is therefore unreadable. That half includes the ARM-mode 15.7 MB `aa-proxy-rs` and the `.ko` files. QEMU never caught this because spi-nor fails there (-110), so the squashfs was never mounted. The cause is the `merge_config.sh -n` flow, which answers n to every visible `default y` prompt you do not name. | `CONFIG_XZ_DEC_ARM=y` and `CONFIG_XZ_DEC_ARMTHUMB=y` (about +1 KB). Optionally also use `-Xbcj arm,armthumb`. |
| F2 | HIGH | **Thermal throttling is inert.** `imx6q-cpufreq` registers its cooling device through `CPUFREQ_IS_COOLING_DEV`, which calls `of_cpufreq_cooling_register()`. That call needs `CPU_FREQ_THERMAL`, which needs `CPU_THERMAL`, which needs `THERMAL_OF`, and all three are off. `imx_thermal` skips its legacy path because the cpu0 node has `#cooling-cells`. Result: no cooling device is bound, the passive trip (Tmax−10 °C) does nothing, and the only protection is the critical trip (Tmax−5 °C). That trip triggers `orderly_poweroff`, and with no power-off driver (`# CONFIG_POWER_RESET is not set`) the board halts. **VERIFIED** in `imx_thermal.c`, `imx6q-cpufreq.c`, `drivers/thermal/Kconfig` and the `imx6ul.dtsi` cpu0 node. | `CONFIG_THERMAL_OF=y`, `CONFIG_CPU_THERMAL=y`, `CONFIG_CPU_FREQ_THERMAL=y` (about +5-8 KB). |
| F3 | HIGH (size) | The ~37 KB headroom problem comes from `CONFIG_KERNEL_LZO`. This board profile changed it from upstream's `KERNEL_XZ`. The comments in `base.fragment` and `base-optional.fragment` still say "XZ kernel". **MEASURED** (the 7.2.15 piggy decompressed and recompressed with the kernel's exact `xz_wrap.sh` flags): LZO payload 3,083,754 B, XZ 1,990,264 B (−1.09 MB), gzip 2,845,389 B (−238 KB), LZ4 3,251,082 B (+167 KB, does not fit). Also, **`CONFIG_THUMB2_KERNEL` is NOT set** (`ARM_THUMB=y` only lets the kernel run Thumb *userspace*). | See §1. In short: a Thumb-2 kernel plus dropping the recovery `sftp-server` buys roughly 280-430 KB with no boot-time cost. |
| F4 | MED (boot) | 0.63 s of the 0.86 s from kernel start to `/init` is UART output. **VERIFIED** arithmetic: 7,273 B of level ≤6 messages at 115200 8N1 (11,520 B/s). This matches the r1 timestamp gaps, where printk stalls behind the polled console. | Add `quiet` to the DT bootargs, or set `CONFIG_CONSOLE_LOGLEVEL_DEFAULT=4`. |
| F5 | MED (robustness) | `WATCHDOG_HANDLE_BOOT_ENABLED=y`, but nothing in recovery or the rootfs ever opens `/dev/watchdog` (**VERIFIED**: inittab, rcS, shared scripts). If U-Boot left WDOG1 running, the kernel pings it forever, and a userspace hang never resets the unit. | Add a rootfs-only feeder and `CONFIG_WATCHDOG_NOWAYOUT=y`. Do **not** set an open timeout (see §5). |
| F6 | LOW | `CONFIG_USB_GADGET_VBUS_DRAW=2` is the default `MaxPower` of every configfs config (**VERIFIED** `configfs.c:739`). No script writes `MaxPower`, so the NCM and ACM gadgets tell the car they draw 2 mA. | `CONFIG_USB_GADGET_VBUS_DRAW=500` (0 bytes). |
| F7 | LOW | `CONFIG_CPUFREQ_DT=y` (+ `PLATDEV`) is dead code. `imx6ull.dtsi` uses v1 `operating-points`, and the platdev allowlist only covers imx27/51/53 (**VERIFIED** `cpufreq-dt-platdev.c`). | Remove it (−2-3 KB). |

**Systemic hazard (process).** `merge_config.sh -n` sets to n every *visible* `default y` prompt that is not named. That is how F1,
F2 (`THERMAL_OF` defaults to y), `ARM_PATCH_IDIV` (defaults to y) and `HW_RANDOM_IMX_RNGC` came to be off. To catch the next
one, run the same fragments once through `merge_config.sh -m` + `olddefconfig` (the non-`-n` flow) and compare with
`scripts/diffconfig`. Every `y -> n` line is a silent drop you should decide on explicitly.

**Budget reference.** `build.sh` checks against `KERNEL_MAX = 0x302fd8 = 3,157,976` (the shared CCPA budget). Against that cap,
the 7.2.15 image has 30,489 B spare and 7.3.6 has 11,849 B. This unit's U-Boot actually reads `0x304bf8 = 3,165,176`, which adds
7,200 B. The U-Boot read length is fixed (`kernel_len`), so a smaller image does **not** load faster (VERIFIED, README/board.env).
Boot time changes only through decompression time.

---

## 1. Size wins (to buy headroom)

How I measured: I extracted the LZO piggy from `ccpa-baseline-bcm4358.zimg` (lzop stream at offset 17,480) and decompressed it
with a pure-Python LZO1X. The Image is 5,965,120 B (7.2.15) and 6,001,344 B (7.3.6). It contains the 856,736 B recovery cpio.
I then recompressed the Image with gzip -9, the kernel's exact xz flags (`--arm --lzma2=lp=2,lc=2,dict=128MiB`), lzma -9 and
lz4 -l. Per-file LZO cost is estimated as lz4 size × 0.9485, which is the LZO/LZ4 ratio measured on the whole Image.

### 1a. Compressor choice (biggest lever), VERIFIED sizes, INFERRED times

| `CONFIG_KERNEL_*` | payload 7.2.15 | payload 7.3.6 | Δ vs LZO | extra decompression time (A7 @ 528-792 MHz) |
|---|---:|---:|---:|---|
| `LZO` (current) | 3,083,754 | 3,102,394 | 0 | ~0.25-0.35 s total |
| `GZIP` | 2,845,389 | 2,862,239 | **−238 KB** (~−235 KB after the larger stub) | +0.45-0.75 s |
| `XZ` | 1,990,264 | 2,000,348 | **−1.09 MB** (~−1.08 MB after the stub) | +1.6-2.6 s |
| `LZMA` | 2,100,862 | - | −983 KB | slower than XZ: never pick it |
| `LZ4` | 3,251,082 | - | **+167 KB: does not fit** | −0.1 s |

The times are scaled from Bootlin's measurements: OMAP4 Cortex-A9 at 1 GHz, 7.0 MB Image, lzo 0.16 s, gzip 0.50 s, xz 1.30 s.
I scaled them by Image size, clock, and A7-vs-A9 IPC (~0.76×). ARM32 has no `HAVE_KERNEL_ZSTD` (VERIFIED in the config).
Recommendation: keep LZO if Tier A + B below are enough. `GZIP` is the cheap fallback (~0.5 s). `XZ` is the "never think about
size again" option at about +2 s. To measure: time on the UART from U-Boot's `Starting kernel` to the first kernel line (the
kernel's own timestamps start after decompression).

### 1b. Config and initramfs removals, ranked by value/risk

| Tier | Change | Est. LZO bytes | Basis | Risk |
|---|---|---:|---|---|
| A | **Drop `/usr/libexec/sftp-server` from the recovery initramfs.** Not Kconfig: `initramfs.list` / RECOVERY_SSH. | **−~127 KB** | MEASURED (197,840 B raw, lz4 133,583 B) | Low. The README flow already uses `scp -O`. sftp clients and OpenSSH ≥9 scp without `-O` stop working in recovery. |
| A | Prune `status = "disabled"` nodes from the appended DTB with `/delete-node/` (nand-controller, both FECs, 3 SAI, 4 ECSPI, unused UARTs, can, lcdif, pxp …). | **up to −9,222 B** (raw, the DTB is not compressed) | MEASURED: 41 top-level disabled nodes = 9,222 B of 26,199 | Low. Don't delete nodes whose labels other nodes reference (dtc errors out). Keep `usbotg1` for the usbhost variant. |
| A | `# CONFIG_SQUASHFS_ZSTD is not set` (the rootfs is xz, the OCBM overlay is a gzip tar unpacked in userspace, VERIFIED) | −18-25 KB | INFERRED (lib/zstd decompress + xxhash) | None |
| A | `# CONFIG_SYSVIPC is not set` | −10-15 KB | INFERRED | Low. No syslogd is started (dropbear logs with `-E`). dbus, BlueZ, hostapd, glib and tokio don't use SysV IPC. |
| A | `# CONFIG_GPIO_SYSFS is not set` + `# CONFIG_GPIO_CDEV is not set`, and remove `CONFIG_GPIO_SYSFS_LEGACY=y` from `base-optional.fragment`. `GPIO_SYSFS` *selects* `GPIO_CDEV` (VERIFIED), so both must go. | −10-14 KB | INFERRED. No users in scripts or `aa-proxy-rs` strings (VERIFIED by grep). GPIOs are used only through DT (regulator, leds, serdev). | Low. You lose ad-hoc `/sys/class/gpio` debugging. |
| A | `# CONFIG_CPUFREQ_DT is not set` | −2-3 KB | VERIFIED dead | None |
| A | `CONFIG_PARTITION_ADVANCED=y` (MSDOS/EFI then drop out). nousb variants only. `usb-host.fragment` turns them back on. | −3-5 KB | VERIFIED mtdblock sets `GENHD_FL_NO_PART` | None |
| A | `# CONFIG_CPU_FREQ_GOV_POWERSAVE is not set`, `# CONFIG_CPU_FREQ_STAT is not set` | −1-3 KB | INFERRED | You lose `time_in_state` |
| B | **`CONFIG_THUMB2_KERNEL=y`** (VERIFIED available: `CPU_V7 && !CPU_V6 && !CPU_V6K`, selects `ARM_UNWIND`, which is already on). The old `THUMB2_AVOID_R_ARM_THM_JUMP11` workaround no longer exists. | **−150-300 KB** | INFERRED from published raw-size reductions of 9-15%. Thumb code compresses a bit worse. One build tells. | Low-med: needs one build + hardware boot. Mainline-supported. Modules become Thumb-2 too. Perf roughly neutral (denser I-cache). |
| B | `CONFIG_PREEMPT_VOLUNTARY=y` (replaces `CONFIG_PREEMPT=y`). On UP this also switches to `TINY_RCU`/`TINY_SRCU` (VERIFIED `kernel/rcu/Kconfig`) and drops preempt_count from every lock site. | −30-60 KB | INFERRED | See §2: slightly worse worst-case latency. |
| C | `# CONFIG_IPV6 is not set`, and **delete** the `# CONFIG_IPV6_SIT is not set` line or the strict check fails because the symbol disappears. Alternative: `CONFIG_IPV6=m`, autoloaded via `kernel.modprobe`, for the same image saving. | −120-170 KB | INFERRED. dmesg shows SR-IPv6 and IOAM6 cores built in. All binds are IPv4: NCM 192.168.50.2, aa-proxy `0.0.0.0:…` (VERIFIED strings) | Low-med: any AF_INET6 socket gets EAFNOSUPPORT. The Mac's NCM IPv6 link-local becomes irrelevant. |
| D | `CONFIG_INIT_STACK_NONE=y` (instead of `INIT_STACK_ALL_ZERO`) | −5-15 KB | INFERRED | You lose stack info-leak hardening |
| D | `# CONFIG_MAGIC_SYSRQ is not set` | −4-6 KB | INFERRED | You lose `/proc/sysrq-trigger`. Serial sysrq is already off (VERIFIED). |
| D | `# CONFIG_FUTEX_PI is not set` | −3-5 KB | INFERRED | Breaks glibc PI mutexes (none expected) |
| D | `CONFIG_LD_DEAD_CODE_DATA_ELIMINATION=y` (EXPERIMENTAL, available on ARM with ld ≥2.36, VERIFIED) | UNMEASURED (tens of KB possible) | - | Medium: "may silently break". Only with a full HW regression run. |

**Do not do** (VERIFIED or long-standing practice):
- `KALLSYMS`, `DEBUG_BUGVERBOSE`, `SLUB_DEBUG`, `DEBUG_FS`, `FTRACE`, `PERF_EVENTS` and `IKCONFIG` are already off.
- `BUG=n` and `PRINTK=n`: you lose all field diagnostics.
- `SLUB_TINY`: its help says "not recommended for systems with more than 16MB RAM", and it slows skb allocation.
- `CC_OPTIMIZE_FOR_PERFORMANCE`: about +10-15% text, which cannot fit with LZO.
- Removing the ARM unwinder: impossible, the unwinder choice is mandatory and Thumb-2 requires `UNWINDER_ARM`.
- Dropping `CONFIG_USB_CONFIGFS_ACM`: recovery uses the ttyGS0 fallback shell.

**Suggested budget:**
- Tier A ≈ −180 KB net, after the +~7 KB of the F1/F2 fixes. Enough for 7.2 and 7.3 today.
- Tier A+B ≈ −350-550 KB, still with LZO and the same boot speed.
- Tier C is the big optional one. Use Tier D only if still short.

---

## 2. Performance / latency (TCP over Wi-Fi → aa-proxy-rs → FunctionFS AIO over USB, single A7)

Context (VERIFIED): r2 measured 78-117 Mbit/s over Wi-Fi against a 5-20 Mbit/s workload, so the CPU is not the bottleneck.
**Jitter is.** `aa-proxy-rs` uses the `usb-gadget` crate with AIO (`io_submit`/eventfd strings), so `CONFIG_AIO=y` and
`EVENTFD` are required: keep them.

- **Preemption model.** In 7.2 and 7.3, `PREEMPT_NONE` `depends on ARCH_NO_PREEMPT` and is unavailable. `PREEMPT_LAZY` needs
  `ARCH_HAS_PREEMPT_LAZY`, which ARM32 lacks. ARM has no `PREEMPT_DYNAMIC`. The only choices are VOLUNTARY and PREEMPT (VERIFIED,
  `kernel/Kconfig.preempt`, identical in both series).
  - **Keep `PREEMPT` if Tier A/B solve the size problem.** Under VOLUNTARY, a squashfs XZ page-in decompresses a 256 KB block
    (~20-40 ms on this CPU), and any other task can do that non-preemptibly ahead of aa-proxy (INFERRED).
  - Choose `PREEMPT_VOLUNTARY` only for the 30-60 KB and a few percent of throughput, which you don't need.
- **HZ.** Keep `HZ_100`, or `CONFIG_HZ_250=y` (0 bytes). ondemand's minimum sampling interval is 2 ticks
  (`CPUFREQ_DBS_MIN_SAMPLING_INTERVAL`, VERIFIED): 20 ms at 100 Hz, 8 ms at 250 Hz. The imx6 transition delay (61 µs × 1.5) is
  below that, so HZ sets how fast the clock ramps on a video burst. The tick cost is negligible with `NO_HZ_IDLE`. INFERRED benefit.
- **`CONFIG_ARM_PATCH_IDIV=y`** (`default y`, dropped by the `-n` flow, +<0.5 KB). It patches `__aeabi_{u}idiv` into
  `udiv`/`sdiv` at boot. The A7 has hardware divide: `/proc/cpuinfo` lists `idiva idivt` (VERIFIED, `boot1/misc.txt`).
- **`CC_OPTIMIZE_FOR_SIZE`**: keep. The copy and checksum hot paths are hand-written asm in `arch/arm/lib` (INFERRED, well known).
- **Allocator**: keep `SLUB` (not `SLUB_TINY`).
- **Networking.** These are all correct as they are. Nothing to add:
  - `NET_SCHED` is off, so egress uses `pfifo_fast` from `sch_generic` (always built).
  - fq_codel is not worth its ~40 KB. The bulk direction is Wi-Fi RX → userspace → FunctionFS (not a netdev qdisc), and
    brcmfmac is FullMAC (no mac80211 queues).
  - The TCP congestion control (cubic) only governs the phone's sender. The dongle is the receiver.
  - BQL is off and neither brcmfmac nor u_ether uses it.
  - GRO is core code and `NET_RX_BUSY_POLL` is not user-selectable (VERIFIED `def_bool`).
- **SDIO.** The brcmfmac SDIO workqueue is already `WQ_HIGHPRI` (VERIFIED `sdio.c:4476`), so there is no module parameter to
  set. The bus runs SDR/HS 50 MHz (`no-1-8-v`), which is ample.
- **vDSO.** Off. Enabling it would not help: `imx6ul.dtsi` marks the arch timer `status = "disabled"` (VERIFIED) and the
  clocksource is the GPT, so `clock_gettime` stays a syscall (~1 µs). Leave it.
- **No `DMADEVICES`/SDMA.** The 3 Mbaud BT UART runs PIO (INFERRED: fine for HCI and RFCOMM). If the SCO bridge is used, watch
  the `oe:` counters in `/proc/tty/driver/IMX`.
- **Userspace (outside the kernel, highest impact).** `aa-proxy-rs` is a 15.7 MB **ARM-mode** static binary (VERIFIED entry
  point). Building it for `thumbv7neon-unknown-linux-gnueabihf` with `opt-level="s"`, LTO and `panic=abort` would cut page-ins
  from the slow NOR (see §3).

---

## 3. Boot time to userspace

1. **Console verbosity.** −0.5-0.6 s (VERIFIED arithmetic, F4). Use `bootargs = "console=ttymxc1,115200 quiet rdinit=/init
   panic=10"`, or `CONFIG_CONSOLE_LOGLEVEL_DEFAULT=4` (the fragment pins 7 today). Everything still reaches `dmesg`.
   `CONSOLE_LOGLEVEL_QUIET=4` is already set.
2. **`lpj=`**: not needed. dmesg says "Calibrating delay loop (skipped), value calculated using timer frequency" (VERIFIED).
3. **Decompressor**: LZO is the fastest that fits. LZ4 does not fit (VERIFIED, §1a). An uncompressed initramfs inside a
   compressed kernel is the right choice (no double compression), and `RD_*` off is correct.
4. **Load**: U-Boot always reads `kernel_len` bytes, so shrinking the image saves no load time (VERIFIED).
5. **Probing.** On a UP system, async probing gains little. Profile once with `initcall_debug` (and `quiet` off), then
   consider `driver_async_probe=<slow driver>` only for a demonstrably slow sleeper (INFERRED). The `Fixed dependency cycle`
   lines are fw_devlink noise.
6. **Entropy.** `crng init done` appears at 3.8 s in r1. Optionally add `CONFIG_HW_RANDOM=y` and `CONFIG_HW_RANDOM_IMX_RNGC=y`
   (+~5 KB). Both are visible prompts and must be named. `imx6ull.dtsi` has `rngb: rng@2284000` (`fsl,imx25-rngb`, VERIFIED) and
   the driver sets `quality = 19` (VERIFIED). This seeds the crng early, so dropbear, hostapd and getrandom() don't block
   (INFERRED). If the probe-time self-test is slow, use `imx_rngc.self_test=0`.
7. **NOR read path (DT, not Kconfig).** QSPI runs **1-bit at 29 MHz** (VERIFIED in the DTS): about 3.6 MB/s raw, on top of xz
   decompression of 256 KB blocks. Page-ins of the 15.7 MB `aa-proxy-rs` probably dominate "boot to AA ready". Investigate
   FAST_READ or 1-1-4 quad on the MX25L12835F. This is a **hardware risk**: if WP#/HOLD# are tied straight to VCC, setting the
   QE bit can cause contention. Keep 3-byte addressing so a WDOG warm reset still boots from the ROM. Measure first with
   `dd if=/dev/mtdblock3 of=/dev/null bs=64k count=64`.
8. `CONFIG_SQUASHFS_FILE_DIRECT=y` instead of `FILE_CACHE`. VERIFIED help: "eliminates a memcpy and … lock contention".
   Small effect.

---

## 4. Power / thermal / RAM

**cpuidle.** VERIFIED from `mach-imx/Makefile`, `mach-imx6ul.c` and `cpuidle-imx6sx.c`:
- The i.MX6UL/ULL uses `imx6sx_cpuidle` with three states: WFI. WAIT, which gates the ARM clock (exit 50 µs, residency 75 µs).
  And LOW-POWER-IDLE, which power-gates the ARM (300 µs / 500 µs).
- It is built because `CPU_IDLE=y`, and works without `CONFIG_PM`: `pm-imx6.o` is unconditional and `imx6_pm_ccm_init()` runs
  from `init_irq`. No config change is needed.
- The `TIMER_STOP` states without broadcast are fine because the clockevent is the SoC GPT, not a per-CPU timer (INFERRED).
- Check on the device: `cat /sys/devices/system/cpu/cpuidle/current_driver` should print `imx6sx_cpuidle`, and the state
  `usage` counters should increase. Keep the `menu` governor.

**cpufreq.** `schedutil` `depends on SMP` (VERIFIED), so ondemand is right. The OPPs are 900/792/528/396/198 MHz, gated by the
speed-grade fuse (VERIFIED in `imx6ull.dtsi` and `imx6q-cpufreq.c`). The defaults are `up_threshold=80` and
`sampling_down_factor=1` (VERIFIED). For bursty video, tune at runtime:
`echo 60 > …/ondemand/up_threshold; echo 10 > …/ondemand/sampling_down_factor`. Or switch to `performance` for the length of an
AA session and back to `ondemand` when idle. `io_is_busy` does not matter here because the I/O is network, not block.

**Thermal** (F2). After the fix, check that `/sys/class/thermal/thermal_zone0/cdev0/type` is `thermal-cpufreq-0`. The trips are
set from the fuse grade (VERIFIED `imx_init_temp_grade`):

| Grade | Tmax | Passive trip | Critical trip |
|---|---:|---:|---:|
| Commercial | 95 °C | 85 °C | 90 °C |
| Extended / Industrial | 105 °C | 95 °C | 100 °C |

The probe log line `… CPU temperature grade - max:… critical:… passive:…` names the grade. The passive trip can be lowered
through sysfs, for example to 80 °C for a sun-baked dashboard. Also:
- `CONFIG_THERMAL_EMERGENCY_POWEROFF_DELAY_MS=10000`, so a stuck userspace poweroff still gets forced (VERIFIED: 0 disables it).
- `orderly_poweroff` ends in a **halt** on this board (no `POWER_RESET`). If WDOG1 runs, `imx2_wdt_shutdown` re-arms it at 128 s
  (VERIFIED), so the unit resets about 2 minutes later.
- For a car, consider `hw_protection=reboot` on the cmdline (VERIFIED in `kernel/reboot.c`, also `/sys/kernel/reboot/hw_protection`).

**RAM** (VERIFIED from the r1 dmesg, 0 image bytes):

| Setting | Now | Change | RAM saved |
|---|---|---|---:|
| `CONFIG_LOG_BUF_SHIFT` | 17: 131,072 B data + 409,600 B meta = 540 KB | 15 | ~405 KB |
| `CONFIG_INET_TABLE_PERTURB_ORDER` (EXPERT prompt) | 16: 65,536 entries, 256 KB | 10 | ~252 KB |

With `LOG_BUF_SHIFT=15` the log keeps 32 KB of text, while the boot log is ~7 KB. A smaller perturb table only weakens RFC 6056
port randomisation, which doesn't matter on this device.
- `zram`/`zswap`: **no.** Both need `SWAP=y` plus zsmalloc plus a compressor (~50-100 KB of image). 118 MB is free in recovery
  and the workload is known.
- MGLRU: available (FLATMEM satisfies `!SPARSEMEM`, VERIFIED) but pointless with no swap and only squashfs page cache.
- `COMPACTION` is off. That's fine for short ignition-cycle uptimes. Turn it on only if dmesg shows `page allocation failure: order:N`.
- Runtime: `vm.min_free_kbytes=4096` (default ≈ 4·√lowmem ≈ 1.4 MB, INFERRED) gives brcmfmac's atomic RX allocations more slack.
  Give `aa-proxy-rs` a negative `oom_score_adj` and respawn it from init.

---

## 5. Robustness (power can be cut at any time)

- **Panic.** `panic=10` is in the DT bootargs (VERIFIED). Add `CONFIG_PANIC_TIMEOUT=10` as a fallback, and
  **`CONFIG_PANIC_ON_OOPS=y`** (0 B): a brcmfmac or gadget oops in a workqueue then reboots instead of leaving Wi-Fi or USB dead.
  The bootstate guard only covers boots that don't reach "up", so a later panic reboots normally.
- **Watchdog** (F5). VERIFIED facts:
  - imx2_wdt clears the 16 s power-down counter (`WMCR=0`) and has a maximum timeout of 128 s.
  - The core keeps pinging after a magic close (`'V'`).
  - An unexpected close (feeder killed) lets the WDOG fire.

  Plan:
  1. Check whether U-Boot armed it: `devmem 0x020BC000 16` and look at bit 2 (WDE).
  2. Add a feeder to the **rootfs only**, e.g. `::respawn:/sbin/watchdog -F -t 5 -T 20 /dev/watchdog`. Better: let aa-proxy
     or a health check feed it.
  3. Set `CONFIG_WATCHDOG_NOWAYOUT=y` (0 B), so a feeder that exits "cleanly" can't silently hand pinging back to the kernel.

  **Do NOT set `CONFIG_WATCHDOG_OPEN_TIMEOUT` or `watchdog.open_timeout=`.** It is global: recovery uses the same kernel and
  cmdline, nobody opens the watchdog there, and the unit would reset in the middle of `flash-kernel` (brick risk).
- **Hung tasks** (optional, +~3 KB). `CONFIG_DETECT_HUNG_TASK=y` and `CONFIG_DEFAULT_HUNG_TASK_TIMEOUT=60`. Enable
  `kernel.hung_task_panic=1` with sysctl from the rootfs rcS only, not in recovery: it catches brcmfmac SDIO wedges (-110 class).
- **Soft lockups.** Skip the soft-lockup detector. On UP, a userspace-fed hardware watchdog already resets a kernel that
  starves userspace.
- **Console.** `MAGIC_SYSRQ_SERIAL` is off (VERIFIED) and the UART pads have pull-ups (0x1b0b1). A floating console line in the
  car can't trigger sysrq.
- **Flash.** The rootfs is read-only squashfs, and /run and /tmp are tmpfs, so power cuts are harmless there. The only exposure
  is raw NOR writes to `customer`/`bootstate`. Userspace must write, verify and rotate those. There is nothing to do in the
  kernel. Keep the QSPI in 3-byte, single-I/O boot mode so a watchdog warm reset always boots from the ROM.
- **BlueZ (INFERRED, modules only).** bluetoothd uses AF_ALG for some LE crypto. If its log shows crypto init errors, add
  `CONFIG_CRYPTO_USER_API_HASH=m`, `CONFIG_CRYPTO_USER_API_SKCIPHER=m`, `CONFIG_CRYPTO_CMAC=m` and `CONFIG_CRYPTO_ECB=m`. They
  cost nothing in the image because `CRYPTO=m`. Classic RFCOMM for AA doesn't need them.

---

## 6. Copy-paste delta (base.fragment / base-optional.fragment). The same lines work for 7.2 and 7.3.

Every line must survive the strict check. Remove lines whose symbols disappear (noted below).

```
# --- MUST (correctness / safety) ---
CONFIG_XZ_DEC_ARM=y
CONFIG_XZ_DEC_ARMTHUMB=y
CONFIG_THERMAL_OF=y
CONFIG_CPU_THERMAL=y
CONFIG_CPU_FREQ_THERMAL=y
CONFIG_THERMAL_EMERGENCY_POWEROFF_DELAY_MS=10000
CONFIG_ARM_PATCH_IDIV=y
CONFIG_PANIC_TIMEOUT=10
CONFIG_PANIC_ON_OOPS=y
CONFIG_WATCHDOG_NOWAYOUT=y
CONFIG_USB_GADGET_VBUS_DRAW=500
CONFIG_LOG_BUF_SHIFT=15
CONFIG_INET_TABLE_PERTURB_ORDER=10
CONFIG_CONSOLE_LOGLEVEL_DEFAULT=4          # replaces =7 (or add "quiet" to DT bootargs instead)

# --- Tier A size (replace the existing =y lines) ---
# CONFIG_CPUFREQ_DT is not set
# CONFIG_SQUASHFS_ZSTD is not set
# CONFIG_SYSVIPC is not set
# CONFIG_GPIO_SYSFS is not set               # and DELETE CONFIG_GPIO_SYSFS_LEGACY=y from base-optional.fragment
# CONFIG_GPIO_CDEV is not set
# CONFIG_CPU_FREQ_GOV_POWERSAVE is not set
CONFIG_PARTITION_ADVANCED=y                 # nousb: MSDOS/EFI then drop out; usb-host.fragment re-enables them
CONFIG_SQUASHFS_FILE_DIRECT=y

# --- Tier B ---
CONFIG_THUMB2_KERNEL=y
# (optional) CONFIG_PREEMPT_VOLUNTARY=y      # replaces CONFIG_PREEMPT=y; do NOT list TINY_RCU (derived)

# --- Tier C (optional) ---
# CONFIG_IPV6 is not set                    # and DELETE "# CONFIG_IPV6_SIT is not set"

# --- optional extras ---
CONFIG_HZ_250=y
CONFIG_HW_RANDOM=y
CONFIG_HW_RANDOM_IMX_RNGC=y
CONFIG_DETECT_HUNG_TASK=y
CONFIG_DEFAULT_HUNG_TASK_TIMEOUT=60
```

Outside Kconfig:
- **`initramfs.list`**: drop `sftp-server`.
- **DTS**: `/delete-node/` the unused disabled nodes. Optionally add `quiet` and `hw_protection=reboot` to the bootargs.
- **board.env**: `SQUASHFS_OPTS="-Xbcj arm,armthumb -b 262144"`.
- **Fragment comments**: fix the stale "XZ kernel" text in `base.fragment` and `base-optional.fragment`.

## 7. On-device checks (read-only), after the next flash

| Check | Command / file | Expected |
|---|---|---|
| F1 fix: every rootfs block decompresses | `cat /usr/bin/aa-proxy-rs > /dev/null && dmesg \| grep -i squashfs` | No errors |
| cpufreq driver | `/sys/devices/system/cpu/cpufreq/policy0/scaling_driver` | `imx6q-cpufreq` |
| cpuidle driver | `/sys/devices/system/cpu/cpuidle/current_driver` | `imx6sx_cpuidle` |
| Thermal cooling bound | `/sys/class/thermal/thermal_zone0/cdev0/type` | exists, `thermal-cpufreq-0` |
| Temperature grade | `dmesg \| grep "temperature grade"` | grade line present |
| WDOG armed by U-Boot | `devmem 0x020BC000 16` | bit 2 = WDE |
| Boot time | UART stopwatch, then `dmesg` timestamp at `Run /init` | ~0.25 s with `quiet` |

## Sources
- Kernel v7.2.15 / v7.3.6 sources via https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/ :
  - Kconfig: `kernel/Kconfig.preempt`, `kernel/rcu/Kconfig`, `arch/arm/Kconfig`, `arch/arm/Kconfig.debug`,
    `arch/arm/mm/Kconfig`, `init/Kconfig`, `lib/xz/Kconfig`, `fs/squashfs/Kconfig`, `drivers/thermal/Kconfig`,
    `drivers/watchdog/Kconfig`, `drivers/gpio/Kconfig`, `drivers/usb/gadget/Kconfig`, `block/partitions/Kconfig`,
    `lib/Kconfig.debug`
  - C sources: `lib/xz/xz_dec_stream.c`, `fs/squashfs/xz_wrapper.c`, `drivers/thermal/imx_thermal.c`,
    `drivers/cpufreq/imx6q-cpufreq.c`, `drivers/cpufreq/cpufreq-dt-platdev.c`, `arch/arm/mach-imx/{Makefile,cpuidle-imx6sx.c,mach-imx6ul.c}`,
    `drivers/watchdog/{imx2_wdt.c,watchdog_dev.c}`, `drivers/usb/gadget/configfs.c`, `drivers/mtd/mtd_blkdevs.c`, `kernel/reboot.c`
  - Other: `scripts/xz_wrap.sh`, `arch/arm/boot/dts/nxp/imx/imx6ul{,l}.dtsi`
- Bootlin, ARM xz kernel decompression benchmarks: https://bootlin.com/blog/arm-xz-kernel-decompression-benchmarks/
- Bootlin, LZO kernel compression: https://bootlin.com/blog/lzo-kernel-compression/
- Thumb-2 size data points: OpenWrt mvebu Thumb-2 RFC (https://lists.openwrt.org/pipermail/openwrt-devel/2020-June/029873.html, −8.8% vmlinux),
  GFiber Cortex-A8 commit (https://gfiber.googlesource.com/kernel/mindspeed/+/38be7e06a859f152aec236767885640c6fd632e2, ~−15%)
- Local measurements: the pure-Python LZO1X unpacker and recompression runs in the session scratchpad (not kept).
