#!/bin/sh
# Emulated self-test of a built U2AC rootfs (no dongle): mainline/selftest/run.sh <rootfs.img> [initramfs-init]
# Docker Desktop runs the armv7 image under qemu-user. Checks:
#  1 every ELF in the image loads (no missing shared library)
#  2 boot slots (common/shared/mtd.sh + the init's parse) under the RECOVERY busybox applets only, on a loop dev;
#    persist load all or nothing (a save cut short by a power loss restores nothing), same applets
#  3 web UI: busybox httpd + CGI, every endpoint, token auth, input validation, injection attempts
#  4 u2ac-aa start dry run (stubbed hardware) in the car / car-after-NCM / computer-on-USB / dev-forced cases
#  5 the boot's USB probe hook (rcS board_usb_probe) with a stand-in probe: car, computer, no host, late host,
#    probe failure, dev mode (the real u2ac-usbprobe needs FunctionFS: tested on the dongle in RAM)
set -u
IMG=${1:?usage: run.sh rootfs.img [init]}
D=$(cd "$(dirname "$0")" && pwd)
INIT=${2:-$D/../ocbm/baseline/arm-imx6ul-u2ac/initramfs/init}
W=$(mktemp -d /tmp/u2ac-selftest.XXXXXX)
TAG=u2ac-rootfs:selftest
FAIL=0
ok() { echo "PASS $*"; }
bad() { echo "FAIL $*"; FAIL=$((FAIL + 1)); }
run_arm() { docker run --rm --platform linux/arm/v7 "$@"; }

cp "$D"/*.sh "$W/"
sed -n '/^# boot slots: "<used>/,/^fi$/p' "$INIT" > "$W/initparse.sh"
[ -s "$W/initparse.sh" ] || bad "init: boot-slot parse block not found in $INIT"
docker run --rm -v "$(cd "$(dirname "$IMG")" && pwd):/in:ro" -v u2ac-build:/build u2ac-build sh -c \
  "unsquashfs -q -n -no-xattrs -d /tmp/r /in/$(basename "$IMG") >/dev/null 2>&1; tar -C /tmp/r -c ." \
  | docker import --platform linux/arm/v7 - "$TAG" > /dev/null || { echo "FAIL import"; exit 1; }
# the recovery busybox of the kernel being staged (RB_TOP = that build's TOP; default the 7.2.15 tree)
RB_TOP=${RB_TOP:-/build/k7215}
docker run --rm -v u2ac-build:/build -v "$W:/w" u2ac-build sh -c \
  "cp $RB_TOP/userspace/out/recovery/busybox /w/rbusybox && cp $RB_TOP/userspace/out/recovery/busybox.links /w/rbusybox.links" \
  || bad "no recovery busybox under $RB_TOP"
echo "recovery busybox: $RB_TOP"
run_arm -v "$W:/w" "$TAG" /bin/sh -c 'cp /lib/baseline/mtd.sh /w/mtd.sh'

# 1
out=$(run_arm -v "$W:/o:ro" "$TAG" /bin/sh /o/bins.sh 2>&1)
n=$(echo "$out" | grep -c '^ok '); b=$(echo "$out" | grep '^BROKEN' || true)
[ -z "$b" ] && [ "$n" -gt 10 ] && ok "binaries: $n ELF load" || bad "binaries: $b"

# 2
out=$(run_arm --privileged -v "$W:/w" "$TAG" /bin/sh -c '
  dd if=/dev/zero bs=65536 count=1 2>/dev/null | tr "\000" "\377" > /tmp/bs.img
  L=$(losetup -f); losetup "$L" /tmp/bs.img; mkdir -p /mtd /rb; ln -s "$L" /mtd/mtd9
  cp /w/rbusybox /rb/busybox; for a in $(sed "s#.*/##" /w/rbusybox.links); do ln -sf busybox /rb/$a; done
  sed -i "s#/o/#/w/#g" /w/slottest.sh
  PATH=/rb /rb/sh /w/slottest.sh; losetup -d "$L"' 2>&1)
r=$(echo "$out" | grep -o 'pass=[0-9]* fail=[0-9]*')
case $r in "pass="*" fail=0") ok "boot slots: $r under the recovery busybox" ;; *) bad "boot slots: $out" ;; esac

# 2b the init's UART window: `read -t 0.2` must wait ~0.2 s under the recovery busybox (FEATURE_SH_READ_FRAC)
out=$(run_arm -v "$W:/w" "$TAG" /bin/sh -c 'mkdir -p /rb; cp /w/rbusybox /rb/busybox; for a in sh sleep; do ln -sf busybox /rb/$a; done
  PATH=/rb /rb/sh -c "sleep 1 | { read -r a _ < /proc/uptime; read -t 0.2 _; read -r b _ < /proc/uptime; echo \$a \$b; }"' 2>&1)
dt=$(echo "$out" | awk '{ printf "%.2f", $2 - $1 }')
case $dt in 0.1*|0.2*|0.3*|0.4*) ok "recovery read -t 0.2 waits ${dt} s" ;; *) bad "recovery read -t 0.2: '$out' (${dt} s)" ;; esac

# 2c persist load is all or nothing, under the recovery busybox (recovery loads the archive too, it has no cp)
out=$(run_arm -v "$W:/w" "$TAG" /bin/sh -c 'mkdir -p /rb; cp /w/rbusybox /rb/busybox
  for a in $(sed "s#.*/##" /w/rbusybox.links); do ln -sf busybox /rb/$a; done; /bin/sh /w/persisttest.sh' 2>&1 | grep '^result')
case $out in
  *"whole_rc=0 whole_same=1 cut_rc=1 cut_files=[] "*) ok "persist: whole archive loads, one cut short loads nothing (recovery busybox)" ;;
  *) bad "persist load: $out" ;;
esac

# 3
docker rm -f u2ac-selftest-web > /dev/null 2>&1
docker run -d --name u2ac-selftest-web --platform linux/arm/v7 -p 127.0.0.1:18081:80 -v "$W:/o:ro" "$TAG" /bin/sh /o/web-setup.sh > /dev/null
sleep 4
U=http://127.0.0.1:18081
chk() { r=$(curl -s -m 30 "$@" 2>&1); case $r in *"$EXP"*) ok "web $L";; *) bad "web $L: $r";; esac; }
L="/ index"; EXP='<title>AutoKit dongle</title>'; chk "$U/"
for e in status about settings "logs?n=5&src=svc"; do L="/$e"; EXP='"ok":true'; chk "$U/cgi-bin/$e"; done
L="token made, not shown off USB on the default hotspot password"; EXP='"token":null,"why":"none"'; chk "$U/cgi-bin/token"
L="token not again"; EXP='"token":null'; chk "$U/cgi-bin/token"
T=$(docker exec u2ac-selftest-web cat /run/persist/u2ac-webtoken)
A=$U/cgi-bin/action
L="no token refused"; EXP='"code":"token"'; chk -X POST --data-binary "confirm=yes&action=mode&to=aa" "$A"
L="wrong token refused"; EXP='wrong access code'; chk -X POST --data-binary "token=0123&confirm=yes&action=mode&to=aa" "$A"
L="wifi change"; EXP='"ok":true'; chk -X POST --data-binary "token=$T&confirm=yes&action=wifi&ssid=Test+AP&psk=supersecret1&alias=Kit_1" "$A"
L="quote refused"; EXP='"code":"input"'; chk -X POST --data-binary "token=$T&confirm=yes&action=wifi&ssid=a%22b" "$A"
L="raw shell chars refused"; EXP='malformed request'; chk -X POST --data-binary "token=$T&confirm=yes&action=wifi&ssid=\$(id)" "$A"
L="encoded injection stays text"; EXP='"ok":true'; chk -X POST --data-binary "token=$T&confirm=yes&action=wifi&ssid=x%3B%24%28touch+%2Ftmp%2Fpwn%29" "$A"
L="forget one"; EXP='Forgot 1 phone'; chk -X POST --data-binary "token=$T&confirm=yes&action=forget&dev=AA%3ABB%3ACC%3ADD%3AEE%3A01" "$A"
docker exec u2ac-selftest-web sh -c '[ "$(cat /etc/aa-proxy-rs/known_devices)" = "11:22:33:44:55:66" ]' \
  && ok "web: forget also drops the phone from aa-proxy-rs known_devices" || bad "web: known_devices after forget"
L="forget path traversal refused"; EXP='not a Bluetooth address'; chk -X POST --data-binary "token=$T&confirm=yes&action=forget&dev=..%2F..%2Fetc" "$A"
L="mode"; EXP='"ok":true'; chk -X POST --data-binary "token=$T&confirm=yes&action=mode&to=maintenance" "$A"
# Wi-Fi channel width: 80 sets the flag (and settings reports it), 40 clears it, anything else is refused
L="width 80"; EXP='"ok":true'; chk -X POST --data-binary "token=$T&confirm=yes&action=width&to=80" "$A"
docker exec u2ac-selftest-web test -e /run/persist/u2ac-wifi-80 && ok "web: width 80 sets its flag" || bad "web: width 80 flag missing"
L="settings width 80"; EXP='"width":{"set":80,'; chk "$U/cgi-bin/settings"
L="width 40"; EXP='"ok":true'; chk -X POST --data-binary "token=$T&confirm=yes&action=width&to=40" "$A"
docker exec u2ac-selftest-web test ! -e /run/persist/u2ac-wifi-80 && ok "web: width 40 clears its flag" || bad "web: width 40 flag left"
L="width refused"; EXP='"code":"input"'; chk -X POST --data-binary "token=$T&confirm=yes&action=width&to=160" "$A"
# the other options: each key flips its flag (or config.toml line), settings reports it, unknown ones are refused
for kv in guard:off flightlog:off led:off btbaud:slow btpatch:0092 usbchunk:512; do
  L="option ${kv%%:*} ${kv#*:}"; EXP='"ok":true'; chk -X POST --data-binary "token=$T&confirm=yes&action=opt&key=${kv%%:*}&value=${kv#*:}" "$A"
done
docker exec u2ac-selftest-web sh -c 'cd /run/persist && test -e u2ac-hfp-guard-off && test -e u2ac-flightlog-off && test -e u2ac-led-off && test -e u2ac-bt-slowbaud && test -e u2ac-bt-0092 && test "$(cat u2ac-ffs-chunk)" = 512' \
  && ok "web: options set their flags and the chunk size" || bad "web: option flags"
L="settings options"; EXP='"opts":{"guard":"off","flightlog":"off","led":"off","btbaud":"slow","btpatch":"0092","usbchunk":512}'; chk "$U/cgi-bin/settings"
for kv in guard:on flightlog:on led:on btbaud:fast btpatch:stock usbchunk:16384; do
  L="option back ${kv%%:*}"; EXP='"ok":true'; chk -X POST --data-binary "token=$T&confirm=yes&action=opt&key=${kv%%:*}&value=${kv#*:}" "$A"
done
L="settings options default"; EXP='"opts":{"guard":"on","flightlog":"on","led":"on","btbaud":"fast","btpatch":"stock","usbchunk":16384}'; chk "$U/cgi-bin/settings"
L="option voice refused (needs MITM)"; EXP='"code":"input"'; chk -X POST --data-binary "token=$T&confirm=yes&action=opt&key=voice&value=on" "$A"
L="option unknown key refused"; EXP='"code":"input"'; chk -X POST --data-binary "token=$T&confirm=yes&action=opt&key=u2ac-dev&value=on" "$A"
L="option bad value refused"; EXP='"code":"input"'; chk -X POST --data-binary "token=$T&confirm=yes&action=opt&key=usbchunk&value=999" "$A"
L="logs flight"; EXP='"src":"flight"'; chk "$U/cgi-bin/logs?n=20&src=flight"
docker exec u2ac-selftest-web sh -c '[ ! -e /tmp/pwn ] && grep -q "^SSID=x;\$(touch /tmp/pwn)$" /run/persist/u2ac-wifi.conf' \
  && ok "web: injected text stored literally, never run" || bad "web: injection check"
# with the hotspot password changed (the wifi test above), a new code goes to its first visitor again
docker exec u2ac-selftest-web sh -c "rm -f /run/persist/u2ac-webtoken; : > /run/stub.calls"
L="token first after the hotspot password change"; EXP='"why":"first"'; chk "$U/cgi-bin/token"
sleep 1; docker exec u2ac-selftest-web sh -c 'grep -q "u2ac-aa persist" /run/stub.calls' \
  && ok "web: a new access code is saved to flash at once" || bad "web: access code not persisted"
docker rm -f u2ac-selftest-web > /dev/null 2>&1

# 4
for sc in car carncm computer dev; do
  out=$(run_arm --privileged -v "$W:/o:ro" -e SCEN=$sc "$TAG" /bin/sh /o/dry.sh 2>&1)
  # car: the probe saw AOA (NCM never up); carncm: no AOA in time, NCM came up, u2ac-aa empties the port
  case $sc in car | carncm) want='aa-proxy-rs started (USB';; computer) want='a computer is on the USB port';; dev) want='dev mode (forced)';; esac
  case $sc in car) usb='ncm udc: \[none\] usbhost=car' pv=car;; carncm) usb='ncm udc: \[\] usbhost=car' pv=noaoa;;
    computer) usb='ncm udc: \[ci_hdrc.0\] usbhost=computer' pv=noaoa;; dev) usb='ncm udc: \[ci_hdrc.0\]' pv=dev;; esac
  carish=0; case $sc in car | carncm) carish=1;; esac
  aap=-; [ $carish = 1 ] && aap=running
  led='led: color=404040 trigger=none'; [ $carish = 1 ] && led='led: color=005f7f trigger=timer'
  # flight recorder: one slot written in car mode, none in the others; squashfs bytes untouched; guard refuses
  fl='flightlog list: $'; [ $carish = 1 ] && fl='flightlog list: U2AC-FLIGHTLOG 1 seq=1 up=[0-9]* why=start+90s bytes=[0-9]'
  flc='flightlog last: 0'; [ $carish = 1 ] && flc='flightlog last: [1-9][0-9]*$'
  echo "$out" | grep -q -- "--- $usb" && echo "$out" | grep -q "usb probe: $pv (u2ac-usbprobe: test verdict $pv" \
    && { [ $sc != carncm ] || echo "$out" | grep -q 'USB: NCM off the port'; } \
    && ok "usb at boot: $sc (probe $pv)" || { bad "usb at boot: $sc"; echo "$out" | grep -- '--- ncm udc\|usb probe\|NCM off'; }
  # the hands-free guard: on by default when aa-proxy-rs runs, off with its persist flag (carncm sets it)
  case $sc in car) hg='AA_HFP_GUARD=1 ' hs=on;; carncm) hg='AA_HFP_GUARD=unset ' hs=off;; *) hg= hs=on;; esac
  if [ -z "$hg" ] || echo "$out" | grep -q "^aa-proxy-rs AA_FFS_CHUNK=16384 $hg"; then
    echo "$out" | grep -q "^hands-free guard: $hs" && ok "hands-free guard: $sc ($hs)" || bad "hands-free guard status: $sc"
  else bad "hands-free guard env: $sc"; echo "$out" | grep '^aa-proxy-rs AA_FFS'; fi
  # every module after its dependencies (busybox modprobe got this wrong on the unit), the BD address set
  # (btmgmt answered), the status light in this mode's colour
  if echo "$out" | awk '/^insmod .*\/bluetooth\.ko/ { b = NR } /^insmod .*\/hci_uart\.ko bcm_force_early_baud=1/ { h = NR }
                        END { exit !(b && h && b < h) }' \
     && echo "$out" | grep -q '^insmod .*/u2ac-ws2812\.ko' && echo "$out" | grep -q "$led" \
     && echo "$out" | grep -q '^btmgmt -i hci0 public-addr 38:BA:B0:aa:bb:cc' \
     && echo "$out" | grep -q "$want" && echo "$out" | grep -q 'AP up' && echo "$out" | grep -q 'BT up' \
     && ! echo "$out" | grep -q 'did not' && echo "$out" | grep -q '^bluetoothd *running' \
     && echo "$out" | grep -q "^aa-proxy-rs *$aap" && echo "$out" | grep -q 'ondemand up_threshold=50' \
     && echo "$out" | grep -q 'saver writes: idle=[01] pairing=1 cache-only=0' \
     && echo "$out" | grep -q '^dropbear -E -s -r /run/' && echo "$out" | grep -q 'cap_logs ok' \
     && echo "$out" | grep -q 'state2=0' && echo "$out" | grep -q 'cpu: normal (ondemand)' \
     && echo "$out" | grep -q -- "--- $fl" && echo "$out" | grep -q -- "--- $flc" \
     && echo "$out" | grep -q -- '--- squashfs region intact' \
     && echo "$out" | grep -q -- '--- pre-restore save keeps pairings: yes' \
     && echo "$out" | grep -q -- '--- known_devices: 11:22:33:44:55:66 ' \
     && echo "$out" | grep -q -- '--- flightlog guard: flight log: no area'; then ok "start dry run: $sc"
  else bad "start dry run: $sc"; echo "$out" | sed -n '/--- u2ac-aa.log/,/--- stub/p'; echo "$out" | grep -- '^--- \(flightlog\|squashfs\|led\|known\)'; fi
  # radio watch: hostapd + bluetoothd killed, then wlan0 re-created: each repaired once, aa-proxy-rs restarted
  wa=0; [ $carish = 1 ] && wa=1
  echo "$out" | grep -q -- "--- watch: hostapd=1 bluetoothd=1 aa=$wa recreate=1 ix=7" \
    && echo "$out" | grep -q '^radio repairs this boot: hostapd=2 bluetoothd=1' \
    && ok "radio watch: $sc" || { bad "radio watch: $sc"; echo "$out" | grep -- '--- watch\|watch:\|radio repairs'; }
done

# 5 the boot's USB probe hook (board_usb_probe) with a stand-in probe: return code (1 = no NCM from rcS), the
# verdict, how long rcS waits, the late-host path, the probe's MTP-stage identity
for ps in car computer nohost late fail dev; do
  out=$(run_arm --privileged -v "$W:/o:ro" -e PSCEN=$ps "$TAG" /bin/sh /o/probe.sh 2>&1 | grep '^result')
  id='ids=0x18d1:0x4ee1: product=\[aa-proxy (Carlinkit U2AC AutoKit mainline (i.MX6ULL))\]'
  case $ps in
    car) re="rc=1 ret=[01]\.[0-9] at_return=car final=car how=- udc=\[\] netup=0 sshup=0 probe=1 $id" ;;
    computer) re="rc=0 ret=[345]\.[0-9] at_return=noaoa final=noaoa how=- udc=\[\] netup=0 sshup=0 probe=1 $id" ;;
    nohost) re="rc=1 ret=[1234]\.[0-9] at_return=- final=none how=- udc=\[\] netup=0 sshup=0 probe=1 $id" ;;
    late) re="rc=1 ret=[1234]\.[0-9] at_return=- final=noaoa how=noaoa-late udc=\[\] netup=1 sshup=1 probe=1 $id" ;;
    fail) re="rc=0 ret=[234]\.[0-9] at_return=failed final=failed how=- udc=\[gone\] netup=0 sshup=0 probe=1 " ;;
    dev) re="rc=0 ret=0\.[0-9] at_return=dev final=dev how=- udc=\[gone\] netup=0 sshup=0 probe=0 ids= " ;;
  esac
  echo "$out" | grep -q "$re" && ok "usb probe hook: $ps" || bad "usb probe hook: $ps: $out"
done
rm -rf "$W"
echo "selftest: $FAIL failure(s)"
exit $FAIL
