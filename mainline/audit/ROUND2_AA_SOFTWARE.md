# Round 2: Android Auto relay software for the U2AC (2026-11-26)

Scope: aa-proxy-rs upstream after what we ship (v1.3.0 = 41e245a), open-source alternatives, and the Carlinkit OTA
re-query. No device access, no builds, no Docker volumes touched. GitHub data pulled with `gh api` at ~14:00 local.

## Verdicts

1. **aa-proxy-rs: nothing newer exists. Stay on `v1.3.0` = `41e245a970465ea2ed75fcb649e38b51052c5c3a` + our
   `0001-ffs-io-16k-transfers.patch`.** `main` is identical to the tag (compare `41e245a...main`: ahead 0 / behind 0).
   No later tag or release. No side branch or open PR is worth cherry-picking: the one recent BT "tryfix" goes against
   a v1.3.0 fix, and the open legacy-mode PR targets a file that no longer exists.
2. **Two cheap follow-ups that v1.3.0 makes possible (config/launcher only, no rebuild):**
   - Set `bt_connect_attempt_timeout_secs = 10`. Today it is absent, which means 0 and the built-in 20 s. The faster
     reconnect and the new "really connected?" check only run when the option is non-zero (see 1.2).
   - The `echo 1 > /proc/sys/vm/overcommit_memory` in u2ac-aa (baseline line 226) works around the rusty_alloc 1 GiB
     arena. v1.3.0 removed that arena, and our v1.3.0 binary contains no `rusty_alloc` strings (the v1.2.0 build has 5).
     The workaround is now stale. Check VmSize/VmRSS on the unit, then drop it (go back to heuristic overcommit).
3. **Alternatives: none beats aa-proxy-rs on our constraints.** WirelessAndroidAutoDongle is unmaintained (last commit
   2025-07-27). It also needs the out-of-tree Android `f_accessory` gadget, forward-ported to 7.2. Everything else is a
   hobby fork, closed, or a different product class. Table in section 3.
4. **Vendor OTA: nothing newer than 2025.12.29.1746.** The U2AC_AUTOKIT M6 moduleUpdate reply has the same 11 module
   ids, and md5(ids) is the same `41a493712ffdf2ed2d9a15b19c2b517d.zip` (same size, 13,226,931 B). moduleRollback,
   moduleBeta and check2Box are all empty. Siblings carry *older* AA engines: U2AW module channel AndroidAuto 2024.07.19.1730,
   U2AW .img 2025.10.31.1346, A15W .img 2025.10.15.1127. All of these predate 2025.12.29, so none can hold a newer
   ARMAndroidAuto/AAaoaForword.
5. **Biggest upstream-predicted risks for us:** (a) the FunctionFS backend is only ~2 months old upstream. Nobody else
   runs it on i.MX/chipidea (zero `imx`/`chipidea` hits in 93 issues and 1,174 comments). (b) VAG head units power-cycle
   USB on transfer errors. (c) Bluetooth `br-connection-busy` and page-timeout storms. Details in section 2.

## 1. aa-proxy-rs upstream (github.com/aa-proxy/aa-proxy-rs)

### 1.1 After 41e245a: nothing
- Releases: v1.3.0 published 2026-11-26T08:49Z on 41e245a (the newest). Before it: v1.2.0 96ceaac (2026-10-30),
  v1.1.0 771f028, v1.0.0 a1a5625. https://github.com/aa-proxy/aa-proxy-rs/releases/tag/v1.3.0
- `main` HEAD = 41e245a "bump version to 1.3.0". There are no commits after it.
- Branches ahead of main (`compare main...<b>`):

| Branch / PR | What | Verdict |
|---|---|---|
| `issue/143` a703bfb (2026-11-05) "tryfix1" | `CONNECT_PROFILE_TIMEOUT` 20 s → 200 s (bluetooth.rs:48), an experiment for #143 (a second phone vs the first paired one) | **Don't take.** Goes against 47d1fe8 in v1.3.0: past ~120 s bluer's D-Bus timeout fires first, no Disconnect() is sent, and `br-connection-busy` comes back |
| `nullpointer` 94f1b8b | 5 GHz detection for integer `iw` freqs | **Already in v1.3.0** (config.rs 1039-1063, `iw_has_freq_in_range`) |
| `profiles` 8d83484 | sdr_ui profile matching | N/A (MITM only) |
| PR #103 "Reconnecting on Sony HU" (legacy mode), open | rewrites `src/usb_gadget.rs` | **Obsolete.** That file was deleted by the FunctionFS rewrite 11dd8b8 |
| PRs #146/#147/#148/#149, closed unmerged | nav-status, BT HSP, WASM store, web UI | Re-landed as separate commits in v1.3.0 (release notes "Closes #146/#147/#148/#149") |
| bt-tryfix, cargotest, dpi-fix, drop-test, ev-as-fuel, full-dbg, fullframes2, keepalive-bt-test, mitm-*, nav-remove, nodelay, pepe-test, sensor_batch_dbg, tcp-proxy | 2025 to early-2026 experiments, 270-814 commits behind | Dead |

### 1.2 What v1.3.0 already gives us (v1.2.0..v1.3.0 = 55 commits), judged for our use
| Commit(s) | Change | Relevance to U2AC | Verdict |
|---|---|---|---|
| 0a35397 | `rusty_h264` without `global-alloc`: no more 1 GiB (fallback 64 MiB) committed arena that aborted low-RAM boards (#141, aaw2b) | **Critical at 128 MB.** Verified: `out/aa-proxy-rs` (sha256 864a4c7b…) has 0 `rusty_alloc` strings. `aa-proxy-rs.v1.2.0-full` has 5 | Have it. Never ship the v1.2.0 build. Drop the overcommit=1 hack after measuring |
| c822648, f80236f | FFS: don't call ep ioctls when the host never enabled the gadget (on kernel ≥5.x `ffs_epfile_ioctl` sleeps → parked worker, `wchan=ffs_epfile_ioctl`). Unbind the MTP-stage gadget off the async worker | Our exact path (`legacy = true` runs the MTP stage, kernel 7.2) | Have it. Essential |
| 728f75a (v1.2.0) | ≥2 tokio workers even on 1-core boards. configfs/UDC ops via spawn_blocking + 10 s timeout. Runtime watchdog logs per-thread wchan | Single-core A7: before this, one blocking unbind froze the whole process | Have it. Known limits per the commit: `gadget.bind()` still synchronous, restart-token race "narrowed, not closed" (an occasional extra reconnect) |
| 31a435c, 47d1fe8, ca36fbf | `bt_connect_attempt_timeout_secs` (clamped 5-20, 0 = built-in 20 s): faster pickup of a phone that appears mid-attempt (1.85 s measured with 5 s), and success only counts if `is_connected()` (otherwise a 120 s RFCOMM wait). `bt_connect_max_delay_secs` (1-60, default 15) | Reconnect delay after car start | Have the code. **Enable it:** `bt_connect_attempt_timeout_secs = 10` (not 5: the commit warns that short limits cut slow controllers, BCM4358 over UART). Baseline already has `bt_connect_max_delay_secs = 5` |
| 1203de8, 8a15224, 588715a, e039dd4, 2dedd36, 32044c3, 74ba60f, 1b9c8db, b7b2520 | `bt_sco` call-audio bridge fixes plus new HSP responder | None: the phone keeps HFP to the car | Keep `bt_sco = false` and `bt_sco_hsp_responder = false` (both default off). The responder exists to make Android route call audio *to the dongle* |
| 520da3e, 14c736d | Docker builds without io-uring. Vendored OpenSSL | Our build.sh already does both (`--no-default-features`, `sed … vendored`) | Nothing to do |
| 49b0c81 | Persist last SDR to `/data/aa-proxy-rs/…json` | Only on the MITM path (mitm.rs:1342) | N/A |
| overlay/CVI/WASM/web pages, media tap, inject_navigation_status | Features | MITM/overlay/wasm, all off or not compiled | N/A. Web UI is larger but bound to 127.0.0.1 in our baseline |

Our patch 0001 (16 KiB FFS transfers) is not upstream. It applies cleanly on 41e245a (build-v1.3.0-ffs.log). Worth
upstreaming. Keep the `AA_FFS_CHUNK=512` escape hatch (see VAG below).

## 2. Issue/comment scan (93 issues + 1,174 comments, keyword pass, v1.3.0 era unless noted)

| Topic | Upstream evidence | Prediction for us / action |
|---|---|---|
| i.MX / chipidea | Zero hits for imx, i.MX, chipidea, ci_hdrc | We are alone on this UDC with the FunctionFS backend (introduced 11dd8b8 on 2026-09-21). Bugs here will be ours to find. If a stall happens, log the 728f75a watchdog output (`aa-proxy-worker state=… wchan=…`) |
| FunctionFS stalls / reconnect | #144 (VW ID.5, FunctionFS, v1.2.0): sessions end with `reader channel hung up`, `read_input_data: read error/timeout`, `EndpointIo read error`. The reporter's Pi4 stabilised on a separately powered (power-bank) supply. https://github.com/aa-proxy/aa-proxy-rs/issues/144 . #138 (stale accessory session after loop restart → `unexpected transfer stall`, OrangePi + Pixel 9) fixed in v1.2.0 | Mostly HU/power related, but the error strings are the ones to grep for in `/run/log/aa-proxy-rs.log` |
| VAG head units | #131, #144: VW/Audi/Skoda MIB units hard-power-cycle the USB port on transfer errors or low voltage. https://github.com/aa-proxy/aa-proxy-rs/issues/131 | If the car is VAG and loops connect/disconnect, first retest with `AA_FFS_CHUNK=512` (i.e. without our patch's effect), then try `legacy = false` |
| Broadcom / brcmfmac | #141, AAWireless CS307 (BCM43455, mainline 6.18 brcmfmac, our closest peer): (a) `wpa_pairwise=TKIP` in the template capped the AP at 802.11a 54 Mbps. Fixed with CCMP only. (b) missing regulatory.db, then embedded in the kernel (buildroot 3f24b6d, f790abb). https://github.com/aa-proxy/aa-proxy-rs/issues/141 | Our `/usr/share/u2ac/hostapd.conf` is CCMP only: OK. The aa-proxy template `out/aatree/etc/hostapd.conf.in` still has TKIP, so never let aa-proxy-rs generate our hostapd.conf. r3x ships /lib/firmware/regulatory.db (cfg80211 is a module): confirm `iw reg get` shows GR on the unit |
| Audio stutter / mic | #39 (47 comments): dropouts mostly from RF/phone. Helpful hostapd knobs: `rts_threshold=500`, `fragm_threshold=2304`, short preamble. `audio_max_unacked = 1` reportedly fixed "Hey Google" dropping words (10 made it worse). See #55. https://github.com/aa-proxy/aa-proxy-rs/issues/39 | Keep `audio_max_unacked = 0` unless voice commands miss words, then try 1. The rts/fragm knobs are for interference spots |
| Bluetooth bootstrap | #144 log analysis: about 1,950 of 2,300 connect attempts failed (`br-connection-busy/-canceled/-page-timeout`, `le-connection-abort-by-local`). #143 (open): a second phone gets ignored in favour of the first paired one | v1.3.0 clamp plus `bt_connect_attempt_timeout_secs = 10` is the mitigation. For multi-phone use, clear `known_devices` (now persisted by us) when switching phones |
| Low RAM | #141: 1 GiB arena at startup on a ~220 MB board → fixed in v1.3.0. aaw2b (RV1103, named "low-RAM" in v1.3.0 Cargo.toml) is an official v1.3.0 target. Rockchip lists the RV1103 as a single Cortex-A7 with 64 MB in-package DRAM (from the vendor spec, not checked here) | Good predictor for 128 MB. No other memory issues reported |
| Pixel phones | No Pixel-specific regression. #78 (Pixel 5 + RAV4) is phone-specific. #64 (Pixel 9 flaky) blamed on phone firmware, fixed by a phone reboot | None |
| armv7 / musl | Only old (2024-25) io_uring/kernel issues (#7), now moot (we build without io-uring) | None |

## 3. Alternatives

| Project | Stack | USB toward the car | Kernel needs on our 7.2.15 | Footprint / 1-core fit | Maintenance | Fit for U2AC |
|---|---|---|---|---|---|---|
| **aa-proxy-rs v1.3.0** (current) | Rust, static musl. BlueZ via bluer | FunctionFS in-process (AOA + optional MTP stage) | Mainline f_fs + configfs only | Our lean build is a 15.7 MB static binary (stored in xz squashfs). Official 1-core targets: rpi0w, aaw2b (RV1103) | Very active: v1.0 to v1.3 in 11 weeks, 529★ | **Best, keep** |
| nisargjhaveri/WirelessAndroidAutoDongle v0.5.0 (aawgd) https://github.com/nisargjhaveri/WirelessAndroidAutoDongle | C++ (dbus-cxx-2.0, protobuf-lite, libstdc++) | Android `f_accessory` + umtprd (FFS for MTP only) + configfs shell | Forward-port its 60 KB `0001-Backport-…Android-Accessory` + 0002 patches to 7.2 | Small RSS, 2 blocking threads with 16 KiB buffers. Ran on Pi Zero W | Dead: last commit 2025-07-27, last release 2025-03-28, 161 open issues | No: regression plus a kernel patch to carry |
| WAAD forks: joka90 (2024-05), morre95/MyWirelessAndroidAutoDongle (2026-11, 0★), TravisDuane/SG2002-… port (2026-09, 0★) | as above | as above | as above | as above | Hobby | No |
| Carlinkit stock engine (ARMAndroidAuto 491 KB + AAaoaForword 243 KB, 2025.12.29) | Closed ARM binaries | Vendor `USBDrv` modules | Vendor 3.14.52 kernel + vendor userland | Proven on this exact board | Vendor | Stock path only. Cannot run on mainline |
| AAWireless firmware / "aawireless-rs" (Snirpo WIP, cited in usb_functionfs.rs header) | Closed / unreleased | n/a | n/a | n/a | n/a | No |
| lachyn/leanlink | Debloat of vendor firmware for LiaoYuan V821B adapters | n/a | n/a | n/a | New (2026-11) | Different hardware. Not a relay |
| Phone-as-dongle apps (elezabi/wireless-aa-bridge, thucngv/aa-phone-dongle) | Android apps | n/a | n/a | n/a | n/a | N/A |

**Verdict:** aa-proxy-rs is the only maintained, mainline-kernel-clean, passthrough-capable relay. It already covers
the single-core and low-RAM cases upstream. Nothing to switch to.

## 4. Carlinkit OTA re-query (dummy uuid only)

All requests: multipart POST, exactly the stock web UI form (AutoKit.*.js, moduleRollback = the moduleUpdate fields
with a different path). `uuid=00000000000000000000000000000000`, no MAC/serial/real identifier, UA `Mozilla/5.0`. The
returned JWT payload confirms `"id":"000…0"`. mfd values reuse round 1's dummies (20231001/20240101/20250101).
cbrand/cmodel empty, cyear 0, lang 2. 20 POST + 1 HEAD, 2026-11-26 14:18-14:20.

| Query | Result |
|---|---|
| U2AC_AUTOKIT moduleUpdate M6, ver 2024.07.20.0937 (mfd 20231001 and 20240101), ver 2025.12.29.1746, and the api.paplink.cn mirror | Identical 11 modules: Boot128 2024.03.21.1830, Upg 2025.09.09.1101, USBDrv 2024.12.23.1345, HUCP 2025.12.29.1743, HUAA 2025.12.29.1744, Common 2025.12.29.1745, Service 2025.12.29.1744, CarPlay 2025.12.29.1745, AndroidAuto 2025.12.29.1746, WebAUTOKIT 2025.12.29.1433, Cus 2025.12.29.1511. md5(ids) = `41a49371…` = the zip we already have. Notes "2air修改一些已知问题" ("2air: fixed some known issues"). No BCM4358 module offered |
| U2AC moduleRollback (ver 2024.07 / 2025.12) | `total 0` |
| U2AC moduleBeta (full 2025.12.29 name:version set) | `data ["0", []]` (empty) |
| U2AC check2Box (ver 2024.10.31.1827 / 2025.12.29.1746) | empty (`ver ""`) |
| HEAD `cgi.paplink.cn:4080/file/tmp/41a49371….zip` | 200, 13,226,931 B, ETag c9d3b3 (same size). Last-Modified 2026-11-16 is a server-side regeneration, not new content |
| U2AW_AUTOKIT moduleUpdate M6 (ver 2025.10.31.1346) | 10 modules, 2024.07 era (AndroidAuto 2024.07.19.1730). Rollback empty. check2Box empty (its .img 2025.10.31.1346 is the latest) |
| A15W check2Box | from 2025.02.25.1521 → offers 2025.10.15.1127 (`20251017/IuSttKFZ_A15W_Update_2025.10.15.1127.img`, 11,342,661 B = the copy we have). From 2025.10.15.1127 → nothing newer (rollback 2025.02.25.1521). moduleUpdate: only Upg 2025.09.09.1101 |
| A2A, A2A_AUTOKIT, U2AA_AUTOKIT (guessed AA-only types) | unknown product type (`total 0` / empty) |

Sibling AA engines therefore all predate the U2AC 2025.12.29 set. U2W/U2W_* lines are CarPlay-only (no AndroidAuto
module). For reference only, no cross-flashing.

## 5. Downloads (untrusted, never executed)

Nothing new existed to download. Only the OTA replies (evidence) were saved, in
`firmware/hunt/dl/round2/ota_replies_20261126/`. To find the request format, the existing round-1 M6 zip's WebAUTOKIT
and Common modules were decrypted read-only into the session scratchpad: AES-128-CBC over whole blocks, trailing
`len % 16` bytes left in plain text. That is why a plain `openssl` run reports "bad decrypt".

| sha256 | file |
|---|---|
| 43d6bcbaf17629cde6fcbf0c56f215089db376ea71b4e3a4792539657e0a6ebc | u2ac_mu_2024.07.txt |
| 7758866672871343f75e803c42a1fc346f260b75e3a1aa717088935f07249f72 | u2ac_mu_2024.07_mfd2024.txt |
| 74ce1ac87696479ceaa57a216b6de7eab56e14782a0b7a0672754a8763b3a5ec | u2ac_mu_2025.12.txt |
| 9e391da976888a26a060775b3edfd168494870eaacdebeb3315e8368a74a5582 | u2ac_mu_api_mirror.txt |
| a5d49b2ee1440ff415a421ab7ce81fefbd452a64a7ac60e2da7e5f1414821366 | u2ac_rb_2024.07.txt |
| a191104b4b6afe1d26e9a52f835b39c0589b876dadcb898aefdacf10fd2476db | u2ac_rb_2025.12.txt |
| 4faf2c7a6f6946cf43262903d1ad30b88e5e36bd3454dd61b01912ef5891a76e | u2ac_beta_2025.12.txt |
| c64ed85fe90f2873651230cd68727d2f616a49944eafdd31762bc1d9e67ac9e2 | u2ac_c2b_2024.10.txt |
| 5408be355cc9852e4db624e5cd823302f6080eef9d381063ce9e0bf6f63db053 | u2ac_c2b_2025.12.txt |
| 5f9d19956776cffbc750ab95282348d92a37117aa4f724af1289662c25c56c23 | u2aw_mu_2025.10.txt |
| de0f7efde2ebab993aa2c71600031467020b31cb9c6a2f734336373547da7309 | u2aw_rb_2025.10.txt |
| ff0dd7858e9c1a23f70fa2d157556731a02e7bf0bdd5bd3578660244cab835e4 | u2aw_c2b_2025.10.txt |
| 1cc7eb9eab9e4de4c8af1a6080c382ef23ce5155c4e9ffbf172fab6aae7e8d97 | a15w_c2b_2025.10.txt |
| 4ee3291274f605bf35b306805ef93069d10e060706322716aa27907394174c08 | a15w_c2b_2025.02.txt |
| c235c43e6d356339a09f5feb548fd5342b5ae08bf7481d2074660c1b0763dd7f | a15w_mu_2025.10.txt |
| 229d9071933c3837c75f1daa7f009bededa79a11bb39a1201e718dbc50af9fef | a2a_mu.txt |
| ef1fd6e2a6d30c5a6ae9cedaaa1fc5c6482d44d87cc084ca6b9cd3783a4a2876 | a2a_c2b.txt |
| 3ee6116291118bca84a38a8ccbb07c6e5a5dfd5ecac73601bbe988a8651d7060 | guess_mu_A2A_AUTOKIT.txt |
| 04248fbe52d23913800bd3a33c134a6747201c5307f148c5122da3b158487e38 | guess_mu_U2AA_AUTOKIT.txt |
