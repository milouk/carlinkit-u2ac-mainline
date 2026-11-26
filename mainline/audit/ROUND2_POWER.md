# U2AC round 2: idle power audit and idle policy (2026-11-26)

Scope: Carlinkit U2AC (i.MX6ULL 1x A7 900 MHz, 128 MB DDR3, BCM4358 over SDIO + UART), mainline 7.2.15, BusyBox init,
hostapd 2.12, BlueZ 5.87, aa-proxy-rs v1.3.0 (41e245a), powered from the car's USB port. Read-only review: no device, no
build, no repository file changed except this report. It does not repeat SYSTEM_TUNING.md / KERNEL_AUDIT.md. It builds on
them (several of their items are already in `u2ac-aa`: governor at boot, ondemand tuning, saver skip during a session,
known_devices persistence, oom/nice, supervision).

Labels: **VERIFIED** = read in the source/config/DT/script named. **INFERRED** = reasoning, typical values or public
figures for sibling parts. Needs an on-unit measurement. Paths are relative to `mainline/` unless absolute.
"Kernel src" = `u2ac-build:/build/k7215/linux-7.2.15` (the patched tree that is built). "Build config" =
`u2ac-build:/build/k7215/kbuild/nousb/.config` (09:37). Note: `audit/kernel-7.2.15.config` is **older** than the build
config (it still says `HZ_100`, the build has `HZ=250`). This report uses the build config. "aa src" =
`u2ac-aa-src:/src/aa-proxy-rs/src`. "BlueZ src" / "hostapd src" = `u2ac-build:/build/userspace/build/{bluez-5.87,hostapd-2.12}`.

---

## 0. Verdicts (read first)

1. **The two big idle costs are the 5 GHz AP and the Bluetooth paging loop. Everything else is small.**
   - The AP listens all the time. An AP cannot doze (clients may transmit at any moment), and `hostapd` keeps it up 24/7.
     brcmfmac's "AP power save" is a no-op (SYSTEM_TUNING §3). This is the largest consumer whenever no phone is
     connected: ~0.4 W at 40 MHz and ~0.55 W at 80 MHz at the radio rail (CYW4354 listen figures, §3, INFERRED for the 4358).
   - **aa-proxy-rs pages the known phone forever when it is absent (VERIFIED code).** `get_aa_profile_connection` retries
     `try_connect_bluetooth_addresses` with `.without_max_times()` (bluetooth.rs 6060-6100, line 6079). Each round is `ATTEMPTS = 3`
     connects per known phone (bluetooth.rs 45). A page to an absent phone lasts the page timeout, which is the
     controller default 5.12 s (BlueZ main.conf `PageTimeout` unset, kernel `def_page_timeout` only set through mgmt
     config, mgmt_config.c 262). Rounds are separated by a 1-2-4-5 s backoff (`bt_connect_max_delay_secs = 5` in our
     config). Steady state is about 15.4 s of paging every ~20.4 s: **~75 % radio duty** with one known phone and ~86 %
     with two (INFERRED timing from VERIFIED constants). Paging keeps the BT radio transmitting/receiving continuously.
   - The same loop also writes 2 log lines per attempt at `info` level into tmpfs, **twice** (logfile plus the console
     capture in `aa_run`). That is roughly 4 MB/day per copy (INFERRED rate) in RAM with no cap on `/run`.
2. **Second loop, same root cause: phone in range but head unit off** (garage at home, USB still powered). Phone-first
   order (`change_usb_order = false`): BT handshake → phone joins the AP → USB MTP stage waits 2 × 6 s for
   `ACCESSORY_START` → accessory stage waits 5 s → fail → `continue` → a new BT handshake (main.rs 1086-1325,
   usb_functionfs.rs 351-470). **VERIFIED code path.** It drains the dongle *and the phone* for as long as both stay in range.
3. **While aa-proxy-rs waits for the phone, the dongle cannot see the head unit at all (VERIFIED).** In phone-first order
   no gadget is bound (`usb.init()` removes every gadget, main.rs 1094-1096). With no gadget the chipidea controller is
   stopped (`hw_device_state(ci, 0)` in `ci_udc_stop`, udc.c 2184-2206) and raises no interrupts. `/sys/class/udc/<udc>/state`
   then carries no information: it reads `not attached` until the first bind (udc/core.c 1452) and afterwards **keeps its
   last value**, because `ci_udc_stop` sets no state.
   VBUS tells nothing either: the dongle is powered from VBUS, and patch 0002 forces "VBUS active" regardless of OTGSC.
   USB-level head-unit signals exist **only while a gadget is bound** (§2.1). The policy below works around this with
   time, Bluetooth activity, the UDC state during the MTP stage, and aa-proxy-rs's own HU-first mode.
4. **SoC side: little left to win in software.** cpuidle (WFI / WAIT / LOW-POWER-IDLE) is built and registered (KERNEL_AUDIT
   §4, re-checked: GPT clockevent has no `C3STOP`, so the TIMER_STOP states are allowed, tick-common.c 375-383,
   timer-imx-gpt.c 276). `NO_HZ_IDLE=y`, `HZ=250`, `HIGH_RES_TIMERS=y`. The lowest OPP is 198 MHz at 0.95 V. **LDO bypass
   is impossible** (no PMIC: the stock unit runs anatop LDOs `cpu 1.275 V`, `vddsoc 1.25 V`, fp/regulators.txt, mainline
   has no i.MX LDO-bypass code). **No DDR frequency scaling** in mainline (NXP's busfreq is BSP-only). Unused clocks are
   gated by the clk core (no `clk_ignore_unused` in the bootargs). `CONFIG_PM`, `CONFIG_SUSPEND` and `CONFIG_RFKILL` are
   off (build config).
5. **The design:** five states plus a transient WAKING: READY → (10 min, nothing) → IDLE → (2 h) → DEEP, plus SESSION and HU_OFF. IDLE/DEEP take
   the AP down (`hostapd_cli disable`), stop aa-proxy-rs's paging, keep BT page scan on, and probe the known phones with
   one remote-name page every 30 s (DEEP: 120 s). HU_OFF (the head unit went to sleep under us, or never enumerated while
   the phone was there) runs aa-proxy-rs in its own **HU-first** mode, so the head unit waking up becomes a USB event
   (`ACCESSORY_START`) and nothing pages in the meantime. **Every boot starts in READY with today's behaviour**, so a normal
   car start (USB power cycled) is unaffected (§1).
6. **Expected effect (INFERRED from public sibling-part numbers, pending measurement):** idle draw at the 5 V input falls
   from **~0.62-0.73 W (~125-145 mA)** today (~0.8-0.9 W when the 80 MHz AP config is picked) to **~0.09-0.14 W (~20-28 mA)**
   in IDLE/DEEP/HU_OFF, about **6x less**. The AP is ~70-75 % of today's idle draw (CYW4354 2x2 5 GHz listen 121 mA at
   40 MHz, 163 mA at 80 MHz) and paging ~10-15 %. The SoC+DDR floor (~50-70 mW) is what remains (§3).
7. **Wake latency:** a fresh boot is unchanged. From IDLE the phone is found within the probe period (≤ 30 s) and AA follows
   in ~5-10 s, because BT is already up and the AP comes back in ~1-3 s while the BT handshake runs (INFERRED). From HU_OFF,
   AA follows the head unit's first USB enumeration by roughly one BT handshake (INFERRED ~5-10 s).

---

## 1. The idle policy (design for `u2ac-aa`)

### 1.1 States

| State | Meaning | Wi-Fi | Bluetooth | aa-proxy-rs | CPU | LED |
|---|---|---|---|---|---|---|
| READY | boot default. Waiting for the phone, full speed | AP up | today (aa-proxy-rs pages known phones, discoverable) | phone-first (default config) | ondemand (tuned) | on |
| SESSION | AA running | AP up | as aa-proxy-rs left it | running | ondemand (tuned) | on |
| HU_OFF | phone known, head unit asleep/absent | AP **disabled** | page scan only, not discoverable | **HU-first** config (no paging until the HU sends `ACCESSORY_START`) | powersave | slow blink |
| IDLE | nothing for 10 min | AP **disabled** | page scan only, not discoverable. Probe every 30 s | **stopped** (if any known phone, else left running, it does not page) | powersave | slow blink |
| DEEP | IDLE for 2 h | AP disabled, optional Wi-Fi power-off (§2.2, gated by a test) | as IDLE, probe every 120 s | stopped | powersave | slow blink |

The policy is **never active** in dev mode (`/run/persist/u2ac-dev`), in maintenance mode (computer on USB, aa-proxy-rs
not started), or when `/run/persist/u2ac-pm-off` exists (a persisted opt-out, same mechanism as `u2ac-dev`).

### 1.2 Signals (sampled every 2 s, every 1 s in HU_OFF, all fork-light)

| Name | Test | Source |
|---|---|---|
| `US` | `read -r US < /sys/class/udc/$UDC/state`. `$UDC` = the entry whose `readlink -f` contains `2184200.usb` (board.env `NCM_UDC_MATCH`). **Only meaningful while `BOUND`**: after an unbind it is stale (`ci_udc_stop` sets no state, udc.c 2184-2206) | VERIFIED: values "not attached / powered / addressed / configured / suspended" (common.c 160-172). Chipidea sets POWERED on every bind (`ci_udc_start` → `ci_hdrc_gadget_connect(1)`, udc.c 2157-2158, 1877), ADDRESSED on SET_ADDRESS (udc.c 1235), CONFIGURED from composite (composite.c 986), SUSPENDED on bus idle (udc.c 2263-2273) and restores the previous state on resume (udc.c 2248-2256). It does **not** set DEFAULT on the first bus reset (`usb_gadget_udc_reset` only when speed is known, udc.c 1047-1048) |
| `BOUND` | `/sys/kernel/config/usb_gadget/*/UDC` contains `$UDC` | VERIFIED configfs |
| `TCP` | phone session socket: `grep -qiE '^ *[0-9]+: [0-9A-F]+:14A8 [0-9A-F:]+ 01 ' /proc/net/tcp` (already used by `state_save`) | VERIFIED u2ac-aa 66 |
| `SESSION` | `TCP` **and** `BOUND` **and** `US = configured` | INFERRED definition |
| `STA` | a Wi-Fi client is associated: `iw dev wlan0 station dump \| grep -q '^Station'` | VERIFIED tool in image |
| `ADMIN` | ssh/http client on the box: `grep -qiE ':(0016\|0050) [0-9A-F:]+ 01 ' /proc/net/tcp` (also covers ssh over NCM) | INFERRED |
| `ACL` | any BR/EDR link: a `/sys/class/bluetooth/hci0:<handle>` node exists | VERIFIED net/bluetooth/hci_sysfs.c 59. The `NEAR` probe does not create one (a remote-name request reports no Connection Complete to the host, INFERRED) |
| `NEAR` | a known phone answers one page: `hcitool -i hci0 name <addr>` prints a name (it prints nothing and still exits 0 when absent) | VERIFIED BlueZ src tools/hcitool.c cmd_name. RNR uses R2 / clock offset 0 (lib/bluetooth/hci.c 1672-1676), so keep the 5.12 s page timeout |
| `NOENUM` | seconds with `BOUND` and `US ∈ {powered, suspended}` (a gadget is presented and no live host enumerates it), summed across aa-proxy-rs's ~1-2 s unbind gaps between windows. Reset by `addressed`/`configured` or by 60 s with nothing bound | VERIFIED semantics above. A live host resets and addresses a new device within ~100-300 ms (INFERRED, USB 2.0 attach timing) |
| `SLEPT` | `US = suspended` for ≥ 3 s while `TCP` (the HU stopped SOFs under a running session) | VERIFIED state source |

### 1.3 Transitions

| From | Condition | To | Commands (§1.4 helpers) |
|---|---|---|---|
| boot | `u2ac-aa start` reached aa-proxy-rs mode | READY | today's `start()`, then `pm_loop &` |
| READY | `SESSION` | SESSION | none |
| READY | `NOENUM ≥ 40 s` and not `SESSION` (two full MTP+accessory windows: the phone came, the HU did not) | HU_OFF | `state_save; aa_restart hufirst; ap_off; bt_quiet; cpu_low; led_idle` |
| READY | 600 s with none of `SESSION`, `TCP`, `STA`, `ADMIN`, `ACL`, `BOUND` | IDLE | `state_save; [ known ] && aa_stop; ap_off; bt_quiet; cpu_low; led_idle` |
| SESSION | `TCP` gone and `SLEPT` was set | HU_OFF | as READY→HU_OFF |
| SESSION | `TCP` gone, `SLEPT` not set | READY | reset timers |
| HU_OFF | `US ∈ {addressed, configured}` (the HU enumerated the MTP stage) | WAKING | `cpu_fast; ap_on` (aa-proxy-rs already pages the phone after `ACCESSORY_START`) |
| WAKING | `SESSION` | SESSION | `cpu_tuned` |
| WAKING | 60 s after the HU enumerated, no `SESSION` (HU on, phone absent or HU dislikes HU-first) | READY | `aa_restart default; bt_loud; cpu_tuned; led_on` |
| IDLE/DEEP | `NEAR` (probe hit) or `ACL` (phone-initiated link) or `STA` | READY | `cpu_fast; ap_on; aa_restart default; bt_loud; led_on` (then `cpu_tuned` once aa-proxy-rs runs) |
| IDLE | 7200 s in IDLE | DEEP | probe period 120 s (optional `wifi_off`, §2.2) |
| any | dev / maintenance / `u2ac-pm-off` | READY, loop paused | `ap_on; aa_restart default` if they were changed |

Notes:
- The only actions that touch a running AA path are `aa_restart`/`aa_stop`. They are **never** issued during a SESSION
  (`US = configured` and `TCP`). A `TCP` without an enumerated HU is the broken loop of verdict 2, and an enumerated
  accessory with no phone after 60 s (WAKING fallback) is a dead end. Neither is a session.
- HU_OFF is self-correcting: if the detection was wrong and the HU is actually on, it enumerates the MTP gadget within one
  window and the flow continues (HU-first order). If the HU dislikes HU-first order (some HUs time out while the phone is
  still being paged), WAKING falls back to READY (phone-first) after 60 s.
- In HU-first mode aa-proxy-rs re-presents the MTP gadget about every 13-15 s (2 × 6 s window + 1 s settle + 0.5 s,
  usb_functionfs.rs 355-470, main.rs 1117-1128). The HU sees nothing while asleep. Once it wakes it sees the gadget at once
  or within one cycle.
- **IDLE option B (opt-in, `IDLE_MODE=hufirst`):** run HU-first in IDLE too, instead of stopping aa-proxy-rs and probing.
  It gives instant HU wake and no paging at all. The cost: if the car is driven **without** a phone, the HU meets an AOA
  accessory that never speaks AA once per drive (WAKING then reverts to READY after 60 s). This is HU-dependent, so it is
  not the default.

### 1.4 Helpers (exact commands, BusyBox ash, all tools are in the current image)

```sh
# --- signals ---
UDC=; for u in /sys/class/udc/*; do case $(readlink -f "$u") in */2184200.usb/*) UDC=${u##*/} ;; esac; done
udc_rd()  { US=; read -r US < "/sys/class/udc/$UDC/state" 2>/dev/null; }           # no fork
bound()   { for g in /sys/kernel/config/usb_gadget/*/UDC; do read -r b < "$g" 2>/dev/null; [ "$b" = "$UDC" ] && return 0; done; return 1; }
tcp_aa()  { grep -qiE '^ *[0-9]+: [0-9A-F]+:14A8 [0-9A-F:]+ 01 ' /proc/net/tcp; }
admin()   { grep -qiE ':(0016|0050) [0-9A-F:]+ 01 ' /proc/net/tcp; }
sta()     { iw dev wlan0 station dump 2>/dev/null | grep -q '^Station'; }
acl()     { for c in /sys/class/bluetooth/hci0:*; do [ -e "$c" ] && return 0; done; return 1; }
known()   { [ -s /run/aa-etc/known_devices ]; }
near()    { known || return 1                       # one page per known phone, <= 5.12 s each when absent
            while read -r a _; do case $a in ??:??:??:??:??:??) ;; *) continue ;; esac
                [ -n "$(timeout 8 hcitool -i hci0 name "$a" 2>/dev/null)" ] && return 0
            done < /run/aa-etc/known_devices; return 1; }

# --- Wi-Fi AP ---
HCLI="hostapd_cli -p /run/hostapd -i wlan0"
ap_off()  { $HCLI disable > /dev/null 2>&1; }       # stop_ap: SET_SSID null, C_DOWN, SET_AP 0, C_UP, mpc=1 (§2.2)
ap_on()   { $HCLI enable > /dev/null 2>&1 || { kill "$(cat /run/hostapd.pid)" 2>/dev/null; ap_up; return; }
            n=0; until $HCLI status 2>/dev/null | grep -q '^state=ENABLED'; do [ $n -ge 60 ] && break; sleep 0.25; n=$((n + 1)); done
            iw dev wlan0 set txpower limit 1400 2>/dev/null; }   # re-apply: survives? unverified after C_DOWN/C_UP

# --- aa-proxy-rs ---
# aa_run gains an optional config path: aa-proxy-rs -c FILE (clap `config`, main.rs Args); the HU-first copy is NOT under
# /run/aa-etc, so the saver never persists it
hufirst_cfg() { sed -e 's/^\(  change_usb_order\) = .*/\1 = true/' \
                    -e 's/^\(  usb_gadget_require_accessory_start\) = .*/\1 = true/' /run/aa-etc/config.toml > /run/aa-hufirst.toml; }
aa_stop() { [ -s /run/aa-proxy-rs.pid ] && kill "$(cat /run/aa-proxy-rs.pid)" 2>/dev/null; rm -f /run/aa-proxy-rs.pid   # the respawn loop first
            pkill -TERM -x aa-proxy-rs 2>/dev/null                    # SIGTERM = clean disconnect (main.rs 768-790)
            n=0; while pgrep -x aa-proxy-rs > /dev/null && [ $n -lt 20 ]; do sleep 0.25; n=$((n + 1)); done
            pkill -KILL -x aa-proxy-rs 2>/dev/null; }                 # a KILLed gadget is swept by the next start (usb_functionfs.rs 283)
aa_restart() { aa_stop; case $1 in hufirst) hufirst_cfg; aa_run /run/aa-hufirst.toml ;; *) aa_run ;; esac; }

# --- Bluetooth ---
bt_quiet() { btmgmt -i hci0 discov off > /dev/null 2>&1; }   # inquiry scan off; page scan (connectable) stays on
bt_loud()  { btmgmt -i hci0 discov on  > /dev/null 2>&1; }   # aa-proxy-rs also sets it at init (bluetooth.rs 4599-4602)

# --- CPU ---
gov()       { for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo "$1" > "$g"; done 2>/dev/null; }
cpu_low()   { gov powersave; }                       # pins 198 MHz / 0.95 V (imx6ull.dtsi OPP table)
cpu_fast()  { gov performance; }                     # bring-up, as start() does at boot
cpu_tuned() { gov ondemand; O=/sys/devices/system/cpu/cpufreq/ondemand    # tunables are freed when the governor exits
              [ -d $O ] && { echo 50 > $O/up_threshold; echo 10 > $O/sampling_down_factor; } 2>/dev/null; }   # (cpufreq_governor.c 506): re-apply

# --- LED (red = vendor power LED, gpio-leds; LEDS_TRIGGER_TIMER=y) ---
led_idle() { led red blink 100 4900; }               # 2 % duty instead of 100 %
led_on()   { led red on; }
```

The loop itself (sketch, `now` = first field of `/proc/uptime`, integer part):

```sh
pm_loop() {
    st=READY; since=$(now); noenum=0; slept=0; next_probe=0; last_bound=0
    while :; do
        [ -e "$P/u2ac-pm-off" ] && { [ $st != READY ] && pm_ready; sleep 30; continue; }
        t=$(now); udc_rd
        # NOENUM accumulates across aa-proxy-rs's short unbind gaps between MTP windows; it resets only when a host
        # enumerates us, or after a minute with nothing bound (the phone left, no more attempts)
        if bound; then case $US in powered|suspended) noenum=$((noenum + 2)); last_bound=$t ;; addressed|configured) noenum=0 ;; esac
        elif [ $((t - last_bound)) -gt 60 ]; then noenum=0; fi
        if tcp_aa && bound; then case $US in suspended) slept=$((slept + 2)) ;; configured) slept=0 ;; esac; fi
        case $st in
          READY)
            if tcp_aa && bound && [ "$US" = configured ]; then st=SESSION; slept=0
            elif [ $noenum -ge 40 ]; then pm_huoff
            elif tcp_aa || sta || admin || acl || bound; then since=$t
            elif [ $((t - since)) -ge 600 ]; then pm_idle; fi ;;
          SESSION)
            tcp_aa && { since=$t; } || { if [ $slept -ge 3 ]; then pm_huoff; else st=READY; since=$t; fi; slept=0; } ;;
          HU_OFF)
            bound && case $US in addressed|configured) cpu_fast; ap_on; st=WAKING; since=$t ;; esac ;;
          WAKING)
            if tcp_aa && bound && [ "$US" = configured ]; then cpu_tuned; st=SESSION
            elif [ $((t - since)) -ge 60 ]; then pm_ready; fi ;;
          IDLE|DEEP)
            if acl || sta; then pm_ready
            elif [ $t -ge $next_probe ]; then
                if near; then pm_ready; else
                    [ $st = IDLE ] && [ $((t - since)) -ge 7200 ] && st=DEEP
                    next_probe=$((t + $([ $st = DEEP ] && echo 120 || echo 30)))
                fi
            fi ;;
        esac
        sleep "$([ $st = HU_OFF ] && echo 1 || echo 2)"
    done
}
pm_ready() { cpu_fast; ap_on; aa_restart default; bt_loud; led_on; cpu_tuned; st=READY; since=$(now); noenum=0; }
pm_idle()  { state_save; known && aa_stop; ap_off; bt_quiet; cpu_low; led_idle; st=IDLE; since=$(now); next_probe=0; }
pm_huoff() { state_save; aa_restart hufirst; ap_off; bt_quiet; cpu_low; led_idle; st=HU_OFF; since=$(now); noenum=0; }
```

`start()` calls `pm_loop &` (pid in `/run/u2ac-pm.pid`) in the `aa_run` branch only. `stop()` kills it first. `u2ac-aa
status` prints `cat /run/u2ac-pm.state`. Have the loop also write the state and reason to `$LOG` with `say` (it already has
uptime stamps).

### 1.5 Risks and guards

| Risk | Guard |
|---|---|
| Breaking a live AA session | No action is taken during a SESSION (`US = configured` and `TCP`). `aa_stop` and `aa_restart` re-check it just before acting. The saver already skips a live session (u2ac-aa 66). |
| Unit unreachable (AP down) | (1) Every boot is READY with the AP up for ≥ 10 min, so unplug/replug always recovers. (2) Any BT connection to the dongle (pair/connect from a phone's settings) raises `ACL` → READY → AP up in ~2-3 s: a manual wake that needs no unplug. (3) The policy is off in dev and maintenance modes. (4) The persisted `u2ac-pm-off` opt-out. (5) Never `rmmod` BT. |
| `hostapd_cli enable` fails after `disable` on brcmfmac | `ap_on` falls back to killing hostapd and running `ap_up` (the boot path). Test the disable/enable cycle 50× on the bench. |
| HU-first order upsets a given HU | Only used after evidence the HU was away (HU_OFF) or by opt-in (IDLE option B). WAKING reverts to phone-first after 60 s. |
| USB connect/disconnect while the HU sleeps **wakes some HUs** | A Linux EHCI host arms wake-on-connect when its port is empty and wake-on-disconnect when a device is attached (`PORT_WKCONN_E`/`PORT_WKDISC_E`, drivers/usb/host/ehci-hub.c 270-280, VERIFIED for Linux hosts). Whether that wakes the whole HU depends on its root-hub wakeup setting (INFERRED, HU-specific, most aftermarket Android HUs run Linux). Every gadget bind/unbind under a sleeping HU is such an event. Today's code already produces them: the 10 s teardown after the HU suspends, and the MTP bind of every phone-present/HU-absent cycle. HU-first mode as shipped re-binds every ~13-15 s, so HU_OFF in its interim form has **comparable churn** to today's garage loop (one bind per ~20-25 s cycle there), but without the paging and the phone loop. The proper fix is aa-proxy-rs patch (e) in §1.6: one bind, then silence until the HU wakes. IDLE binds nothing, so it produces no USB events at all. |
| Phone found by the probe, but the HU is off (garage) | READY → the phone handshakes → `NOENUM ≥ 40 s` → HU_OFF: no more paging and no more phone reconnect loop (verdict 2 fixed). |
| A wrong IDLE in a running car with no phone | Harmless: the car is on (alternator). The phone is found within one probe period once it appears. |
| Log growth (verdict 1) | IDLE stops aa-proxy-rs. HU_OFF still logs ~3-4 warning lines per 13-15 s cycle (MTP-stage timeouts), so also truncate logs over a limit in the loop: `[ $(stat -c %s F) -gt 1048576 ] && : > F` for `/run/log/aa-proxy-rs.log` and `.console`. That is safe because both are O_APPEND (aa-proxy-rs `OpenOptions::append(true)`, main.rs 527, the shell `>>`). And cap `/run` (SYSTEM_TUNING §5, not applied yet). |
| Probe paging when nobody is around | Bounded: 5.12 s per known phone per probe = 17 % duty at 30 s and 4 % at 120 s, versus ~75 % today. |
| BlueZ auto-reconnect adds paging after a link loss | `[Policy] ReconnectUUIDs` defaults include 0x1112 (HSP AG), the UUID aa-proxy-rs connects (`connect_profile(&HSP_AG_UUID)`, bluetooth.rs 6325). So after a supervision timeout BlueZ may reconnect up to 7 times over ~127 s (BlueZ src main.conf 380-392). Set `ReconnectAttempts=0` in `rootfs/etc/bluetooth/main.conf` [Policy]: aa-proxy-rs does its own reconnects. INFERRED that the policy plugin fires here. Low impact either way. |

### 1.6 Optional later steps (not needed for the main saving)

- **aa-proxy-rs patches (upstreamable):** (a) log FFS `Suspend`/`Resume` at info and write a state file
  (`/run/aa-proxy-rs.state`: waiting_bt / usb_mtp / usb_accessory / session / hu_suspended). Today they go to `debug!`
  only (usb_functionfs.rs 859-861). (b) Allow `bt_connect_max_delay_secs` above 60 (today clamped 1..60, bluetooth.rs
  5893 and 6077) and a configurable `ATTEMPTS`. (c) On `Suspend` during a session, keep the gadget bound and wait for
  `Resume` instead of the 10 s teardown. That gives an instant resume when the HU wakes and enables the next item.
  (d) Rate-limit the repeating connect/MTP warnings. (e) **HU-first without churn:** with `usb_gadget_require_accessory_start = true`,
  keep the MTP-stage gadget bound until `ACCESSORY_START` arrives instead of `MTP_WAIT_TIMEOUT = 6 s` × `MAX_TRIES = 2` and
  a re-bind (usb_functionfs.rs 355-356). For example, a `usb_gadget_mtp_wait_secs = 0` meaning "forever". HU_OFF then makes
  exactly one USB connect at entry and none while the HU sleeps.
- **Suspend-to-RAM with USB wakeup (cars that keep USB powered permanently).** This needs `CONFIG_PM_SLEEP`/`SUSPEND`.
  Mainline supports it for this exact case: `udc_suspend` keeps the pull-up when the bus is already suspended and wakeup is
  enabled (udc.c 2375-2388), and the 6UL usbmisc ops set DPDM/VBUS wakeup (usbmisc_imx.c 70-74, 140-141, 1477-1478 →
  `imx6sx_usbmisc_ops`). Costs: the radios must be unloaded around suspend. Kernel image bytes (budget is tight, KERNEL_AUDIT
  §1). No RTC driver for a safety alarm (`RTC_CLASS` off). The watchdog stops in low-power mode (imx2_wdt WDZST), so a
  failed resume strands the unit until a power cycle. Worth it only if measurements show the SoC/DDR floor dominates after
  the policy above.
- **Experimental HU-presence probe without a gadget (bench only).** The anatop USB2 charger detector can do BC1.2 data
  contact detection (a ~10 µA source on D+ that the host's 15 kΩ pull-downs pull low). Registers: anatop base
  0x020C8000 (imx6ul.dtsi `anatop@20c8000`), `USB2_CHRG_DETECT` SET 0x214 (VERIFIED phy-mxs-usb.c 83) → CLR 0x218,
  status `USB2_CHRG_DET_STAT` 0x230 (INFERRED from the 0x60 USB1→USB2 stride: 0x1d0 + 0x60), bits EN_B 20, CHK_CHRG_B 19,
  CHK_CONTACT 18, PLUG_CONTACT 0 (VERIFIED for USB1, phy-mxs-usb.c 84-94). Mainline's own detection was disabled by
  patch 0003. It is hard-coded to **USB1's** registers anyway (`mxs_charger_*` use only `ANADIG_USB1_*`, phy-mxs-usb.c
  618-760), so on this board (usbotg2) it probed the unconnected port. Use it only with no gadget bound, and always
  restore EN_B=1/CHK_CHRG_B=1. Whether an *off* HU's pull-downs disappear is HU-specific (INFERRED). Not for the shipping
  policy.

---

## 2. Evidence by question

### 2.1 Q1: telling "car off / HU asleep / host suspended" from "car on, waiting for phone"

**What the UDC reports (VERIFIED, kernel src):**
- `/sys/class/udc/<udc>/state` = `usb_state_string(gadget->state)` (udc/core.c 1839-1845, common.c 160-172). Changes are
  pushed with `sysfs_notify(..., "state")` (udc/core.c 1124-1130), so a small C helper can `poll(POLLPRI)` on the file
  instead of polling every second. BusyBox has no such tool. The shell sketch polls with the `read` builtin.
- chipidea transitions: bind/pull-up → `powered` (udc.c 1877). First bus reset: no state change (udc.c 1047-1048 only
  calls `usb_gadget_udc_reset` when the speed is already known). SET_ADDRESS → `addressed` (udc.c 1235), SET_CONFIG →
  `configured` (composite.c 986). Bus idle (no SOF, 3 ms) → SLI → `suspended` and the gadget driver's `suspend()` (udc.c
  2263-2273). Resume/port change while suspended → back to the saved state plus `resume()` (udc.c 2242-2257). Unbind: no
  state change at all (`ci_udc_stop`, udc.c 2184-2206), so the attribute is stale until the next bind sets `powered`.
  (`not attached` is set only at UDC registration, udc/core.c 1452, and on a VBUS-session end, udc.c 1893, which patch
  0002 makes impossible.)
- FunctionFS turns those callbacks into `FUNCTIONFS_SUSPEND`/`FUNCTIONFS_RESUME` events on ep0 (f_fs.c 3936-3944,
  4178-4179). The `usb-gadget` crate maps them to `Event::Suspend`/`Resume` (custom/mod.rs 1245-1264). aa-proxy-rs only
  `debug!`s them (usb_functionfs.rs 859-861), so today **only the ep0 owner (aa-proxy-rs) sees them, and it ignores them**.

**When a gadget is bound (VERIFIED, aa src):** phone-first order binds only **after** the BT handshake
(`enable_usb_if_present` after `aa_handshake`, main.rs 1317-1328): first the MTP stage (6 s window, 2 tries, legacy=true),
then the accessory gadget (5 s for `Enable`). HU-first order (`change_usb_order = true`) binds before BT (main.rs
1117-1128). With `usb_gadget_require_accessory_start = true` it never presents the accessory without a real
`ACCESSORY_START` (usb_functionfs.rs 406-409). The upstream doc says this is "useful when the car/HU sleeps while aa-proxy-rs
keeps running" (aa-proxy-rs.config.toml.upstream 173).

**The exact signals, by situation:**

| Situation | Gadget bound? | What the dongle can see | Signal to use |
|---|---|---|---|
| Car on, waiting for phone (phone-first) | no | nothing on USB (controller stopped, `state` stale) | none on USB. Time + BT (`ACL`, probe) |
| AA session, HU goes to sleep / host powers down but VBUS stays | yes | `configured` → `suspended`. FFS `Suspend`. aa-proxy-rs times out after `timeout_secs = 10` and tears down | `SLEPT` (`state = suspended` ≥ 3 s while the TCP session is up) |
| Phone connected, HU off/asleep (garage) | yes (MTP stage) | `powered` or `suspended`, never `addressed` | `NOENUM` (bound ≥ 40 s without enumeration) |
| HU wakes while aa-proxy-rs is HU-first | yes (MTP stage, re-bound every ~13-15 s) | `powered`/`suspended` → `addressed` → `configured`, then the AOA `ACCESSORY_START` (logged at info: "received AOA start request") | `state ∈ {addressed, configured}` |
| VBUS removed | - | the dongle loses power | none needed (next boot = READY) |

**VBUS sensing on this board (VERIFIED + INFERRED).** Patch 0002 adds `CI_HDRC_FORCE_VBUS_ACTIVE_ALWAYS` and bypasses
the OTG BSV path ("A bus-powered gadget has VBUS whenever it runs, whatever OTGSC says"). The gadget is therefore
connected at bind whatever the VBUS comparator says. There is no VBUS-loss event, but none is needed: losing VBUS means
losing power. Read-only check of the comparator: `devmem 0x020C8220 32`, bit 3 = USB2 VBUS_VALID (offset VERIFIED,
phy-mxs-usb.c 96/112). If it reads 0 while running, the OTG2 VBUS pin is not wired, which would explain why LIVI needed
patch 0002 (INFERRED). **Patch 0003 (no charger detection) costs nothing for idle detection.** It removes BC1.2 type
detection (SDP/CDP/DCP, a charge-only DCP port could otherwise have been recognised as "never AA"). The mainline code it
disables read USB1's registers on this USB2 port anyway (above).

### 2.2 Q2: what to turn off, how, and how fast it comes back

**Wi-Fi (brcmfmac FullMAC, BCM4358, firmware 7.112.100.4):**

| Level | Command | What happens (VERIFIED code) | Wake | Wake time |
|---|---|---|---|---|
| L0 AP up | - | firmware beacons every 102 ms. RX on continuously. AP PM is a no-op | - | - |
| L1 AP disabled | `hostapd_cli -p /run/hostapd -i wlan0 disable` | `brcmf_cfg80211_stop_ap`: SET_SSID(null), `C_DOWN`, `SET_AP 0`, `C_UP`, then `mpc=1` (cfg80211.c stop_ap, `brcmf_set_mpc` 1031-1037). With MPC and no association/scan the firmware switches the radio off. The SDIO bus then idles: the 10 ms watchdog stops and `brcmf_sdio_bus_sleep(true)` runs (sdio.c 3735-3750). The 4358 goes through the SR (save/restore) check like 4354/4356 (chip.c 1440-1452, patch 0005), so it can sleep with KSO off if the firmware enabled SR | `hostapd_cli ... enable` (hostapd src ctrl_iface.c 4247/4270) → re-runs AP setup incl. the 20/40 MHz scan | ~1-3 s (INFERRED, measure) |
| L2 Wi-Fi unpowered | stop hostapd/udhcpd, `rmmod brcmfmac_wcc brcmfmac sdhci_esdhc_imx sdhci_pltfm sdhci` | MMC power-off disables `vmmc-supply = <&reg_wlan>` → GPIO1_IO05 off (DTS usdhc1 + reg_wlan). Also stops the **50 MHz SDCLK**, which uSDHC keeps forced on while the card clock is enabled (`ESDHC_VENDOR_SPEC_FRC_SDCLK_ON`, sdhci-esdhc-imx.c 737-742, 1046) | `mod_load brcmfmac ...; mod_load brcmfmac_wcc; mod_load sdhci_esdhc_imx; iw reg set GR; ap_up` | firmware up in **0.28 s** after the host probes (boot1/r2_wifi_dmesg.txt 105.42 → 105.70 s), plus insmod forks and hostapd: ~2-4 s (INFERRED) |

- **Gate L2 on one bench test:** it is not proven that `reg_wlan` feeds only the Wi-Fi side. The DTS calls GPIO1_IO05 "the
  radio module's power switch" and the stock name is `wlreg_on` (fp/gpio.txt, fp/regulators.txt). If the module's VBAT
  goes through it, unloading sdhci also kills BT. Test: `rmmod sdhci_esdhc_imx` then `btmgmt -i hci0 info` and a page
  from a phone. Until then DEEP stays at L1.
- rfkill: not available (`# CONFIG_RFKILL is not set`, build config). `iw dev wlan0 set power_save` is STA-only.
  `ip link set wlan0 down` gives no more than L1 (`brcmf_cfg80211_down` + mpc).
- Beacon tweaks instead of AP off (`beacon_int`, hidden SSID): an AP still listens continuously, so the saving is only
  the beacon airtime (~0.3 ms per 102 ms, <1 % TX duty). Not worth it (INFERRED).
- In-session lever (not idle): `rxchain=3`/`txchain=3` in `brcmfmac4358-sdio.txt` 53-54 (2x2). A 1x1 nvram
  (`rxchain=1 txchain=1`) cuts RX power and is still far above AA's 5-20 Mbit/s. It costs diversity, needs a module
  reload, and is INFERRED. Measure before considering it.

**Bluetooth (hci_bcm serdev, BCM4358A3):**

| Level | Command | Effect | Wake |
|---|---|---|---|
| B0 today | - | aa-proxy-rs paging loop (~75 % radio duty with an absent phone) + page scan + inquiry scan (discoverable, timeout 0, bluetooth.rs 4599-4602) | - |
| B1 page scan only | stop aa-proxy-rs paging (`aa_stop`) + `btmgmt -i hci0 discov off` | page scan at the kernel defaults 1.28 s / 11.25 ms (`def_page_scan_int = 0x0800`, `window = 0x0012`, hci_core.c 2487-2489) = **0.9 % duty**. Inquiry scan off. `FastConnectable` stays off (not set in our main.conf). | instant for phone-initiated links |
| B1 + probe | `hcitool -i hci0 name <addr>` every 30/120 s | one ≤ 5.12 s page per known phone per period: 17 % / 4 % duty when absent | the probe hit itself |
| B2 adapter off | `btmgmt -i hci0 power off` | no scans. Controller still powered | `power on`. aa-proxy-rs must be restarted (it sets powered only at init) |
| B3 chip off | `rmmod hci_uart` (BT_REG_ON low through `shutdown-gpios`) | chip off | patch download again: ~1.5 s at 3 Mbaud, ~5-6 s at 115200 (SYSTEM_TUNING F3) |

- **There is no BLE advertising to tune.** `advertise = true` only makes the adapter BR/EDR-discoverable (inquiry scan,
  bluetooth.rs 4599-4602). No LE advertisement is registered anywhere in aa src (`grep -ri advertisement` finds nothing),
  and nothing starts LE scanning (`discover_devices` is used only in the experimental `bt_wireless_proxy` pairing path,
  bluetooth.rs 5579, off in our config). The "advertising" cost is the inquiry scan, which `bt_quiet` turns off.
- **Do not use B2/B3 in the policy.** BT is the wake path (probes, phone-initiated links, HU_OFF's phone page).
- **BT controller sleep mode is unavailable (VERIFIED).** hci_bcm only enables Broadcom UART sleep (`sleep_mode = 1`)
  with a host-wake IRQ and under `CONFIG_PM` (hci_bcm.c 329-422, 657-658). `CONFIG_PM` is off, and the DT node has only
  `shutdown-gpios` (radio-bcm4358.dtsi, no `device-wakeup`/`host-wakeup`). The stock GPIO list shows no wake lines
  (fp/gpio.txt: gpio-1 BT reset, 2 LED, 5 wlreg_on, 6/7 the stock "quick charge" switch, 3/9 unused). So the controller
  idles awake between scan windows. Its idle current is whatever the firmware does without sleep mode (INFERRED).
- Page timeout: keep the 5.12 s default. RNR and Create Connection use R2 page-scan repetition with no cached clock offset
  (lib/bluetooth/hci.c 1676, kernel the same when the inquiry cache is empty), so the second train can need the full
  5.12 s. A shorter `PageTimeout` would miss phones (INFERRED from the BR/EDR paging procedure).

**CPU / SoC:**
- cpuidle: driver `imx6sx_cpuidle` registered for 6UL/ULL from `imx6ul_init_late` (mach-imx6ul.c 31-37, Makefile 17-23,
  cpuidle-imx6sx.c). States: WFI. **WAIT** (ARM clock gated, exit 50 µs / residency 75 µs). **LOW-POWER-IDLE** (ARM power
  gated, 300/500 µs). `ARM_CPU_SUSPEND=y` (selected by SOC_IMX6 with CPU_IDLE, mach-imx/Kconfig 117), so `cpu_suspend` in
  state 2 is built. The GPT keeps running in WAIT (`V2_TCTL_WAITEN`, timer-imx-gpt.c 303/316). Nothing to enable.
  On the unit: `grep . /sys/devices/system/cpu/cpu0/cpuidle/state*/{name,usage,time}`.
- Lowest OPP: 198 MHz at VDDARM 0.95 V. VDDSOC stays 1.175 V at every OPP except 900 MHz (imx6ull.dtsi 14-31). In idle,
  ondemand already sits at 198 MHz (its update hook only runs when the scheduler updates utilisation, so it adds no idle
  wakeups: `cpufreq_add_update_util_hook`, cpufreq_governor.c 285/350, VERIFIED). `powersave` in IDLE only stops the shell bursts (probe, saver) from ramping to 900 MHz. Small gain, no risk.
- LDO bypass: not possible (verdict 4). The anatop LDOs burn (Vin − Vout) · I. At 198 MHz/0.95 V from a ~1.3-1.4 V input,
  about 30 % of the core power is LDO loss (INFERRED from the stock 1.275/1.25 V regulator settings). This is fixed by the
  hardware.
- DDR: no busfreq in mainline. What can help is the MMDC's automatic power-saving and self-refresh, which the boot
  loader's DCD sets up. Read-only check: `devmem 0x021B0404 32` (MMDC MAPSR: bit 0 PSD = 1 means automatic power
  saving is *disabled*) and `devmem 0x021B0004 32` (MDPDC power-down timers). INFERRED register semantics from the i.MX6
  RM. If PSD = 1, setting it to 0 is a candidate win worth measuring. It is worth up to ~10 mW: precharge standby IDD2N 21 mA
  vs power-down IDD2P 12-14 mA vs self-refresh IDD6 12 mA (max, 2 Gb DDR3L at 1.35 V, §3).
- Clock gating: done by the clk core at late init (no `clk_ignore_unused` in `bootargs`, DTS chosen). Patch 0001 only
  keeps the boot loader's AHB/PERIPH set-up on the ULL. It gates nothing on or off.
- USB PHY: with `CONFIG_PM` off and VBUS forced active, chipidea never puts the PHY or controller into low-power mode
  (runtime PM stubs, `pm_runtime_get_sync` in `ci_hdrc_gadget_connect` is a no-op). Powering USBPHY2 down by hand
  (`devmem 0x020CA000 32 0x001E1C00`, PWD register at 0x020CA000, imx6ul.dtsi `usbphy@20ca000`, offset VERIFIED
  phy-mxs-usb.c 26) would need a restore (`0`) before any gadget bind. **Not recommended**: the gain is INFERRED at a few mW (no public typical figure, §3) and a
  missed restore means no AA.
- LED: the red "power" LED is on 100 % (board-rcS.sh board_late keeps it on). A slow blink in IDLE (`led red blink 100
  4900`) saves ~98 % of its current. LED current is INFERRED at 1-5 mA (resistor unknown).

**How AA comes back fast (summary).** BT stays powered and connectable in every state. AP L1 comes back in ~1-3 s, inside
the time the BT handshake already takes, because the phone joins Wi-Fi only after the RFCOMM `WifiStartRequest`.
aa-proxy-rs restarts in ~1-2 s with a warm page cache (it is the same binary, SYSTEM_TUNING F8). L2 adds ~1 s more.
Every power-cycled car start is a fresh boot in READY, exactly as today.

### 2.3 Q3: power numbers

See §3.

### 2.4 Q4: wasteful things running now, and kernel wakeup options

| Item | Cost (idle) | Evidence | Fix |
|---|---|---|---|
| aa-proxy-rs paging loop to an absent known phone | **large** (~75 % BT radio duty) | bluetooth.rs 45, 48, 6060-6100, 6264-6390 (VERIFIED) | policy IDLE (§1) |
| Phone-present / HU-absent loop (BT handshake + Wi-Fi join + 2 MTP windows + accessory window, forever) | **large**, also drains the phone | main.rs 1086-1325, usb_functionfs.rs 351-470 (VERIFIED) | policy HU_OFF |
| AP up 24/7 | **largest** single item (§3) | hostapd.conf. SYSTEM_TUNING §3 (AP PM no-op) | policy L1 |
| Log growth during those loops: 2 info lines per page attempt (attempt + error), stored twice (logfile + `aa-proxy-rs.console`), `/run` uncapped | RAM, not power. ~4 MB/day per copy (INFERRED). Grows until tmpfs/RAM pressure evicts squashfs text | bluetooth.rs 6309, 6346 (`info!`/`warn!`), u2ac-aa 214, rcS (no `/run` cap) | truncate in the loop (O_APPEND-safe), cap `/run` |
| `state_save` every 30 s: each pass forks ~40-60 BusyBox processes (`sig` runs `find`, `sort`, one `md5sum` per file, twice per dir) even when nothing changed | small: INFERRED ~0.2-0.6 s CPU per pass at a low OPP ≈ 1-2 % CPU, enough to bounce ondemand to 900 MHz | u2ac-aa 40-58, 252 | cheap pre-check `[ -n "$(find /run/varlib/bluetooth /run/aa-etc -newer /run/persist.sig \| head -n 1)" ]` before `sig`. In IDLE/DEEP save only on entering the state |
| `usb-mode watch`: `sleep 5` + `cat` forever, although U2AC never uses OCBM (`overlay.none` exists) | negligible (0.4 fork/s) | usb-mode 184-218 | `[ -e "$R/overlay.none" ] && exec sleep 2147483647` before the loop |
| udhcpd `auto_time 30` (lease file every 30 s) | negligible | udhcpd-wlan.conf | leave (web UI uses it) |
| aa-proxy-rs internal timers: `scheduler_probe` 200 ms (1 task on 1 CPU), stall watchdog thread 2 s, `action_handler` 2 s → ~6 wakeups/s | negligible (<0.1 mW: ~6 × ~100 µs awake per second) | main.rs 1674-1710, 605-612, 936-940 (VERIFIED) | none needed (stopped in IDLE anyway) |
| `imx_thermal` polling 2 s | negligible | imx_thermal.c 81-82, 682-688 | leave (needed for throttling) |
| brcmfmac SDIO watchdog 10 ms | none when idle: it stops itself | sdio.h 144, sdio.c 3735-3750 | - |
| busybox `watchdog -t 5` | negligible | board-rcS.sh 17 | could be `-t 10` (timeout 30 s) |
| 50 MHz SDCLK while brcmfmac is loaded | small: INFERRED ~5 mW (C·V²·f ≈ 10 pF · 3.3² · 50 MHz) | sdhci-esdhc-imx.c 737-742 | only L2 removes it |
| Red LED on 100 % | small: INFERRED 3-17 mW | board-rcS.sh board_late | `led_idle` |
| BT discoverable forever (inquiry scan) | small (~0.4 % duty at the 2.56 s default) | bluetooth.rs 4599-4602 | `bt_quiet` in idle states |

**Kernel options against wakeups (build config, VERIFIED):** `NO_HZ_IDLE=y` (the tick stops in idle), `HZ=250` (its
cost only matters when busy), `HIGH_RES_TIMERS=y`, `CPU_IDLE=y` + menu governor, `CPU_FREQ_GOV_POWERSAVE=y` (present,
which the policy uses). `NO_HZ_FULL` needs SMP and is pointless here. Optional: `CONFIG_CPU_IDLE_GOV_TEO=y` (0 risk, tiny
gain on tickless systems, INFERRED). Not recommended now: `CONFIG_PM` just for runtime PM. It would let sdhci, thermal and
others runtime-suspend, but it changes many drivers' behaviour at once, and the UDC would stay held anyway (FORCE_VBUS).
Consider it only together with the suspend-to-RAM step (§1.6).
Userspace: BusyBox `powertop` is in the image (`/usr/sbin/powertop`, VERIFIED in the built squashfs) and shows
wakeups/s per source: run it in each state.

---

## 3. Power numbers (public sources)

There is no public BCM4358 datasheet. The closest public sibling is the **CYW4354** (2x2 11ac + BT 4.1, same family as
the 4354/4356/4358 that brcmfmac treats alike). Its figures are Cypress "design goals" at VBAT 3.6 V. The U2AC module is
fed 3.3 V through `reg_wlan`. i.MX6ULL figures are NXP's (AN5345 is measured on the EVK with 512 MB DDR3L, the datasheet
gives typical values). Whole-board Raspberry Pi figures are third-party measurements at 5 V.

| Component | State | Value | Conditions | Source | Type |
|---|---|---|---|---|---|
| CYW4354 Wi-Fi | **Listen** (RX on, no carrier), 1x1 / **2x2** | 5 GHz/20: 67 / 96 mA. **5 GHz/40: 80 / 121 mA**. **5 GHz/80: 102 / 163 mA** | VBAT 3.6 V | CYW4354 DS 002-14809 Rev *J, pp. 138-139 | datasheet design goal |
| CYW4354 Wi-Fi | Transmit, 100 % duty, 5 GHz/80 MCS9 14 dBm | 305 mA (1 stream) / 610 mA (2 streams) | VBAT 3.6 V | same | design goal |
| CYW4354 Wi-Fi | Sleep (not associated, host bus asleep) | 5 µA VBAT + 260 µA VIO | | same | design goal |
| CYW4354 Wi-Fi | IEEE PS (STA only), DTIM1, 5 GHz/40 | 1.5 mA | | same | design goal |
| CYW4354 | Off (WL_REG_ON and BT_REG_ON low) | 3 µA VBAT + 5.5 µA VIO | | same, Table 50 | design goal |
| CYW4354 BT | Page + inquiry scan (1.28 s / 11.25 ms) | 440 µA | assumes the controller sleeps between windows | same, Table 51 | design goal |
| CYW4354 BT | Inquiry scan only | 217 µA | | same | design goal |
| CYW4354 BT | ACL DM1/DH1 master (active link) | 25.3 mA | | same | design goal |
| CYW4354 BT | BLE advertising 1.28 s | 55 µA | (not used by aa-proxy-rs) | same | design goal |
| TI CC2564 BT | Page scan / page + inquiry scan / full throughput | 320 µA / 445 µA / ~41 mA | 3.6 V, 10 dBm | TI SWRS121E §5.3.2.1 | datasheet |
| CSR BC4 BT | Idle ACL slave without sniff | 75.3 mW | 3.3 V | Blom et al. 2008, Table 11 | measured, 3rd party |
| Paging an absent device | - | **no public number** | proxy: the radio is active for the whole page timeout, like an active link (~25-40 mA) | - | - |
| i.MX6ULL | SYSTEM IDLE (CPU in WFI, 528 PLL on, LDO enabled, DDR in self-refresh) | 9 mA @1.275 V + 9.7 mA @3.0 V = **40.7 mW** (I/O and DRAM excluded) | | IMX6ULLCEC Rev 1.3, Table 15 | datasheet typical |
| i.MX6ULL | LOW POWER IDLE (all PLLs off, RC osc, DDR self-refresh) | 5.48 mW | needs busfreq: **not reachable on mainline** | same | datasheet typical |
| i.MX6ULL | "System Idle" (AXI 24 MHz, AHB 3 MHz, PLLs off) | 20.6 mW incl. DDR rail | **busfreq-dependent** | AN5345 Rev 2, Table 2 | measured (EVK) |
| i.MX6ULL | DSM suspend | 10.67 mW incl. DDR self-refresh (SOC rail lowered to 0.92 V by a PMIC) | not available here (no PMIC, no SUSPEND) | AN5345, Table 1 | measured |
| i.MX6ULL | Dhrystone 528 / 800 / 900 MHz | 270 / 375 / 407 mW (incl. DDR ~14 mW) | busy, not idle | AN5345, Tables 3-5 | measured |
| i.MX6ULL | USB PHY | max 50 mA per active PHY on USB_OTGx_VBUS. Powered down 5.1 µA | no typical active-idle figure published | IMX6ULLCEC Tables 13, 16 | datasheet |
| DDR3L 2 Gb x16 (Micron, proxy for the 1 Gb part) | IDD2N / IDD2P / IDD6 (self-refresh) | 21 / 12-14 / 12 mA max @1.35 V | max values. Typical lower | Micron MT41K128M16 Table 8 | datasheet max |
| MX25L12835F NOR | standby / deep power-down | 10 µA / 2 µA typ | | Macronix PM1795 Table 17 | datasheet |
| Raspberry Pi 3 as AP | beacons only, no clients | 1.59 W board. Beacon interval 100→900 ms saves ≤ 1.6 % | 802.11n | Kowal & Staniec, IJET 2020 | measured, 3rd party |
| Pi Zero 2 W | idle. disable-wifi/bt + tweaks | 120 mA vs 114 mA @5 V | | CNX Software 2021 | measured, 3rd party |
| Nexus 6P (BCM4358) | wifi.on / active / scan | 21.2 / 98 / 130 mA (whole system) | OEM power model | AOSP angler power_profile.xml | OEM model |
| AAWireless | in use | "90-330 mA" | | vendor FAQ (search snippet) | vendor claim |
| Pi Zero W with aa-proxy | idle | "100 mA" | | aa-proxy-rs issue #124 | user claim |
| Cars, USB after locking | - | ~30 s (Baleno), 1-2 min (Sorento), ~5 min (Altroz). Zoe and many Kia/Hyundai stay powered | | WirelessAndroidAutoDongle #163, aa-proxy-rs #124 | anecdotes |

**What this means for U2AC (INFERRED budget, rails at 3.3 V for the radio, ÷ ~0.85 for the 5 V converters):**

| Item | Today, no phone | IDLE | DEEP | HU_OFF |
|---|---|---|---|---|
| Wi-Fi AP 2x2 listen + beacons | 40 MHz: ~0.40-0.43 W. 80 MHz (`hostapd-80.conf`, picked automatically when VHT80 is offered, u2ac-aa 114-115): ~0.54-0.58 W | L1: ~1-5 mW | L1 (L2: ~0) | L1 |
| BT paging (~25-40 mA when active) | 75 % duty: ~60-100 mW | probe 17 %: ~14-22 mW | 4 %: ~3-5 mW | ~0 |
| BT scans (+ awake controller, no sleep mode) | ~1.5 mW + unknown | ~1 mW + unknown | same | same |
| SoC idle (WFI/WAIT/LPI, LDO mode, PLLs on, no busfreq) + DDR | ~40-55 mW + ~10-15 mW | same | same | same (+ gadget re-binds) |
| LED, USB PHY, SDCLK, regulators' quiescent | ~15-40 mW | ~10-25 mW (LED blink) | same | same |
| **Total at the rails** | **~0.53-0.62 W** (80 MHz: ~0.67-0.77 W) | **~0.08-0.12 W** | ~0.07-0.10 W | ~0.07-0.10 W |
| **At 5 V (÷0.85)** | **~0.62-0.73 W ≈ 125-145 mA** (80 MHz: ~0.8-0.9 W) | **~0.09-0.14 W ≈ 20-28 mA** | ~0.08-0.12 W | ~0.08-0.12 W |

- So the AP is ~70-75 % of today's idle draw, paging ~10-15 %, and the SoC+DDR floor ~10 %. After the policy, the SoC+DDR
  floor (~50-70 mW) dominates. Only the suspend-to-RAM step (§1.6) moves it, and even that cannot reach AN5345's 10 mW
  without a PMIC.
- Car battery, 12 V side, assuming a ~85 % efficient USB supply in the car: today ~60-70 mA (≈ 1.5-1.7 Ah/day) versus
  ~10-14 mA (≈ 0.25-0.35 Ah/day) in IDLE/DEEP. A 60 Ah battery with half its capacity usable lasts ~18-20 days on the
  dongle alone today, and ~3-4 months with the policy (the car's own parasitic draw comes on top). INFERRED.
- Session-time lever that falls out of the table (not idle): **40 MHz instead of 80 MHz saves ~42 mA of listen current
  (~0.14 W)**, and 1x1 instead of 2x2 another ~40 mA. u2ac-aa currently picks `hostapd-80.conf` whenever ch36 offers VHT80.
  SYSTEM_TUNING §3 already recommended 40 MHz for RF reasons. The power numbers back it.
- Beacon tuning is worthless, as both the CYW numbers (listen dominates) and the Pi 3 AP measurement (≤ 1.6 % from
  100→900 ms beacon interval) show.
- Unknowns that only a measurement settles: the BT controller's awake-idle current without sleep mode, the SoC's actual
  idle power with DDR clocked at 396 MHz (MMDC power-down settings, §2.2), the USB PHY idle current, and the LED current.

---

## 4. On-unit measurements to run (read-only, each takes minutes)

Measure at the 5 V input with a USB power meter (the only meaningful number for the car battery), each state for ≥ 2 min:

```
# A. today, no phone in range (AP + paging):         expect the highest idle
# B. aa-proxy-rs stopped (pkill -x aa-proxy-rs; the respawn loop: kill $(cat /run/aa-proxy-rs.pid) first)
# C. B + hostapd_cli -p /run/hostapd -i wlan0 disable
# D. C + btmgmt -i hci0 discov off; led red blink 100 4900; powersave governor
# E. D + (bench only) rmmod brcmfmac_wcc brcmfmac sdhci_esdhc_imx sdhci_pltfm sdhci   -> then check BT still answers
# F. restore: hostapd_cli ... enable (time it: date +%s.%N before/after state=ENABLED); u2ac-aa aa-now
grep . /sys/devices/system/cpu/cpu0/cpuidle/state*/{name,usage,time}     # cpuidle actually used
cat /sys/devices/system/cpu/cpu0/cpufreq/stats/time_in_state
powertop                                                                  # wakeups/s per state
devmem 0x020C8220 32      # USB2 VBUS_VALID (bit 3)
devmem 0x021B0404 32      # MMDC MAPSR (bit 0 PSD)
devmem 0x021B0004 32      # MMDC MDPDC
cat /sys/class/udc/*/state                                                # in each USB situation of §2.1
ls /sys/class/bluetooth/                                                  # hci0:<handle> while a phone is linked
```

The A−B difference is the paging loop, B−C the AP, C−D LED+scan+CPU, and D−E the Wi-Fi chip's own floor plus SDCLK.

---

## Sources

Local (VERIFIED): `ocbm/baseline/arm-imx6ul-u2ac/rootfs/usr/sbin/u2ac-aa`, `.../etc/baseline/board-rcS.sh`,
`.../usr/share/u2ac/{aa-proxy-rs.config.toml,aa-proxy-rs.config.toml.upstream,hostapd.conf,udhcpd-wlan.conf}`,
`.../etc/bluetooth/main.conf`, `.../lib/firmware/brcm/brcmfmac4358-sdio.txt`, `.../dts/{imx6ull-ccpa-baseline.dts,
radio-bcm4358.dtsi}`, `.../patches/000{1,2,3,5}-*.patch`, `.../kernel/*.fragment`, `ocbm/baseline/common/rootfs/
{etc/inittab,etc/init.d/rcS,usr/sbin/usb-mode,usr/sbin/led}`, `ocbm/baseline/common/shared/net-up`, `boot1/r2_wifi_dmesg.txt`,
`fingerprint_20261125/fp/{gpio.txt,regulators.txt,scripts.txt,usb.txt}`. Build config `u2ac-build:/build/k7215/kbuild/nousb/.config`.
Built squashfs listing `u2ac-build:/build/k7215/out/nousb/rootfs.img` (hostapd_cli, hcitool, btmgmt, devmem, powertop present,
inotifyd absent. BusyBox `FEATURE_SH_NOFORK` off).
Kernel src 7.2.15: `drivers/usb/chipidea/{udc.c,ci_hdrc_imx.c,usbmisc_imx.c}`, `drivers/usb/gadget/{udc/core.c,composite.c,
function/f_fs.c}`, `drivers/usb/common/common.c`, `drivers/usb/phy/phy-mxs-usb.c`, `arch/arm/mach-imx/{Makefile,Kconfig,
cpuidle-imx6sx.c,mach-imx6ul.c}`, `arch/arm/Kconfig`, `arch/arm/boot/dts/nxp/imx/{imx6ul.dtsi,imx6ull.dtsi}`,
`kernel/time/{tick-common.c,tick-broadcast.c}`, `drivers/clocksource/timer-imx-gpt.c`, `drivers/thermal/imx_thermal.c`,
`drivers/net/wireless/broadcom/brcm80211/brcmfmac/{cfg80211.c,chip.c,sdio.c,sdio.h}`, `drivers/mmc/host/sdhci-esdhc-imx.c`,
`drivers/bluetooth/hci_bcm.c`, `net/bluetooth/{hci_core.c,hci_sysfs.c,mgmt_config.c}`.
Web (§3, fetched by a research sub-agent, copies in the session scratchpad `powerdl/`, untrusted): NXP AN5345 Rev 2
(https://www.nxp.com/docs/en/application-note/AN5345.pdf). NXP IMX6ULLCEC Rev 1.3 (https://www.nxp.com/docs/en/data-sheet/IMX6ULLCEC.pdf).
Cypress CYW4354 datasheet 002-14809 Rev *J (https://dtsheet.com/model/4804110). TI CC2564 SWRS121E
(https://www.ti.com/document-viewer/CC2560/datasheet/specifications). Blom et al. 2008 (https://www.es.mdu.se/pdf_publications/1317.pdf).
Kowal & Staniec, IJET 2020 (https://journals.pan.pl//Content/115187/PDF/23_2020.pdf). CNX Software Pi Zero 2 W power
(https://www.cnx-software.com/2021/12/09/raspberry-pi-zero-2-w-power-consumption/). raspi.tv Pi Zero W
(https://raspi.tv/2017/how-much-power-does-pi-zero-w-use). AOSP angler power_profile.xml
(https://android.googlesource.com/device/huawei/angler/+/refs/heads/master/overlay/frameworks/base/core/res/res/xml/power_profile.xml).
Micron MT41K128M16 (https://e2e.ti.com/cfs-file/__key/communityserver-discussions-components-files/791/MT41K128M16JT_2D00_125M_5F00_K.pdf).
Macronix MX25L12835F PM1795 (https://static.rapidonline.com/pdf/73-3777.pdf). AAWireless FAQ
(https://www.aawireless.io/faq/my-car-never-turns-off-the-power-will-this-drain-my-battery). GitHub
nisargjhaveri/WirelessAndroidAutoDongle#163, aa-proxy/aa-proxy-rs#124.
aa src v1.3.0: `main.rs`, `bluetooth.rs`, `usb_functionfs.rs`, `proxy.rs`. Crate `usb-gadget-1.2.0/src/function/custom/mod.rs`
(`u2ac-aa-cargo`). BlueZ 5.87: `src/main.conf`, `tools/hcitool.c`, `lib/bluetooth/hci.c`. hostapd 2.12: `hostapd/ctrl_iface.c`,
`hostapd/hostapd_cli.c`, `src/ap/hostapd.c`.
