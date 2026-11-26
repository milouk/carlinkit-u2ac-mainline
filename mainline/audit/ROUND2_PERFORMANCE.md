# U2AC wireless-AA dongle: round-2 performance audit (data path, CPU, latency), 2026-11-26

Read-only review. Nothing was built, flashed or run on the unit. This round covers only items that
`SYSTEM_TUNING.md` and `KERNEL_AUDIT.md` do not already cover. Where one of those documents is wrong or incomplete,
section 4 says so.

Legend: **VERIFIED** means read in the code, config or source named in the row. **INFERRED** means reasoning or typical
figures that still need a measurement on the unit (section 5 has the commands). Short names used below:
- "aa": aa-proxy-rs v1.3.0 (41e245a, with `0001-ffs-io-16k-transfers.patch`) from the volume `u2ac-aa-src`.
- "kernel": linux-7.2.15 from the volume `u2ac-build` (the patched build tree).
- "cfg": `/build/k7215/kbuild/nousb/.config`, which is the config actually built. It is newer than
  `audit/kernel-7.2.15.config`: HZ_250, THERMAL_OF and the other round-1 changes are in it.
- "usb-gadget": the crate usb-gadget 1.2.0 from `u2ac-aa-cargo`.
- "musl": musl 1.2.5 source from musl.libc.org, read only. Its mallocng `free()` logic is the same in every 1.2.x
  release.

## The data path and who runs it (VERIFIED, needed for everything below)

| Hop (phone -> HU video) | Context, priority | Source |
|---|---|---|
| SDIO card IRQ (in-band, DAT1) | sdhci hard IRQ, then `schedule_work` on the **system wq (kworker, nice 0)**. That worker issues **one CMD52 read of CCCR_INTx per IRQ**, because brcmfmac claims IRQs on func1 *and* func2, which turns off the core's single-function shortcut | sdhci.c 3635-3639. sdio_irq.c 30-38, 75-82, 132-136. `sdio_single_irq_set` needs `sdio_irqs == 1`. bcmsdh.c 157-161 |
| brcmf DPC (reads frames over SDIO) | `brcmf_wq`, ordered, **WQ_HIGHPRI (nice -20)** | sdio.c 4479 |
| each SDIO data transfer completes | sdhci DMA requests complete in the **threaded IRQ (SCHED_FIFO 50)** | sdhci.c 3657-3673 (`sdhci_defer_done`, COOKIE_MAPPED) |
| RX to the stack | `netif_rx()` **per skb**. In process context it brackets every skb with `local_bh_disable/enable`, so TCP runs inline per segment. There is no NAPI and no GRO | brcmfmac core.c 408-431. net/core/dev.c 5853 |
| TCP wakeup of aa-proxy-rs | `tcp_data_ready` checks `sk_rcvlowat` (=1 today) | tcp_input.c 5607 |
| aa-proxy-rs (nice -10) | 2 tokio workers + `block_on` thread + **one helper thread per FFS endpoint** (usb-gadget AIO driver) | main.rs 1651-1661. usb-gadget aio/mod.rs 294-314 |
| FFS write | AIO `io_submit`, then an `eventfd` write that wakes the helper thread. f_fs **vmalloc()s a 16 KiB sg buffer per transfer** (chipidea has `sg_supported`) and copies | aio/mod.rs 340-370. f_fs.c 814-853, 1080. Chipidea udc.c 2301 |
| USB completion | chipidea hard IRQ, then `io_completion_wq`, which is **ordered, flags 0 (unbound kworker, nice 0)**. Then `eventfd`, the helper thread, `Notify`, and the tokio task | f_fs.c 900-910, 868-897, 2245 |
| per-frame flush | aa-proxy-rs waits for **every** frame's USB completion before it accepts the next frame | aa `ffs_io.rs` 121-130, `usb_functionfs.rs` 140-143 |

AA media flow control makes the *reverse* path matter for video as well. The HU's media `Config` carries
`max_unacked` (aa `src/protos/protos.proto` 505-512), so the phone stops sending media until the HU's `Ack`
has crossed USB OUT -> aa-proxy-rs -> TCP -> Wi-Fi TX. Small HU->phone messages are on the video critical path.

---

## 0. Ranked list

| # | Change | Where | Expected effect | Risk | Evidence |
|---|---|---|---|---|---|
| 1 | **Disable cpuidle LOW-POWER-IDLE (state2) during an AA session** | u2ac-aa (sysfs, or a PM QoS fd) | Removes the 300 µs ARM power-up on wakeups from deep idle, plus the **full L1+L2 clean/invalidate on every entry** and the cold-cache refill after it. These sit on every IRQ-driven wakeup of the relay. Likely the largest single latency/jitter item, and it also cuts busy time | None (runtime, reversible, a few mW) | VERIFIED code (cpuidle-imx6sx.c 17-31, 42-58, 83-97, menu.c 287-319). INFERRED magnitude |
| 2 | **CPU floor during a session** (`scaling_min_freq=528000`, or a lower `up_threshold`). Today's `sampling_down_factor=10` does **nothing** at session loads | u2ac-aa | Below `up_threshold`, ondemand goes *proportional* and resets `rate_mult` to 1. A relay at 10-25 % load settles at **198-396 MHz**, so every burst is handled 2.3-4.5x slower than at 900 MHz | Low (heat: small, the thermal trip now works) | VERIFIED (cpufreq_ondemand.c 113-145). INFERRED settle point |
| 3 | **Pipeline FFS writes:** drop the per-frame `flush_async`, bound the IN queue to 8, **clamp the chunk to ≤16384** | aa patch (ffs_io.rs, usb_functionfs.rs) | Takes the full completion round trip (IRQ, ITC ≤125 µs, nice-0 kworker, eventfd, helper thread, Notify) off the critical path of every frame, so audio no longer waits behind a video frame's completion. The clamp fixes a latent break: chipidea rejects requests above 16 KiB | Low-med (HU compatibility: order is preserved, validate on the HU) | VERIFIED (ffs_io.rs 121-130, usb-gadget mod.rs 1837-1846, ci_hdrc_imx.c 382, udc.c 1127-1131, ci.h 26-28) |
| 4 | **`SO_PRIORITY=5` on the phone socket** (802.1D UP5 = AC_VI) | aa patch (proxy.rs after `set_nodelay`) | MediaAck, touch, mic, control and the dongle's TCP ACKs win EDCA contention against the phone's bulk BE video. This lowers the latency of the path that paces video | Low (local only, DSCP unchanged on the wire) | VERIFIED mapping (brcmfmac core.c 361-363, bcdc.c 273, ip_output.c 530). INFERRED gain |
| 5 | **Cut the per-IRQ CMD52 + nice-0 hop on Wi-Fi RX:** (a) brcmfmac patch: do not claim func2's IRQ, so the single-IRQ shortcut applies. Or (b) OOB host-wake via DT if GPIO1_IO09 is WL_HOST_WAKE | kernel patch / DT | One fewer SDIO command round trip and one fewer scheduler hop per Wi-Fi interrupt. CPU and RX latency | (a) med, (b) med (wiring unknown) | VERIFIED code path. INFERRED wiring (fp/pinctrl.txt 36/168: vendor muxed IO09 in `wifigrp`, never used it: fp/interrupts.txt shows only `mmc0`) |
| 6 | **f_fs `io_completion_wq` WQ_HIGHPRI** (1 line), or drop aa-proxy-rs's boost from -10 to -5/0 | kernel patch / u2ac-aa | The USB completion worker runs at nice 0, against aa-proxy-rs at nice -10 (weight 9548 vs 1024, base slice 0.7 ms, HRTICK off). It can be delayed whenever an aa-proxy-rs thread is busy | Low | VERIFIED (f_fs.c 2245, fair.c 79, features.h + cfg). INFERRED size |
| 7 | **brcmfmac bus idle-sleep:** module param for `idletime` (0 = never) | kernel patch | After about 24 ms with no DPC, the bus sleeps (KSO cleared or HT clock off). The next packet (a touch, a MediaAck after a static screen) pays a busy-wait wake (`udelay(50)` loop) | Low-med (+chip power) | VERIFIED (sdio.c 312, 326-327, 740-772, 967-1010, 3733-3751, 4537, sdio.h 144). INFERRED wake cost / SR state |
| 8 | **Dynamic `SO_RCVLOWAT`** = bytes still missing from the current AA frame | aa patch (endpoint_reader, MD side) | Wake aa-proxy-rs once per AA frame instead of per DPC batch or segment. Fewer reads, wakeups and 16 KiB zero-fills | Low | VERIFIED kernel semantics (tcp_input.c 5607, 6121-6140, tcp.c 1829-1851). **Gate on measurement** (section 5) |
| 9 | **Copy/alloc trims in passthrough** (reuse the read buffer, no `vec![0;n]` per read/frame, no `payload.clone()`) **+ bug fix `write` -> `write_all` on TCP** | aa patch (io_tokio.rs, mitm.rs) | About 2 zero-fills, 2-3 copies and 3 allocs fewer per 16 KiB frame (≈0.5 % CPU). **Fixes silent frame truncation** when the TCP send buffer is short | Low | VERIFIED (io_tokio.rs 72-74, 147, mitm.rs 1094-1113, 4217-4221) |
| 10 | **RX FFS chunk 4096** (separate from TX) | aa patch | f_fs uses kmalloc (≤ PAGE_SIZE) instead of vmalloc+sg+vfree for every HU->phone message. 16 queued reads pin 64 KiB instead of 256 KiB (kernel) + 256 KiB (user) | Low | VERIFIED (f_fs.c 1080, usb-gadget mod.rs 323, aa ffs_io.rs 89) |
| 11 | `itc-setting = <0>` on `&usbotg2` | DT | Completion IRQ up to 125 µs earlier. Matters only while #3 is not done | Low | VERIFIED (chipidea core.c 437, 712-715) |
| 12 | brcmfmac RX batching + GRO (`gro_cells`) | kernel patch | GRO merges a DPC batch, so TCP runs once per batch: fewer dongle ACK frames (SDIO TX + airtime) and fewer wakeups | Medium | VERIFIED no NAPI/GRO today. INFERRED gain |
| 13 | Build: `-C target-feature=+thumb-mode` (size), then opt-level 2 only for hot crates | aa-build/build.sh, Cargo profile | Small CPU (the relay is syscall-bound). Thumb buys back the size budget | Low-med | VERIFIED toolchain facts. INFERRED gains |

Investigated and **rejected**: io_uring backend, alternative global allocator, PGO, global opt-level 3, FunctionFS
DMABUF, `threadirqs`, RPS/XPS, busy-poll, extra hostapd HT/VHT flags, brcmfmac module params, WMM tuning, new TCP sysctls.
Section 3 has the evidence for each.

---

## 1. CPU idle and frequency (items 1, 2)

### 1.1 LOW-POWER-IDLE is chosen during streaming, and it is expensive (VERIFIED mechanism)

- `imx6sx_cpuidle` (used by 6UL/6ULL, mach-imx6ul.c 31-33) has state 2 "LOW-POWER-IDLE": exit 300 µs, target residency
  500 µs (cpuidle-imx6sx.c 83-97). Entering it runs `imx6sx_idle_finish()`, which calls **`flush_cache_all()`**
  (clean+invalidate L1 and the A7's internal L2 by set/way), then power-gates the ARM core (lines 17-31, 42-58).
- menu picks the deepest enabled state whose `target_residency <= predicted idle`, limited only by PM QoS
  (menu.c 287-319). Nothing in this kernel limits it on 6UL. chipidea's `CI_HDRC_PMQOS` is set only for imx7ulp
  (ci_hdrc_imx.c 72-76, 475-476), and FEC's `FEC_QUIRK_HAS_PMQOS` only for imx6q (fec_main.c 127, 4205-4206). These
  are NXP's own precedent for holding a zero CPU-latency request while I/O is active.
- During a session the CPU idles between SDIO/USB IRQs for roughly 0.5-5 ms (INFERRED). Every such gap ≥ 500 µs
  predicted goes to state 2. The next IRQ is then serviced ≥ 300 µs late, on cold caches.

Fix (pick one, both are runtime-only):
```sh
# u2ac-aa start(), right after aa_run (AA mode only); undo in stop()
echo 1 > /sys/devices/system/cpu/cpu0/cpuidle/state2/disable 2>/dev/null   # drivers/cpuidle/sysfs.c 287-325
# optional, for minimum latency: also state1 (WAIT, 50 us exit)
# echo 1 > /sys/devices/system/cpu/cpu0/cpuidle/state1/disable
```
Alternatively, tie it to the aa-proxy-rs supervisor's lifetime (released when the loop dies). The misc device parses
a non-4-byte write as **hex** (kernel/power/qos.c 383-397):
```sh
aa_run() { ( exec 9> /dev/cpu_dma_latency && echo 64 >&9    # 0x64 = 100 us: WFI+WAIT allowed, state2 (300 us) not
             echo -900 > /proc/self/oom_score_adj; ...
```
Cost: the ARM core stays clock-gated (WAIT) instead of power-gated when idle: some mW of leakage (INFERRED). That is
irrelevant on car power. Measure: `state*/usage` and `state*/time` deltas (section 5).

### 1.2 ondemand at session load: `sampling_down_factor` never engages (VERIFIED)

`od_update()` (cpufreq_ondemand.c 113-145) behaves like this:
- Above `up_threshold` it jumps to max and sets `rate_mult = sampling_down_factor`.
- Otherwise it sets `freq_next = min + load·(max-min)/100` with `RELATION_CE` and **resets `rate_mult = 1`**.

The relay is bursty but light on average. Example (INFERRED): 11 % busy at 900 MHz is 45 % at 198 MHz, which gives
198+0.45·702 ≈ 514 and selects 528. At 528 that is 19 %, giving ≈ 331 and selecting 396. It settles at 396/198 MHz and
never crosses 50 %, so the tuned `sampling_down_factor=10` (u2ac-aa 250) is inert. Each burst then runs at 0.22-0.44x
of 900 MHz speed. OPPs: 900/792/528/396/198 MHz at 1.275-0.95 V (imx6ull.dtsi 16-23).

Fix (session only, next to item 1):
```sh
echo 528000 > /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq   # or 792000; keep ondemand for the top step
# alternative: echo 25 > /sys/devices/system/cpu/cpufreq/ondemand/up_threshold  (bursts jump to 900, sdf=10 then holds 80 ms)
```
Heat (INFERRED): the busy ARM rail costs about 1.75x at 528/1.175 V versus 396/1.025 V. The idle time is in WFI/WAIT.
VDD_SOC is 1.175 V at every OPP ≤ 792 (imx6ull.dtsi 24-31), so the delta is small. The passive thermal trip works
since round 1 (cfg: THERMAL_OF, CPU_THERMAL).

---

## 2. Patches and settings (items 3-13)

### 2.1 FFS TX: pipeline, clamp, bound the queue (item 3, also items 10 and 11)

Facts (VERIFIED):
- Every i.MX gets `CI_HDRC_HAS_SHORT_PKT_LIMIT` (ci_hdrc_imx.c 382). `_ep_queue` then fails any request
  `> CI_MAX_REQ_SIZE` = 4·4096 = 16384 with `-EMSGSIZE` ("request length too big (max 16KB)", udc.c 1127-1131,
  ci.h 26-28). f_fs does not split writes (f_fs.c 1072-1083). Today `AA_FFS_CHUNK` accepts larger values, and any value
  above 16384 would break every full-size frame. 16384 is both the maximum and enough: native AA fragments are
  16120/16124 B of plaintext (aa `packet_fragment.rs` 1-14), about 16157 B on the wire with the TLS record and
  header, so **one USB transfer per video frame** at 16384.
- usb-gadget's `flush_async` waits for **all** queued completions (mod.rs 1837-1846). aa flushes after every frame
  (ffs_io.rs 124 and 130) and again in `FfsWrite::write` (usb_functionfs.rs 140-143). AIO keeps order on one
  endpoint: f_fs queues requests FIFO to the UDC. Errors of earlier transfers surface on the next `send_async` via
  `try_ready` (mod.rs 1734-1740, 1810-1818).
- Default AIO queue depth is 16 per endpoint (mod.rs 323). `with_queue_len()` sets it (mod.rs 343).

Patch sketch (`aa-build/patches/0002-ffs-pipeline.patch`, on top of 0001):
```diff
--- a/src/ffs_io.rs
+++ b/src/ffs_io.rs
-fn transfer_size(max_packet_size: usize) -> usize {
-    let want = std::env::var("AA_FFS_CHUNK")
+/// chipidea on every i.MX (CI_HDRC_HAS_SHORT_PKT_LIMIT) rejects requests > 16 KiB with -EMSGSIZE
+const UDC_MAX_REQ: usize = 16384;
+fn transfer_size(var: &str, default: usize, max_packet_size: usize) -> usize {
+    let want = std::env::var(var)
         .ok()
         .and_then(|v| v.parse::<usize>().ok())
-        .unwrap_or(16384);
+        .unwrap_or(default);
     let mps = max_packet_size.max(1);
-    (want.max(mps) / mps) * mps
+    (want.clamp(mps, UDC_MAX_REQ.max(mps)) / mps) * mps
 }
@@ IntoStreamReader
-        let context = RecvContext::new(self, transfer_size(max_packet_size));
+        // <= PAGE_SIZE keeps f_fs on kmalloc (f_fs.c 1080: use_sg only when data_len > PAGE_SIZE)
+        let context = RecvContext::new(self, transfer_size("AA_FFS_RX_CHUNK", 4096, max_packet_size));
@@ IntoSinkWriter
-        let xfer = transfer_size(max_packet_size);
+        let xfer = transfer_size("AA_FFS_CHUNK", 16384, max_packet_size);
+        let flush_each = std::env::var("AA_FFS_FLUSH").map(|v| v == "1").unwrap_or(false);
@@
                 if data_len % max_packet_size == 0 {
-                    this.flush_async().await.map_err(std::io::Error::other)?;
                     this.send_async(Bytes::new())          // ZLP, queued in order behind the data
                         .await
                         .map_err(std::io::Error::other)?;
                 }
-
-                this.flush_async().await.map_err(std::io::Error::other)?;
+                if flush_each {                            // old behaviour, for HU A/B tests
+                    this.flush_async().await.map_err(std::io::Error::other)?;
+                }
--- a/src/usb_functionfs.rs   (run_accessory_stage, ~616)
-        let (ep_in, ep_in_dir) = EndpointDirection::device_to_host();
+        let (ep_in, ep_in_dir) = EndpointDirection::device_to_host();
+        let ep_in_dir = ep_in_dir.with_queue_len(8);   // <= 8 x 16 KiB in flight (~4 ms at USB2 bulk rates)
```
`FfsWrite::write`'s own `self.inner.flush()` can stay: with the closure no longer waiting on AIO, it returns once the
submit is done. The MTP stage shares `ffs_io.rs`. Ordering is still preserved, and `AA_FFS_FLUSH=1` is the escape
hatch. Expected effect (INFERRED): about 0.1-0.3 ms less per frame on the critical path, and no head-of-line wait
for audio behind a video frame's completion. Real phones' `f_accessory` also keeps several IN requests queued
(INFERRED, AOSP).

DT, only useful while #3 is not applied (chipidea core.c 437, 712-715, the default is 1 microframe = 125 µs):
```dts
&usbotg2 { itc-setting = <0>; };   /* immediate completion IRQs; IRQ rate is already low with 16 KiB transfers */
```
Leave `CI_HDRC_DISABLE_DEVICE_STREAMING` (an imx6ul platform flag, ci_hdrc_imx.c 61-66) and the
AHB/burst settings (imx6ul.dtsi 887-889) alone. They are SoC workarounds, and USB2 bandwidth is about 10x the need.

### 2.2 SO_PRIORITY on the phone socket (item 4)

VERIFIED chain:
- `ip_queue_xmit` sets `skb->priority = sk->sk_priority` (ip_output.c 530), for data and pure ACKs.
- brcmfmac replaces it from DSCP only when it is 0 or above 7 (core.c 361-363).
- BCDC passes the 802.1D priority to the firmware (bcdc.c 273). UP 4/5 is AC_VI.

```rust
// src/proxy.rs, after `stream.set_nodelay(true)?;` (594) -- tokio backend
{
    use std::os::fd::AsRawFd;
    let prio: libc::c_int = 5; // 802.1D UP5 -> AC_VI: MediaAck/touch/mic/TCP ACKs beat the phone's BE bulk TX
    unsafe {
        libc::setsockopt(stream.as_raw_fd(), libc::SOL_SOCKET, libc::SO_PRIORITY,
            &prio as *const _ as *const libc::c_void, std::mem::size_of::<libc::c_int>() as libc::socklen_t);
    }
}
```
Use VI, not VO: Broadcom firmware commonly does not A-MPDU-aggregate VO, and the dongle sends about 400 ACKs/s at
10 Mbit/s (INFERRED). The effect is INFERRED and should show as lower p99 RTT of the probe in section 5 while video
streams.

### 2.3 SDIO interrupt path (item 5)

VERIFIED cost per Wi-Fi interrupt today:
1. sdhci hard IRQ, then `sdio_signal_irq` -> `schedule_work` (system wq, nice 0).
2. That worker runs a **CMD52 CCCR_INTx read**, because two functions hold IRQ handlers (bcmsdh.c 157-161), so
   `sdio_single_irq` is NULL.
3. Then `brcmf_sdio_isr` queues `brcmf_wq`.

(a) Kernel patch, no hardware dependency (INFERRED safe, test probe, rmmod/insmod and a long session):
```diff
--- a/drivers/net/wireless/broadcom/brcm80211/brcmfmac/bcmsdh.c
@@ brcmf_sdiod_intr_register(), in-band branch
 		sdio_claim_irq(sdiodev->func1, brcmf_sdiod_ib_irqhandler);
-		sdio_claim_irq(sdiodev->func2, brcmf_sdiod_dummy_irqhandler);
+		/* U2AC: enable F2's card interrupt without a host handler, so sdio_irqs == 1 and the
+		 * mmc core calls func1's handler directly (sdio_irq.c) instead of a CMD52 per IRQ */
+		data = brcmf_sdiod_func0_rb(sdiodev, SDIO_CCCR_IENx, &ret);
+		brcmf_sdiod_func0_wb(sdiodev, SDIO_CCCR_IENx, data | SDIO_CCCR_IEN_FUNC2, &ret);
@@ brcmf_sdiod_intr_unregister()
 		sdio_claim_host(sdiodev->func1);
-		sdio_release_irq(sdiodev->func2);
 		sdio_release_irq(sdiodev->func1);
```
This is safe for brcmfmac because its func1 ISR reads the chip's own `intstatus` regardless of which function
signalled.

(b) OOB host-wake, which also removes the system-wq hop. brcmfmac uses DT interrupt 0 of the `wifi@1` node
(of.c 142-154) and routes the chip's separate-interrupt pin itself (bcmsdh.c 105-150, `SDIO_CCCR_BRCM_SEPINT`).
**Wiring unknown:** the vendor muxed GPIO1_IO09 in `wifigrp` with WL_REG_ON (GPIO1_IO05), pad 0x17059, but its
`bcmdhd` ran in-band (fp/interrupts.txt lists no GPIO IRQ). The pin stays silent until SEPINT is enabled, so it can
only be tested with the DT change. If it is wrong, Wi-Fi does not come up. revert.
```dts
&iomuxc { pinctrl_wlan_wake: wlanwakegrp { fsl,pins = < MX6UL_PAD_GPIO1_IO09__GPIO1_IO09 0x17059 >; }; };
&usdhc1 { wifi@1 { pinctrl-names = "default"; pinctrl-0 = <&pinctrl_wlan_wake>;
                   interrupt-parent = <&gpio1>; interrupts = <9 IRQ_TYPE_LEVEL_HIGH>;  /* try LOW if no IRQs */
                   interrupt-names = "host-wake"; }; };
```
Expected effect (INFERRED): one fewer SDIO command round trip (IRQ + wake, tens of µs) and one fewer scheduler hop per
interrupt. Count `mmc0` IRQ/s in `/proc/interrupts` to size it.

### 2.4 Nice-0 kernel hops versus aa-proxy-rs at nice -10 (item 6)

VERIFIED:
- f_fs `io_completion_wq = alloc_ordered_workqueue("%s", 0, ...)` (f_fs.c 2245) runs in unbound kworkers at nice 0.
- The in-band SDIO work is also nice 0 (2.3).
- aa-proxy-rs and all its threads inherit nice -10 (u2ac-aa 209-210).
- EEVDF base slice is 0.7 ms (fair.c 79). HRTICK is off (features.h, no HRTIMER_REARM_DEFERRED in cfg).

Under load, a running aa-proxy-rs thread therefore delays these hops by up to about a slice (INFERRED). Fix:
```diff
--- a/drivers/usb/gadget/function/f_fs.c
-	ffs->io_completion_wq = alloc_ordered_workqueue("%s", 0, dev_name);
+	ffs->io_completion_wq = alloc_ordered_workqueue("%s", WQ_HIGHPRI, dev_name);
```
A no-rebuild alternative is to try `renice -n -5` or 0 for aa-proxy-rs and compare the section-5 probe. The other
userspace (hostapd, bluetoothd, httpd) is idle during a session, so the -10 boost mainly out-competes the relay's own
kernel helpers.

### 2.5 brcmfmac bus idle-sleep (item 7)

VERIFIED:
- `bus->idletime = BRCMF_IDLE_INTERVAL` (1) (sdio.c 4537).
- The watchdog runs every `BRCMF_WD_POLL` = 10 ms, which is 3 jiffies = 12 ms at HZ=250 (sdio.h 144). After
  `idlecount > idletime` ticks with no DPC (about 24 ms) it calls `brcmf_sdio_bus_sleep(bus, true)` (sdio.c 3733-3751).
- With SR it clears KSO. Waking polls `SLEEPCSR` with `udelay(50)` up to `PMU_MAX_TRANSITION_DLY/50` times
  (1 s / 50 µs, sdio.c 312, 326-327, 740-772) in the `brcmf_wq` worker.
- Without SR the HT clock is dropped and re-requested (sdio.c 967-1010).
- BCM4358 is SR-capable when PMU chipcontrol3 bit 2 is set (chip.c 1441-1454). That depends on the firmware/nvram:
  INFERRED unknown.

```diff
--- a/drivers/net/wireless/broadcom/brcm80211/brcmfmac/sdio.c
+static int brcmf_sdio_idletime = BRCMF_IDLE_INTERVAL;
+module_param_named(sdio_idletime, brcmf_sdio_idletime, int, 0444);
+MODULE_PARM_DESC(sdio_idletime, "SDIO bus idle watchdog ticks before sleep (0 = never sleep)");
@@ brcmf_sdio_probe_attach()
-	bus->idletime = BRCMF_IDLE_INTERVAL;
+	bus->idletime = brcmf_sdio_idletime;
```
Then use `mod_load brcmfmac feature_disable=0x10 sdio_idletime=0` in u2ac-aa. The probe with `-i 1` in section 5
shows the effect: a raised RTT at long intervals that disappears with the parameter.

### 2.6 Dynamic SO_RCVLOWAT (item 8, measure first)

VERIFIED:
- TCP calls `sk_data_ready` only when `tcp_epollin_ready(sk, sk_rcvlowat)` holds (tcp_input.c 5607).
- ACKs still go out while unread data is below lowat (tcp_input.c 6121-6140, the "SO_RCVLOWAT" branch).
- `tcp_set_rcvlowat` grows `sk_rcvbuf` to fit, capped at `tcp_rmem[2]/2` (tcp.c 1829-1851).

aa reads the phone socket in 16 KiB `read()`s with a freshly zeroed buffer each time (io_tokio.rs 143-158,
`incremental_read` is always false on the tokio backend, mitm.rs 4166-4186).

Sketch (MD/TCP reader only): capture `fd = stream.as_raw_fd()` before `into_split()` (proxy.rs 1037) and pass
`Some(fd)` into `endpoint_reader`. After the parse loop:
```rust
let need = if rbuf.len() < HEADER_LENGTH { HEADER_LENGTH - rbuf.len() }
    else if (rbuf[1] & FRAME_TYPE_MASK) == FRAME_TYPE_FIRST && rbuf.len() < 8 { 8 - rbuf.len() }
    else { header_size + payload_size - rbuf.len() };          // values from the incomplete frame
let want = need.clamp(1, 16 * 1024) as libc::c_int;
if want != cur_lowat { unsafe { libc::setsockopt(fd, libc::SOL_SOCKET, libc::SO_RCVLOWAT,
    &want as *const _ as *const libc::c_void, 4) }; cur_lowat = want; }
```
This is worth doing only if the measurement in section 5 shows many more aa-proxy-rs wakeups than AA frames. EEVDF
may already batch reads per DPC pass, because the HIGHPRI kworker has the earlier virtual deadline (INFERRED).

### 2.7 Copy/alloc trims and a real bug (item 9)

VERIFIED per ~16 KiB frame, phone->HU:
- calloc + zero 16 KiB per `read` (io_tokio.rs 147), then a copy into the `VecDeque`.
- `vec![0; frame_size]` + copy + `drain(..header)` memmove (mitm.rs 4217-4221).
- `transmit` builds an empty `Vec`, pushes the header, then `payload.clone()` + `append` (a realloc and 2 copies,
  mitm.rs 1094-1113).
- `CopyToBytes` copies again (ffs_io.rs 110), then the f_fs bounce copy.

Sketch:
- `endpoint_reader` keeps one `scratch = vec![0u8; BUFFER_LEN]` and passes `&mut scratch` to `read_input_data`.
- Frame extraction: `rbuf.drain(..header_size); let (a,b) = rbuf.as_slices();` copy `payload_size` bytes into
  `Vec::with_capacity`, then `rbuf.drain(..payload_size)`.
- `transmit`: `Vec::with_capacity(hdr + len)`, then `extend_from_slice(&self.payload)`.

Gain about 0.5 % CPU (INFERRED: copies are cheap at about 2 MB/s). **Bug (VERIFIED):** `IoDevice::TcpWrite` uses
`w.write(buf)` (io_tokio.rs 72-74), and `transmit` ignores the returned length (mitm.rs 1112, passthrough loop 4319).
A short TCP write silently drops the tail of a frame and desyncs the AA stream. This happens when the send buffer
fills during a Wi-Fi stall, with mic audio flowing. Fix:
`w.write_all(buf).await.map(|_| buf.len())`.

### 2.8 RX transfer size (item 10)

With 0001, every queued OUT read is 16 KiB (ffs_io.rs 89). f_fs then builds a vmalloc'd sg buffer per read, and
again for each re-submit (f_fs.c 814-853, 1080). 16 reads stay queued (mod.rs 323). HU->phone messages are small:
acks, touch, mic. 4096 keeps the kmalloc path and pins 64 KiB instead of 256 KiB. Longer messages just span
transfers, because the HU reader parses a byte stream (mitm.rs 4186-4232). This is in the 2.1 patch
(`AA_FFS_RX_CHUNK`).

### 2.9 brcmfmac GRO (item 12, larger patch)

Today: one `netif_rx` per skb, and TCP runs inline per segment (2 / dev.c 5853). Sketch:
1. Collect the skbs of one `brcmf_sdio_readframes` pass in a local `sk_buff_head`. Those SDIO reads sleep, so BH
   cannot be disabled around them.
2. Then `local_bh_disable(); while ((skb = __skb_dequeue(&q))) brcmf_rx_frame(...); local_bh_enable();`.
3. In `brcmf_netif_rx` use `gro_cells_receive(&ifp->gro_cells, skb)`, with `gro_cells_init/destroy` per netdev and
   `select GRO_CELLS` in brcmfmac Kconfig (net/Kconfig 465-467). Cloned skbs fall back to `netif_rx`.

Expected effect (INFERRED): GRO coalesces the in-order video segments of a batch, so one ACK and one wakeup per
batch instead of per 2 segments. This cuts the dongle's SDIO TX work and its airtime contention with the phone.
Medium risk. Do it after items 1-7.

### 2.10 Build (item 13)

VERIFIED:
- The Cargo profile already has `strip`, `lto=true`, `codegen-units=1` and `panic="abort"` (aa Cargo.toml
  `[profile.release]`). build.sh also forces LTO and CU=1 and `-C target-cpu=cortex-a7`.
- The binary is 15.71 MB, `.text` 12.4 MB, and **≈5.1 MB xz** (ARM BCJ, 256 KiB dict) against about 2.6 MB rootfs
  free.
- It links **both** TLS stacks (vendored OpenSSL 3.6.3 *and* rustls/ring) and the rusty_h264 encoder, though
  passthrough uses neither.

Options:
- `thumbv7neon-unknown-linux-musleabihf` has no prebuilt std (missing from `rustup target list`, tier 3).
  `-C target-feature=+thumb-mode` exists on the installed armv7 musl target (`rustc --print target-features`).
  Add it to RUSTFLAGS. Expect roughly -20-30 % `.text` (INFERRED), and denser code for the 32 KB I-cache.
- Only with the headroom that buys, add `[profile.release.package.tokio] opt-level = 2` (likewise `bytes`,
  `usb-gadget`, `tokio-util`). Under fat LTO, per-crate opt levels survive as per-function `optsize` attributes
  (INFERRED). The expected CPU gain is small: the relay is dominated by syscalls, wakeups and kernel work.
- Making `openssl` optional (feature-gating `ssl_openssl.rs`) is the largest size lever (INFERRED, MBs), but it is not
  a performance item.

---

## 3. Investigated and rejected (with evidence)

| Idea | Verdict | Evidence |
|---|---|---|
| **io_uring backend** | **Not applicable** | aa `main.rs` 1523-1532 exits if built with `io-uring` and not in DHU mode. The FFS endpoints are AIO+`AsyncFd` bound to the multi-thread runtime, and tokio-uring runs a separate runtime (usb_functionfs.rs 17-32, Cargo.toml `[features]` comment). The kernel has `# CONFIG_IO_URING is not set` (base.fragment, cfg), and adding it costs tens of KB against about 30 KB of kernel headroom (KERNEL_AUDIT). Even if bridged, the gain is at most one helper-thread hop per transfer (about 150-250/s): well under 1 % CPU (INFERRED). VERIFIED |
| **mimalloc / jemalloc** | **No** | mallocng `free()` does **not** madvise (`USE_MADV_FREE 0`, musl glue.h 27, free.c 119-127). Group munmap churn is damped by the bounce heuristic (free.c 38-70). The allocation rate is about 10 per frame, so under 2000/s at 10 Mbit/s: under 0.1 % CPU even at several hundred ns each (INFERRED). An allocator adds code size and RSS (mimalloc segments, INFERRED +≈1 MB) for no measurable gain. Fix the zero-fills and copies instead (2.7) |
| **PGO** | **Not feasible on stable** | No `profiler_builtins` rlib in the `armv7-unknown-linux-musleabihf` sysroot (rustc 1.100.0 in u2ac-aa-build). It would need nightly `-Zbuild-std`, plus a profiling run on the unit. VERIFIED |
| Global `opt-level=3` | No | The `.text` is already 12.4 MB. +15-30 % is about +0.6-1.2 MB compressed against 2.6 MB free, for a syscall-bound relay (INFERRED). See 2.10 for the targeted variant |
| FunctionFS DMABUF zero-copy | No | It is present (f_fs.c 1631 `ffs_dmabuf_transfer`), but needs a dma-buf exporter (`# CONFIG_UDMABUF is not set`, cfg) and a crate rewrite. It saves one 16 KiB copy + vmalloc per frame: about 0.3 % (INFERRED) |
| `threadirqs` | No | Available (`IRQ_FORCED_THREADING=y`), but on 1 core it only adds a context switch per IRQ. sdhci DMA completion is already threaded (FIFO 50) |
| RPS / XPS / RFS | **Moot** | `config RPS depends on SMP && SYSFS` (net/Kconfig 305-308). There is one CPU. VERIFIED |
| busy_poll | Moot | No NAPI in brcmfmac, so there is no napi_id (SYSTEM_TUNING §2). VERIFIED |
| hostapd `[LDPC] [TX-STBC] [RX-STBC1] [MAX-AMSDU-*]`, VHT `[RXLDPC] [SU-BEAMFORMEE]`… | **Leave as is** | brcmfmac reports only SGI20/40, 20/40, DSSSCCK40, A-MPDU 64K/16 µs (HT) and SGI80 + firmware txbf bits (VHT) (cfg80211.c 7255-7322). hostapd 2.12 refuses anything else ("Driver does not support configured HT capability", hw_features.c 662-745). Even accepted flags never reach the chip: `start_ap` forwards only *vendor* IEs from hostapd's beacon (cfg80211.c 4800-4810). The firmware builds the HT/VHT IEs itself, and only the chandef (width) matters. To *see* what the firmware advertises: scan the AP from a Linux laptop (`iw dev <if> scan freq 5180`), or read firmware iovars through brcmfmac's vendor DCMD passthrough (`iw dev wlan0 vendor send 0x001018 1 <brcmf_vndr_dcmd_hdr + "ldpc_cap\0">`, vendor.c 19-116) |
| brcmfmac module params | Nothing to gain | The full list is `txglomsz` (32, host TX glom only), `debug`, `p2pon`, `feature_disable` (already 0x10), `alternative_fw_path`, `fcmode` (0: no firmware-signalled TX credits), `roamoff` (STA), `iapp` (common.c 34-70). The SDIO wq is already HIGHPRI. Item 7 adds the only useful one |
| WMM / EDCA tuning | No lever | hostapd's WME IE is dropped (SYSTEM_TUNING §3). The phone picks its own TX AC. What the dongle *can* set is the AC of its own TX: item 4 |
| ACS / other channel | Optional, not perf | `dump_survey` is registered only with firmware feature DUMP_OBSS (cfg80211.c 8392-8393), and the scan costs boot time |
| New TCP sysctls | None | `tcp_rcvbuf_low_rtt` (1 ms) does not apply at Wi-Fi RTTs. `tcp_backlog_ack_defer` is already 1. `tcp_comp_sack_*` affects SACK only (kernel Documentation/networking/ip-sysctl.rst 696-704, 914-930). The `tcp_rmem` cap stays as in SYSTEM_TUNING |

---

## 4. Corrections to round-1 documents

- SYSTEM_TUNING §7 and u2ac-aa 247-250: "`sampling_down_factor` 10 = hold top OPP ~200 ms after load" applies **only
  after** a jump to max. At session loads ondemand stays proportional and resets `rate_mult` to 1 (1.2). Use the
  floor from item 2.
- KERNEL_AUDIT §4 cpuidle ("No config change is needed … keep menu"): correct for power, but it misses the latency
  cost of LOW-POWER-IDLE: `flush_cache_all` on entry and 300 µs exit (1.1).
- KERNEL_AUDIT §2 SDIO ("brcmf_wq already WQ_HIGHPRI, nothing to set"): true for the DPC, but the **in-band SDIO
  IRQ itself** runs on the nice-0 system wq and costs one CMD52 per interrupt (2.3).
- SYSTEM_TUNING P1 / patch 0001: (a) `AA_FFS_CHUNK` must be clamped to 16384: chipidea returns -EMSGSIZE above that
  (2.1). (b) Applying 16 KiB to the OUT side moved every queued read onto f_fs's vmalloc+sg path. 4 KiB is better
  there (2.8). (c) The per-frame flush that P1 suggested dropping is still present.
- KERNEL_AUDIT §2 "Userspace": the suggested `thumbv7neon-unknown-linux-gnueabihf` is a glibc target. The musl
  equivalent has no prebuilt std. Use `+thumb-mode` on the armv7 musl target (2.10).
- Not re-proposed, but noted: SYSTEM_TUNING §3 recommended 40 MHz by default, while u2ac-aa 112-115 now prefers
  `hostapd-80.conf` whenever VHT80 is offered. Neither round has measurements to decide this.

---

## 5. Measurement plan (busybox only, before and after each item)

Run during a steady AA session with video (navigation map moving). Take two snapshots 10 s apart.
```sh
P=$(pidof aa-proxy-rs)
for s in /sys/devices/system/cpu/cpu0/cpuidle/state*; do echo "$(cat $s/name) $(cat $s/usage) $(cat $s/time)"; done  # item 1
cat /sys/devices/system/cpu/cpu0/cpufreq/stats/time_in_state                       # item 2
grep -E 'mmc0|2184200.usb' /proc/interrupts                                         # items 5, 11: IRQ/s
for t in /proc/$P/task/*; do echo "$(cat $t/comm) $(grep ctxt $t/status | tr -s '\t\n' ' ')"; done  # items 3, 8
grep -A1 '^Tcp:' /proc/net/snmp | tail -1      # InSegs (col 10) vs OutSegs (col 11): ACK ratio (items 8, 12)
grep wlan0 /proc/net/dev                         # rx bytes / 16157 ~= AA video frames
top -b -n 1 | head -15                           # aa-proxy-rs vs kworker vs irq/xx-mmc0 share
```
Decision rules:
- Item 8 pays off if the aa-proxy-worker voluntary switches per second are much greater than the AA frames per
  second.
- Item 12 pays off if OutSegs/InSegs ≈ 0.5.

Latency probe: a laptop joined to AutoKit with power save off (`iw dev <if> set power_save off`), while the
phone streams.
```sh
ping -i 0.05 -c 400 10.0.0.1   # p50/p99 under load: items 1, 2, 4, 5, 6
ping -i 1    -c 60  10.0.0.1   # long gaps: bus idle-sleep (item 7) and deep-idle wake (item 1)
```
The ICMP request follows the same SDIO IRQ -> system wq -> brcmf_wq -> softirq path as the video. The reply follows
the same TX path as MediaAck/touch, so this probe measures exactly the hops these items change.

## Sources

Repo: `ocbm/baseline/arm-imx6ul-u2ac/{kernel/*.fragment, rootfs/usr/sbin/u2ac-aa, rootfs/usr/share/u2ac/*,
dts/*}`, `aa-build/{build.sh, patches/0001-ffs-io-16k-transfers.patch, out/aa-proxy-rs}`,
`fingerprint_20261125/fp/{interrupts,pinctrl,dmesg}.txt`.

aa-proxy-rs v1.3.0: `src/{main.rs, proxy.rs, mitm.rs, io_tokio.rs, io_backend.rs, io_uring.rs, ffs_io.rs,
usb_functionfs.rs, packet_fragment.rs, protos/protos.proto}`, `Cargo.toml`.

usb-gadget 1.2.0: `src/function/custom/{mod.rs, aio/mod.rs}`.

linux-7.2.15:
- `drivers/usb/chipidea/{ci.h, ci_hdrc_imx.c, core.c, udc.c}`, `drivers/usb/gadget/function/f_fs.c`
- `drivers/mmc/core/sdio_irq.c`, `drivers/mmc/host/sdhci.c`
- `drivers/net/wireless/broadcom/brcm80211/brcmfmac/{bcmsdh.c, sdio.c, sdio.h, chip.c, core.c, bcdc.c, cfg80211.c,
  vendor.c, of.c, common.c}`
- `net/core/dev.c`, `net/ipv4/{tcp.c, tcp_input.c, ip_output.c}`, `net/wireless/util.c`, `net/Kconfig`
- `arch/arm/mach-imx/{cpuidle-imx6sx.c, mach-imx6ul.c}`, `drivers/cpuidle/{governors/menu.c, governor.c, sysfs.c}`,
  `kernel/power/qos.c`
- `drivers/cpufreq/cpufreq_ondemand.c`, `kernel/sched/{fair.c, features.h}`,
  `arch/arm/boot/dts/nxp/imx/{imx6ul,imx6ull}.dtsi`, `drivers/net/ethernet/freescale/{fec_main.c, fec.h}`
- `Documentation/networking/{ip-sysctl.rst, scaling.rst}`

hostapd 2.12 `src/ap/hw_features.c`. musl 1.2.5 `src/malloc/mallocng/{free.c, glue.h, malloc.c, meta.h}`.

Toolchain: `rustc 1.100.0` in image `u2ac-aa-build` (`rustup target list`, `--print target-features`, sysroot
listing).
