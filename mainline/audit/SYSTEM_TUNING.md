# U2AC wireless-AA dongle: runtime and system tuning (audit, 2026-11-26)

Scope: i.MX6ULL (1x Cortex-A7, 900 MHz max), 125 MB usable RAM (`MemTotal: 125004 kB`, boot1/proc.txt), no swap,
mainline 7.2.15, BusyBox init, BCM4358 (brcmfmac SDIO + hci_bcm UART), hostapd 2.12, aa-proxy-rs v1.3.0
passthrough (`mitm = false`), built `--no-default-features` (tokio backend, no io-uring, no wasm, aa-build/build.sh).
Nothing here has been applied to the unit or the build. This is a read-only review.

Legend: **VERIFIED** = read in the code, config or kernel/crate source named in "Source". **INFERRED** = reasoning
or typical figures that still need an on-unit measurement. Paths are relative to `mainline/` unless absolute.
"Kernel src" = `linux-7.2.15` in docker volume `u2ac-build` (`/b/k7215/linux-7.2.15`). "Crate src" = docker volume
`u2ac-aa-cargo`. "aa src" = aa-proxy-rs v1.3.0 (41e245a) in docker volume `u2ac-aa-src`, identical in the files
cited here to the scratchpad clone (v1.2.0-54).

The data path matters for every network item below. Video flows **phone -> dongle** (Wi-Fi RX on the dongle), then
aa-proxy-rs, then FunctionFS (bulk IN to the HU). The dongle is the **TCP receiver** for the heavy flow. Its own TCP
sends (touch, mic, AA acks, TCP ACKs) are small. No loopback hop exists in passthrough: aa-proxy-rs reads the phone
socket and writes the FFS endpoint directly (aa src `src/proxy.rs` 1022-1061). Loopback tuning is therefore moot.

---

## 0. Ranked list (expected impact for this workload)

| # | Item | Area | Impact | Effort | Status |
|---|------|------|--------|--------|--------|
| 1 | Persist `/etc/aa-proxy-rs/known_devices`: today it is lost on every boot, so auto-connect never happens after a power cycle | boot-to-AA | **Very high**: every car start | 1 line in u2ac-aa | VERIFIED |
| 2 | FFS writer sends every frame as 512-byte AIO requests plus a flush per frame. Use 16 KiB transfers | CPU / latency on the video path | **High** | small aa-proxy-rs patch (upstream) | VERIFIED code, INFERRED gain |
| 3 | Bootstate mark: a power cut in the first ~3-6 s of a boot (typical at engine crank) sends the next boot to recovery, so no AA on that drive | power-cut safety | **High** (reliability) | initramfs + rcS | VERIFIED logic, INFERRED frequency |
| 4 | Boot ordering: start radios right after `persist load`, load BT first, run BT in parallel with hostapd, drop `sleep 2`, wait for the mgmt index before `btmgmt public-addr` (race), pre-read aa-proxy-rs | boot-to-AA | **High** (several s) | u2ac-aa + rcS hook | VERIFIED order, INFERRED seconds |
| 5 | BT patch "~6 s at 3 Mbaud" does not add up: 55,331 B takes 0.18 s at 3 Mbaud and 4.8 s at 115200. Check the baud before optimizing anything else | boot-to-AA | High if confirmed | measure | VERIFIED arithmetic, INFERRED cause |
| 6 | OOM: protect aa-proxy-rs, supervise/respawn it, cap tmpfs, `min_free_kbytes=4096` | memory / reliability | Medium | u2ac-aa | VERIFIED gaps |
| 7 | Flash writes stall every rootfs read (same NOR, 64 KiB erase blocks): no persist writes during a session, no BlueZ `cache/` in persist | latency + wear | Medium | u2ac-aa | VERIFIED layout |
| 8 | ondemand tuning (`up_threshold 95->50`, `sampling_down_factor 1->10`), `performance` during boot | latency / heat | Medium | u2ac-aa | VERIFIED defaults |
| 9 | Priorities: `nice -n -10` aa-proxy-rs, `nice -n 19` saver loop. No SCHED_FIFO | latency | Low-medium | u2ac-aa | INFERRED |
| 10 | hostapd: `dtim_period=1`. Keep 40 MHz over 80. Several "tuning" keys are no-ops on brcmfmac | Wi-Fi latency | Low-medium | conf | mixed |
| 11 | Network sysctls: almost all are no-ops or unavailable on this kernel. Optional cap `tcp_rmem` max at 256 KiB | latency | Low | sysctl | VERIFIED |
| 12 | aa-proxy-rs config: `webserver = ""`. `TOKIO_WORKER_THREADS` is ignored. `hostapd_cli` is missing | CPU / RAM | Low | config | VERIFIED |
| 13 | Faster rootfs reads: SPI NOR at 29 MHz 1-bit (~3.6 MB/s) with xz squashfs. Try fast-read / higher clock, or zstd | boot | Medium, but risky | DT/kernel/build | INFERRED |
| 14 | `bt_poweroff`, zram, swappiness, dirty_*, BBR, fq_codel, busy_poll, `tcp_low_latency`: leave alone or not applicable | - | none / negative | - | VERIFIED |

---

## 1. Boot-to-AA-ready time

### 1.1 Current critical path (VERIFIED order, INFERRED durations)

`U-Boot + kernel load (3 MB over SPI NOR at 29 MHz 1-bit) -> kernel 0.86 s to /init (boot1/dmesg.txt:96) -> initramfs
(1 s UART "Enter" window, bootstate mark write) -> rcS -> background subshell: persist load -> usb-mode boot -> net-up ncm
-> ssh-up -> bootstate_clear (64 KiB erase) -> board_late -> u2ac-aa start`
(ocbm/baseline/common/rootfs/etc/init.d/rcS 36-87, arm-imx6ul-u2ac/initramfs/init 54-74).

Inside `u2ac-aa start` everything runs **serially** (rootfs/usr/sbin/u2ac-aa 112-131):
1. `radio_up`: insmod brcmfmac, wcc, sdhci, hci_uart. Then poll for wlan0, then poll for hci0.
2. `ap_up`: hostapd, then wait for AP-ENABLED (includes the HT40 neighbor scan), then udhcpd, then dropbear.
3. `bt_up`: btmgmt power off / public-addr, dbus-daemon, bluetoothd, **`sleep 2`**.
4. aa-proxy-rs: first exec of a 13.9 MB static binary from xz squashfs over a 3.6 MB/s flash bus.

### 1.2 Findings

- **F1: known_devices is never persisted (VERIFIED, rank 1).** With `connect = "00:00:00:00:00:00"` aa-proxy-rs
  connects only to addresses in `KNOWN_DEVICES_FILE = /etc/aa-proxy-rs/known_devices` (aa src `src/bluetooth.rs` 419,
  5855-5870). If the file is empty it logs "No known-good devices, passively waiting for incoming phone connection".
  `/etc/aa-proxy-rs` is a symlink to `/run/aa-etc` (tmpfs), and `state_save` copies only `config.toml` from there
  (u2ac-aa 46). So after every power cycle the dongle waits for the phone to connect. In practice that usually means
  the user taps "connect" on the phone.
  **Fix:** in `state_save` add
  `[ -f /run/aa-etc/known_devices ] && cp /run/aa-etc/known_devices "$_new/aa-known_devices"`,
  and in `state_restore` add
  `[ -s "$P/aa-known_devices" ] && cp "$P/aa-known_devices" /run/aa-etc/known_devices`.
  The file changes only when a new phone completes a session (`save_known_device`, bluetooth.rs 4741), so flash
  writes stay rare.
- **F2: btmgmt runs before the controller is ready (VERIFIED race).** `/sys/class/bluetooth/hci0` appears at
  `hci_register_dev`, but the patch download runs afterwards in the power-on work. The mgmt index is announced only
  after setup (kernel src `net/bluetooth/hci_sync.c` `hci_dev_setup_sync`). `radio_up` waits only for the sysfs node
  (u2ac-aa 66). `bt_up` then runs `btmgmt -i hci0 power off && btmgmt public-addr ...` with output discarded (94-95).
  If setup has not finished, both calls fail silently and the BD address stays the chip default. Today hostapd's
  start usually hides the race. Running BT in parallel (below) exposes it.
  **Fix:** before btmgmt, wait for the index:
  `n=0; until btmgmt -i hci0 info 2>/dev/null | grep -q 'current settings'; do [ $n -ge 150 ] && break; sleep 0.1; n=$((n+1)); done`
  (INFERRED output string, confirm once on the unit). Changing the public address does not re-run the patch download:
  `set_public_address` queues power_on with HCI_CONFIG, and the driver `setup()` runs only with HCI_SETUP or the
  NON_PERSISTENT quirk, which hci_bcm does not set (VERIFIED, mgmt.c 8279-8300, hci_sync.c 5187-5196).
- **F3: is the patch download really at 3 Mbaud? (VERIFIED arithmetic, rank 5).** `BCM4358A3.hcd` is 55,331 B
  (out/r3x/root/lib/firmware/brcm). At 3 Mbaud with 10 bits per byte that is 0.18 s on the wire. At 115200 it is
  4.8 s. hci_serdev switches to `oper_speed` (DT `max-speed = <3000000>`) **before** calling `bcm_setup` (kernel src
  `drivers/bluetooth/hci_serdev.c` 197-214), and the patch is sent inside `btbcm_initialize`. On failure the kernel
  logs "Failed to set baudrate" and keeps 115200. Fixed sleeps add only ~0.6 s (btbcm.c 231 = 50 ms, 266 = 250 ms,
  286 = 100 ms per reset x2. hci_bcm.c 301 = 100-120 ms). Around 215 synchronous patch commands at ~1 ms each add
  ~0.25 s. **A ~6 s setup therefore points to the download running at 115200**, or to a command timing out
  (INFERRED). Check with `dmesg | grep -iE 'hci0|bcm|baud'` and compare the timestamps of "BCM: chip id", the
  `.hcd` line and "BCM4358A3 ... build". The expected total at 3 Mbaud is about 1-1.5 s. If confirmed, this one fix
  saves ~4-5 s and moves BT off the critical path.
- **F4: `sleep 2` (u2ac-aa 98) is a fixed cost.** With `bluetoothd -n` the log goes to stderr (LOG_PERROR when not
  detached), i.e. `/run/log/bluetoothd.log`. bluetoothd claims `org.bluez` before it prints
  "Bluetooth management interface ... initialized" (INFERRED from BlueZ start order, confirm in the log).
  **Fix:** `n=0; until grep -q 'management interface' /run/log/bluetoothd.log; do [ $n -ge 40 ] && break; sleep 0.05; n=$((n+1)); done`.
  Expected saving 1-1.7 s.
- **F5: radios wait for NCM, SSH and the bootstate erase.** `u2ac-aa start` is called from `board_late`, the last
  step of the rcS network subshell (rcS 86). The radios do not need NCM. Only the "computer on USB?" decision and the
  UDC handover do. (aa-proxy-rs calls `usb_gadget::remove_all()`, usb_functionfs.rs 283, so it must not race
  `net-up ncm`.)
  **Fix:** add a hook right after `persist load` in rcS (`command -v board_persist_loaded >/dev/null && board_persist_loaded`)
  that runs `u2ac-aa start &`. Have rcS `touch /run/baseline/ways.done` where `board_late` runs today. In u2ac-aa,
  wait for that flag (bounded at ~8 s) **only** just before `computer_on_usb` / starting aa-proxy-rs.
- **F6: parallelize BT and the AP (INFERRED, ~1-3 s).** The phone needs BT (RFCOMM bootstrap) first and the AP only a
  few seconds later, once it has received the credentials. So:
  `radio_up` (insmod **hci_uart first**, then brcmfmac/wcc/sdhci, so the BT patch starts ~0.5-1 s earlier) ->
  `( bt_up ) &` -> `ap_up` -> `wait` -> aa-proxy-rs. Both firmware loads are already asynchronous in the kernel, and
  the insmod order constraint in the u2ac-aa comment (brcmfmac before the SDIO host) is unaffected.
- **F7: `mod_load` costs many forks (INFERRED 0.3-1 s).** Each dependency check forks `awk` (mod_dep_line), `grep` and
  `echo|tr` (radio-lib.sh 61-129). hci_uart pulls in about 12 modules (radiotest/load.sh 17-31). At ~2-5 ms per
  fork+exec on the A7, that is tens to hundreds of ms per module.
  **Fix:** generate a flat, ordered insmod list per radio at build time (the order in radiotest/load.sh) and loop
  `insmod` over it. Measure first with `time sh -c '. /lib/baseline/radio-lib.sh; mod_load hci_uart'` on a cold boot.
- **F8: pre-read aa-proxy-rs while BT is busy (INFERRED 0.5-2 s).** The first exec of aa-proxy-rs takes page faults
  on xz squashfs. Each fault reads and decompresses a 128 KiB block over a ~3.6 MB/s bus. The window while the BT
  patch downloads (UART-bound) is nearly idle for CPU and flash.
  **Fix:** after hostapd is launched, run `nice -n 19 cat /usr/bin/aa-proxy-rs >/dev/null &`. (Do not overlap it
  with insmod or the hostapd exec, which read the same flash.) The cost is ~14 MB of reclaimable page cache.
- **F9: CPU governor during boot (VERIFIED defaults).** `radio_up` sets ondemand at the start of boot (u2ac-aa 57-59).
  Defaults on this kernel are up_threshold 95 (NO_HZ_IDLE active, cpufreq_ondemand.c 342-344) and sampling every
  20 ms (2 ticks at HZ=100, cpufreq_governor.c 22/465). Fork-heavy shell work starts at 198-528 MHz. Upstream
  aa-proxy images boot fast and switch the governor back after boot
  (aa-proxy/buildroot `external/board/radxa03w/rootfs_overlay/etc/init.d/S99cpufreq_governor.sh`, VERIFIED via `gh api`).
  **Fix:** `echo performance > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor` at the top of `start()`, then
  switch to tuned ondemand (section 7) after aa-proxy-rs starts. Small gain (INFERRED <0.5 s).
- **F10: defer non-critical work.** Start the dropbear on 10.0.0.1 (u2ac-aa 87-88) and the `state_save` loop after
  aa-proxy-rs. udhcpd must be up before the phone joins Wi-Fi, which happens only after the BT bootstrap, so keeping
  it in `ap_up` is fine.
- **F11: timestamps.** `say()` has no time. Use
  `say() { read -r _u _ < /proc/uptime; echo "[$_u] u2ac-aa: $*"; echo "[$_u] u2ac-aa: $*" >> "$LOG"; }`
  plus `dmesg` timestamps (PRINTK_TIME=y) to measure boot-to-AA. BusyBox `bootchartd` is in the image
  (out/r3x/root/sbin) for a full chart.
- **F12: aa-proxy-rs knobs.** `startup_delay = 0` is already set. `legacy = true` adds an MTP-stage enumeration before
  AOA (usb_functionfs.rs `run_mtp_stage`). Turning it off saves one re-enumeration on HUs that do not need it
  (HU-dependent, INFERRED). `change_usb_order` is an experiment knob only. BlueZ `FastConnectable = true` in
  `[General]` (bluez main.conf: "other devices can connect faster to us ... increased power") speeds
  phone-initiated connects. It matters less once F1 makes the dongle the initiator.
- **F13: rootfs read speed (INFERRED, risky).** The flash node is `spi-max-frequency = <29000000>`,
  `spi-rx-bus-width = <1>`, with no `m25p,fast-read` (imx6ull-ccpa-baseline.dts 221-226), so reads use plain READ
  (0x03). Fast read is available from DT (kernel src spi-nor/core.c 3123). Adding `m25p,fast-read` and a higher clock
  after checking the exact part's datasheet (the ID covers MX25L12805D and 12835F, patch 0004) could cut flash time
  1.5-3x. Quad mode needs QE (a non-volatile status write) plus a flags patch: do not attempt it casually. Measure
  first with `time dd if=/dev/mtdblock<rootfs> of=/dev/null bs=64k count=64`. Separately, `-comp zstd` is supported
  (CONFIG_SQUASHFS_ZSTD=y) and decompresses several times faster than xz on ARM. The rootfs is 9.70 MiB of a
  12.375 MiB partition (out-build logs, DT `reg = <0x380000 0xc60000>`), so a measured zstd build may fit.
- **F14: BusyBox init.** sysinit `rcS` returns at once (the network part is backgrounded). That is correct. The two
  respawn entries (`usb-mode watch`, 5 s loop, `ocbm-overlay service`, 600 s sleep) are negligible. Keep them.

---

## 2. Network sysctls for this relay

| Knob | Verdict | Why |
|------|---------|-----|
| `net.core.default_qdisc` | **Not present** | CONFIG_NET_SCHED is off (kernel-7.2.15.config). The sysctl is `#ifdef CONFIG_NET_SCHED` (sysctl_net_core.c 590-597). wlan0 gets built-in pfifo_fast. No `tc`. VERIFIED |
| fq_codel | Not available. Little to gain | It would shape only the dongle's small TX direction, and brcmfmac keeps its own 2048-packet bus queue under the qdisc (brcmfmac sdio.c 116 `TXQLEN`). VERIFIED/INFERRED |
| `tcp_congestion_control` (cubic vs bbr) | **Keep cubic** | Only cubic is built (`TCP_CONG_ADVANCED` not set). The sender's CC (the phone's) controls video, and the dongle's CC affects only its small flow. BBR would need a kernel rebuild for no gain. VERIFIED config, INFERRED effect |
| `tcp_low_latency` | **No-op** | `static int sysctl_tcp_low_latency`, unused (sysctl_net_ipv4.c 57/569). VERIFIED |
| TCP_NODELAY | Already on | `stream.set_nodelay(true)` on the phone socket (aa src proxy.rs 594). VERIFIED |
| `net.core.busy_poll/busy_read` | **Avoid / N/A** | brcmfmac delivers with `netif_rx()`, not NAPI (core.c 431), so sockets get no napi_id. On one core, spinning also starves the producer. VERIFIED driver, INFERRED effect |
| `net.core.rmem_max/wmem_max` | No effect | aa-proxy-rs never sets SO_RCVBUF/SO_SNDBUF (no such call in aa src). These cap only setsockopt. VERIFIED |
| `net.ipv4.tcp_rmem` | Optional: `4096 131072 262144` | Autotuned max ≈ 0.9 MB here (`max(131072, min(32 MiB, nr_free_buffer_pages<<5))`, tcp.c 5372-5382). A 1-hop BDP is ~12-125 KB. Capping at 256 KiB bounds a standing queue to ~100 ms at 20 Mbit/s if aa-proxy-rs or USB stalls. AA's own video `max_unacked` normally bounds it first. INFERRED, low |
| `net.ipv4.tcp_wmem` | Leave | The dongle's sends are small. VERIFIED defaults `4096 16384 ~0.9MB` |
| `tcp_notsent_lowat`, `tcp_slow_start_after_idle` | Leave | Sender-side knobs. The dongle is not the bulk sender. INFERRED |
| wlan0 `txqueuelen` | Optional `ip link set wlan0 txqueuelen 100` | Negligible: the downlink is small and brcmfmac's own queue sits below it. INFERRED |
| `netdev_max_backlog` (1000) | Leave. Monitor | netif_rx feeds the backlog. brcmfmac's rxbound is 50 frames per DPC pass (sdio.c 123). Watch column 2 of `/proc/net/softnet_stat` for drops. INFERRED |
| GRO/RPS/XPS | N/A | No NAPI means no GRO. One CPU means no RPS. VERIFIED |

What does help video latency is mostly outside sysctls: item 2 (USB path), item 8 (frequency ramp), item 9 (priority)
and keeping memory pressure off the squashfs text pages (section 5).

---

## 3. hostapd / Wi-Fi AP (brcmfmac FullMAC specifics)

brcmfmac is **FullMAC**: the firmware builds the HT/VHT/WMM IEs and runs the data path. Several hostapd keys do
nothing here:

| Key | Verdict | Source |
|-----|---------|--------|
| `wmm_ac_*`, `tx_queue_data*` | **No effect.** brcmfmac drops hostapd's WMM vendor IE ("Found WPA/WME oui. Do not add it") and the firmware uses its own WME defaults | VERIFIED cfg80211.c 4808-4813 |
| `wmm_enabled=1` | **Keep.** HT/VHT rates require WMM. Disabling it caps the link at 54 Mbit/s | hostapd.conf 625-626, VERIFIED |
| `ht_capab` extras `[LDPC] [TX-STBC] [RX-STBC1]`, `vht_capab [RXLDPC]...` | **Do not add.** brcmfmac advertises only SGI20/SGI40/HT40/DSSSCCK40 (HT) and SGI80 plus beamforming bits (VHT). hostapd rejects capabilities the driver does not report and fails to start. The firmware builds the IEs anyway | VERIFIED cfg80211.c 7255-7322 |
| `beacon_int`, `dtim_period` | **Honoured** (BRCMF_C_SET_BCNPRD / SET_DTIMPRD) | VERIFIED cfg80211.c 5200-5215 |
| `disassoc_low_ack` | **No effect.** brcmfmac emits no CQM packet-loss events | VERIFIED (no `cfg80211_cqm_pktloss_notify`) |
| `ap_max_inactivity` / `skip_inactivity_poll` | Leave at 300 / 0. brcmfmac reports inactive_time (cfg80211.c 3176) but has no probe_client. aa-proxy-rs already drops dead sessions (`timeout_secs = 10`) | VERIFIED |
| `noscan` (skip the 20/40 scan) | **Not available in hostapd 2.12.** The field `no_pri_sec_switch` has no config key | VERIFIED hw_features.c 624, config_file.c |
| AP power save | No-op. `set_power_mgmt` only affects STA PM (BRCMF_C_SET_PM), and the AP is never put in PM by `start_ap` | VERIFIED cfg80211.c 3294-3327, INFERRED firmware behaviour |
| Frameburst | Already enabled by the driver (`BRCMF_C_SET_FAKEFRAG 1`) | VERIFIED cfg80211.c 7820 |
| Group rekey | Defaults are fine: CCMP uses 86400 s in 2.12 | VERIFIED hostapd.conf 1991-1994 |

Recommended changes (add to **both** hostapd.conf and hostapd-80.conf):

```
dtim_period=1      # default 2 (hostapd.conf 248). A dozing phone wakes every 102 ms instead of 205 ms,
                   # which helps downlink touch/ack latency when the phone is in power save. INFERRED, cheap.
beacon_int=100     # keep. 50 doubles beacon airtime for little gain. INFERRED
```

- **Channel width (INFERRED):** keep **40 MHz** as the default even when VHT80 is offered. Video needs 5-20 Mbit/s and
  2x2 HT40 has ample headroom. A narrower channel gives ~3 dB less noise bandwidth, overlaps fewer other dongles in
  traffic (every AutoKit sits on ch36), and draws somewhat less RX power. Use 80 MHz only if measurements show airtime
  pressure. HT20 is a reasonable fallback in crowded RF.
- **Encryption:** WPA2-CCMP runs in firmware, so it costs no host CPU. Keep it. (Out of scope but notable: the
  PSK `12345678` is shared across units, and the AP also serves root ssh on 10.0.0.1. Anyone in a parking lot can
  join and also steal airtime.)
- **txpower (VERIFIED semantics, INFERRED effect):** `iw ... set txpower fixed 1400` maps to `qtxpower = 56 | WL_TXPWR_OVERRIDE`
  (cfg80211.c 2669-2690). The override flag bypasses the board and regulatory per-rate limits. Heat savings are small
  because the dongle mostly **receives** video. Either keep 14 dBm or drop the line and let the firmware use its
  nvram limits (auto, no override). Do not raise it.
- **Ordering nit:** add `ip addr add 10.0.0.1/24 dev wlan0` before starting hostapd (an address survives link down).
  Then a fast-associating phone never meets a missing IP or udhcpd (INFERRED, minor).

---

## 4. aa-proxy-rs (passthrough) settings and code

Config (rootfs/usr/share/u2ac/aa-proxy-rs.config.toml):
- Already optimal: `debug = false`, `hexdump_level = "Disabled"`, `pkt_debug = false`, `stats_interval = 0`,
  `mitm = false`. The per-packet `pkt_debug()` returns at once when both are off (mitm_prettyprint.rs 1255-1258), and
  the passthrough loop does no parsing (mitm.rs 4307-4340). VERIFIED.
- **`webserver = ""`** (today `0.0.0.0:80`) unless the web UI is used. It saves one listener and the axum stack's RAM
  (INFERRED, ~1-3 MB). Note: the companion "reverse bridges" HTTP/WS still try to reach the phone's ports 9999/9998
  **every 1 s for the whole session** whatever this setting (proxy.rs 509-560, 355-360). That is ~2 SYN/RST pairs per
  second on the air. There is no config switch for it: only a code change gating it on `webserver` or
  `add_vendor_channel` would stop it (VERIFIED code, INFERRED cost: low).
- `enable_companion_bt = true` stays, because u2ac relies on it to keep the adapter pairable (config comment).
- Logs: `logfile = /var/log/aa-proxy-rs.log` (-> `/run/log`, tmpfs) and u2ac-aa also captures the console into
  `/run/log/aa-proxy-rs.console`, so every line is stored twice in RAM. Point the console at `/dev/null` once the file
  log is trusted, or cap tmpfs (section 5).
- **`TOKIO_WORKER_THREADS` has no effect:** main.rs 1651-1656 calls `.worker_threads(max(nproc, 2))`, and an explicit
  value overrides the env var (crate src tokio-1.52.3 `runtime/builder.rs` 463, 1859). VERIFIED. Two workers on one
  core are deliberate (comment in main.rs 1647-1650: blocking sysfs/UDC calls would otherwise freeze the runtime).
  Keep them.
- **`hostapd_cli` is not in the image** (out/r3x/root/usr/sbin has hostapd only). aa-proxy-rs spawns
  `/usr/bin/hostapd_cli disassociate <mac>` at session end (proxy.rs 1187), and that silently fails. It matters for
  "next device" and stop-on-disconnect flows. Either build hostapd_cli (CONFIG_CTRL_IFACE=unix is already on) or
  accept it.

Code (upstream patches. These are the biggest CPU items on the video path):
- **P1: FFS writer chunking (VERIFIED code, INFERRED gain, rank 2).** `ffs_io.rs` `IntoSinkWriter` splits each frame
  into `max_packet_size()` pieces. That is the endpoint wMaxPacketSize, 512 B at high speed (crate src usb-gadget-1.2.0
  `custom/mod.rs` 1677-1679). Each piece is a separate AIO PWRITE, and the code then `flush_async()`s after **every**
  frame (aa src ffs_io.rs 95-120). The crate's own docs warn that MPS-sized transfers give "high per-packet overhead
  and poor throughput" and recommend ~16 KiB (mod.rs 1655-1665, 1900-1911). A 16 KiB video fragment becomes 32 AIO
  submits, 32 UDC completions/IRQs and eventfd wakeups, and the per-frame flush serializes frames.
  **Patch:** `let xfer = (16384 / mps).max(1) * mps;` and `split_to(len.min(xfer))`. Keep the ZLP rule on
  `data_len % mps == 0`. Consider dropping the per-frame flush, or flushing only when the queue is full (AIO keeps
  order on one endpoint). Do the same for `RecvContext` (buffer = 16 KiB, not MPS: a short packet ends the transfer
  early, so latency is unchanged, mod.rs 1913-1926). Expect roughly 30x fewer AIO ops and IRQs on the HU-bound path.
  This is a likely-visible CPU cut at 20 Mbit/s. Validate on the actual HU (the code comment mentions "issues with
  some UDCs". chipidea queues multi-TD requests. INFERRED).
- **P2: copies (VERIFIED, INFERRED ~4-7% CPU at 20 Mbit/s).** Per phone->HU byte: a zeroed 16 KiB `vec!` per read
  (io_tokio.rs `read_input_data`), copy into a VecDeque, copy into a frame vec, `drain(..header)` memmove (mitm.rs 4211-4216), then
  `payload.clone()` plus `append` in `transmit` (mitm.rs 1111), `CopyToBytes`, and the f_fs kernel bounce. Reusing
  buffers and dropping the clone would save 3-4 memcpy passes. This is secondary to P1.
- `MITM_QUEUE_CAPACITY = 10` packets per hop (proxy.rs 64) bounds in-app buffering at ~640 KiB. Fine.

---

## 5. Memory

Expected steady state in a session (INFERRED, measure with
`ps -o pid,rss,vsz,args; grep -E 'VmRSS|RssAnon|RssFile|Threads' /proc/$(pidof aa-proxy-rs)/status; cat /proc/meminfo`):
aa-proxy-rs 8-15 MB (part of it file-backed text from squashfs), bluetoothd 2-4 MB, hostapd 1.5-3 MB, dbus-daemon
1-2 MB, udhcpd/dropbear/busybox shells <1 MB each. Kernel: ~7 MB reserved (dmesg "Memory:") plus slab and skbs.
Expect MemAvailable ≥ 60-70 MB. RAM is not tight, so the goals are robustness and keeping text pages resident.

- `vm.overcommit_memory = 1`: already set (u2ac-aa 114). Keep it. It is needed for tokio's reservations and the
  2 MiB thread stacks.
- **`vm.min_free_kbytes = 4096`** (INFERRED). The default is ~1.4 MB (sqrt(lowmem_kB*16)). CONFIG_COMPACTION is **off**
  (kernel config), so higher-order and atomic allocations (SDIO RX skbs in the HIGHPRI brcmf_wq, f_fs AIO buffers)
  get more headroom from a larger reserve. Watch for `page allocation failure` in dmesg.
- **Keep text resident (INFERRED):** without swap, the only reclaimable memory is page cache, including aa-proxy-rs's
  own code pages. Evicting them costs a 128 KiB xz decompress plus a NOR read per refault, i.e. tens of ms stalls on
  the relay. Staying well clear of pressure (caps below) matters more than any vm knob.
- `vm.swappiness`, `vm.dirty_*`, `vm.vfs_cache_pressure`: **no effect / leave**. There is no swap (CONFIG_SWAP off),
  no writable block filesystem (squashfs ro + tmpfs), and persist goes through `flashcp` on the mtd char device, not
  the page cache. VERIFIED.
- **zram: not possible and not wanted.** CONFIG_ZRAM and CONFIG_SWAP are off. Compressing on the single core would
  add exactly the latency we want to avoid. VERIFIED config, INFERRED judgement.
- **tmpfs caps (INFERRED):** `/run` and `/tmp` are default-size tmpfs (50% of RAM each, init 10-12). Logs grow with
  no limit. Cap them so runaway logs hit ENOSPC instead of the OOM killer:
  `mount -o remount,size=24m /run; mount -o remount,size=8m /tmp`. Check current use with `df` first.
- **OOM priorities (VERIFIED gap):** nothing sets `oom_score_adj`, and aa-proxy-rs is the largest process, so it would
  be the **first** victim. Launch it as
  `( echo -900 > /proc/self/oom_score_adj; cd /run/data && exec nice -n -10 aa-proxy-rs ... )`.
  Set `echo -500 > /proc/<pid>/oom_score_adj` for hostapd, bluetoothd and dbus-daemon, and leave dropbear and shells
  at 0. Never use -1000 on everything: if nothing is killable, the kernel panics.
- **Supervision (VERIFIED gap):** aa-proxy-rs is started once (u2ac-aa 124) and built `panic = "abort"`. A crash
  leaves no AA until reboot. Wrap it:
  `( while :; do (echo -900 >/proc/self/oom_score_adj; cd /run/data && exec nice -n -10 aa-proxy-rs) >>/run/log/aa-proxy-rs.console 2>&1; say "aa-proxy-rs exited $?, restart in 2 s"; sleep 2; done ) &`.
  Adapt `stop()` to kill the loop pid first.

---

## 6. Flash wear and power-cut safety

Facts (VERIFIED): rootfs (squashfs xz, ro), `customer` (64 KiB persist tar) and `bootstate` (64 KiB) share one SPI
NOR (DT partitions 236-269). CONFIG_MTD_SPI_NOR_USE_4K_SECTORS is off, so the erase size is **64 KiB**. Every
`flashcp`/`flash_eraseall` is a full block erase (typically ~0.4-0.7 s, up to ~2 s per datasheet class, INFERRED),
and the chip cannot serve reads meanwhile. Every squashfs page fault from any process waits.

- **Bootstate window (rank 3).** The initramfs writes the boot mark on every rootfs boot (initramfs/init 67-68). rcS
  erases it only after NCM and SSH are up (rcS 70-76, mtd.sh 42-45). If power is cut in between (engine crank cuts or
  dips USB power seconds after plug-in), the next boot sees the mark and **stays in recovery**: no Android Auto for
  that drive. Options (INFERRED):
  (a) clear the mark as soon as rootfs userspace runs (rcS start), accepting a weaker boot-loop guard (`panic=10`
  still reboots on PID-1 death).
  (b) better: a **slot counter** that needs no erase on the normal path. Boot k programs the 8-byte mark into the
  next erased slot. rcS programs that slot to 00 (NOR can flip 1->0 without an erase). The initramfs goes to recovery
  only if the last **N=3** used slots are all marks. Erase only when the 64 KiB is full (once per 8192 boots). This
  also removes today's per-boot 64 KiB erase and its rootfs read stall.
- **Persist writes.** `state_save` runs every 30 s and writes only on change (md5 compare, u2ac-aa 47). Good. Gaps:
  - It copies the whole `/run/varlib/bluetooth` including `<adapter>/cache/`, which BlueZ rewrites when names or SDP
    records change. Persist only `settings` and `<dev>/info` (link keys), plus `attributes` if LE is ever used. That
    cuts write frequency (INFERRED).
  - **Do not write during a session:** skip `state_save` while a TCP session on :5288 is established
    (`awk '$2 ~ /:14A8$/ && $4 == "01" {f=1} END {exit !f}' /proc/net/tcp`, 0x14A8 = 5288, state 01 = ESTABLISHED). A 64 KiB erase would stall all
    rootfs reads mid-drive. Pairing happens before a session, so nothing is lost.
  - Single copy, erase then write: a cut during `flashcp` loses all pairings and config. flashcp verifies after
    writing, but there is no A/B copy. If the archive stays ≤ 28 KiB, splitting the 64 KiB block into two 32 KiB
    halves needs 4K sectors (kernel option) or a second partition. Otherwise accept it, given the rare writes
    (INFERRED).
  - Run the saver at `nice -n 19` and stretch it to ~60 s. Each pass forks ~15-20 BusyBox processes (u2ac-aa 35-53).
- Logs only in RAM: already true (/var/log -> /run/log, aa-proxy-rs crash dir `/data/aa-proxy-rs/crashes` ->
  /run/data, tmpfs. out/r3x/root/var). Nothing calls fsync on flash. There are no fsync storms by construction.
- aa-proxy-rs writes `last-service-discovery-response.json` only on the MITM path (mitm.rs 1331-1342), so it does
  not churn persist in passthrough. VERIFIED.

---

## 7. Power and heat

- **cpufreq (VERIFIED defaults, INFERRED tuning).** OPPs: 900 MHz/1.275 V, 792/1.225, 528/1.175, 396/1.025,
  198/0.95 (imx6ull.dtsi 16-23). ondemand defaults here: up_threshold=95, sampling_rate=20000 µs (floor = 2 ticks at
  HZ=100), sampling_down_factor=1. A bursty relay at 30-50% average load will see frames arrive at a low OPP and wait
  up to a sampling period.
  Recommended, after aa-proxy-rs starts:
  ```
  G=/sys/devices/system/cpu/cpufreq/ondemand      # global tunables (imx6q-cpufreq: no per-policy governor)
  [ -d $G ] || G=/sys/devices/system/cpu/cpu0/cpufreq/ondemand
  echo 50 > $G/up_threshold
  echo 10 > $G/sampling_down_factor               # hold top OPP ~200 ms after load
  # sampling_rate stays 20000 (cannot go below 2 ticks at HZ=100)
  ```
  Alternative: `performance` for the whole session. Busy dynamic power is ~2x that of 528 MHz
  ((900/528)·(1.275/1.175)² ≈ 2.0), roughly +50-100 mW on a SoC whose budget is far below the BCM4358's. That is
  acceptable if tuned ondemand still shows stutter. Thermal: passive trip = temp_max-10 °C, critical = temp_max-5 °C
  (imx_thermal.c 449-450), with step_wise cooling built in. Check the grade with
  `cat /sys/class/thermal/thermal_zone0/trip_point_*_temp`.
- **Wi-Fi txpower:** see section 3. The dongle transmits little, so txpower is a minor heat lever. Channel width is
  the bigger RX-power lever (40 over 80, INFERRED).
- **`bt_poweroff` (VERIFIED behaviour): keep `false`.** It powers the adapter off after the handshake and back on at
  the next bootstrap (bluetooth.rs 7885-7887, 8155-8178). The savings are small (BT idle is mostly page/inquiry scan,
  and 5 GHz Wi-Fi does not time-share with BT). It disables companion-BT and quick-reconnect paths, and a mid-drive
  Wi-Fi drop then needs a full BT power-up before re-bootstrapping (INFERRED).
- **USB:** device side only. There is no autosuspend to tune, and the VBUS draw is the HU's business. Item 2 (fewer
  IRQs) is also the main USB power win.
- **Scheduling:** CONFIG_PREEMPT=y, HZ=100. brcmfmac's RX worker already runs on a HIGHPRI workqueue (nice -20, sdio.c
  4479). `nice -n -10` on aa-proxy-rs is safe. Avoid SCHED_FIFO/RR for aa-proxy-rs: an RT task starves the CFS
  kworkers that feed it (brcmf_wq, f_fs, ksoftirqd) and invites priority inversion (INFERRED). HZ=250/1000 would give
  finer CFS slicing between competing CPU hogs, but needs a kernel rebuild. Low priority.

---

## Appendix A: measure before and after (all read-only)

```
dmesg | grep -iE 'brcmf|hci0|bcm|baud|usb|ffs|alloc'     # F3, timestamps
grep . /run/log/u2ac-aa.log                               # once say() has uptime stamps (F11)
cat /proc/net/softnet_stat                                # col2 = backlog drops
top -d 1 (or mpstat 1)  during a session                  # CPU split: aa-proxy-rs vs ksoftirqd vs kworker
cat /proc/interrupts (twice, 10 s apart)                  # ci_hdrc/usb IRQ rate before and after P1
cat /sys/devices/system/cpu/cpu0/cpufreq/stats/time_in_state
cat /sys/class/thermal/thermal_zone0/temp
cat /proc/meminfo; ps -o pid,rss,vsz,args; df /run /tmp
iw dev wlan0 station dump                                 # tx/rx bitrate, retries, inactive time
time dd if=/dev/mtdblock<rootfs#> of=/dev/null bs=64k count=64   # raw NOR read speed (F13)
```

## Appendix B: proposed `u2ac-aa start` shape (sketch, untested)

```
start() {
    : > "$LOG"
    echo 1 > /proc/sys/vm/overcommit_memory
    echo 4096 > /proc/sys/vm/min_free_kbytes
    echo performance > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
    state_restore                                  # + known_devices (F1)
    radio_up || ...                                # hci_uart FIRST, flat insmod list (F6, F7)
    ( bt_wait_index; bt_up_fast ) & BTP=$!         # mgmt-index wait (F2), log-poll instead of sleep 2 (F4)
    ip addr add 10.0.0.1/24 dev wlan0 2>/dev/null
    ap_up                                          # without dropbear (deferred)
    nice -n 19 cat /usr/bin/aa-proxy-rs > /dev/null 2>&1 &   # pre-read while BT finishes (F8)
    wait $BTP
    wait_flag /run/baseline/ways.done 8            # rcS network part done (F5)
    <mode decision as today>
    <supervised aa-proxy-rs, oom -900, nice -10>   # section 5
    renice/oom -500 hostapd bluetoothd dbus-daemon
    <ondemand tuned>                               # section 7
    dropbear on 10.0.0.1
    ( while :; do sleep 60; session_active || nice -n 19 state_save; done ) &   # section 6
}
```

## Sources

Local: `ocbm/baseline/arm-imx6ul-u2ac/rootfs/usr/sbin/u2ac-aa`. `.../usr/share/u2ac/{hostapd.conf,hostapd-80.conf,
udhcpd-wlan.conf,aa-proxy-rs.config.toml}`; `ocbm/baseline/common/rootfs/{init,etc/init.d/rcS,etc/inittab}`.
`.../arm-imx6ul-u2ac/rootfs/etc/baseline/board-rcS.sh`. `ocbm/baseline/common/shared/{net-up,ssh-up,persist,mtd.sh}`.
`ocbm/baseline/arm-imx6ul-u2ac/initramfs/init`. `.../dts/{imx6ull-ccpa-baseline.dts,radio-bcm4358.dtsi}`.
`audit/kernel-7.2.15.config`. `boot1/{dmesg.txt,proc.txt}`. `out/r3x/root` (image contents). `aa-build/build.sh`.
Out-build logs (squashfs size).
Kernel src 7.2.15: `net/core/sysctl_net_core.c`, `net/ipv4/{tcp.c,sysctl_net_ipv4.c}`, `net/bluetooth/{mgmt.c,hci_sync.c}`,
`drivers/bluetooth/{btbcm.c,hci_bcm.c,hci_serdev.c}`, `drivers/net/wireless/broadcom/brcm80211/brcmfmac/{cfg80211.c,
core.c,sdio.c,common.c}`, `drivers/cpufreq/{cpufreq.c,cpufreq_governor.c,cpufreq_ondemand.c,imx6q-cpufreq.c}`,
`drivers/thermal/imx_thermal.c`, `drivers/mtd/spi-nor/core.c`, `arch/arm/boot/dts/nxp/imx/imx6ul{,l}.dtsi`.
hostapd 2.12 (`u2ac-build:/b/userspace/build/hostapd-2.12`): `hostapd/hostapd.conf`, `src/ap/hw_features.c`.
BlueZ 5.87 `src/main.conf` (the build tree's version, the brief says 5.79, and the options cited are the same).
Crates: usb-gadget 1.2.0 `src/function/custom/mod.rs`. tokio 1.52.3 `src/runtime/builder.rs`.
aa-proxy-rs v1.3.0: `src/{main.rs,proxy.rs,io_tokio.rs,ffs_io.rs,usb_functionfs.rs,mitm.rs,mitm_prettyprint.rs,
bluetooth.rs,config.rs,sdr_snapshot.rs}`.
Web: github.com/aa-proxy/buildroot (`external/board/*/rootfs_overlay/etc/hostapd.conf.in`,
`radxa03w/.../S99cpufreq_governor.sh`), read via `gh api`. The upstream images ship plain hostapd with no tuning.
