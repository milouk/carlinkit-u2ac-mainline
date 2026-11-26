#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# aatest.sh [BIN] [SECONDS] [VAR=VALUE...]: on the dongle (maintenance mode, started detached by carsim/run.sh).
# Runs aa-proxy-rs BIN (default /usr/bin/aa-proxy-rs) in direct-TCP mode against fakephone for SECONDS (150),
# with the live config plus aa_server_tcp_addr/logfile/debug, then gives the USB port back to NCM (usb-mode ncm)
# so the Mac can ssh in again and read /run/aatest. Nothing here touches /run/aa-etc, /run/persist or flash.
T=/run/aatest
BIN=${1:-/usr/bin/aa-proxy-rs}; DUR=${2:-150}
shift 2 2> /dev/null
for kv in "$@"; do export "$kv"; done
cd "$T" || exit 1
rm -f aa-proxy-rs.log stderr.log fakephone.log dmesg.txt sample.log done
# PHONE=1: the real phone instead of fakephone (aa-proxy-rs dials the known phones over Bluetooth, the phone
# joins the AP and connects to 5288: the car flow end to end, the Mac still playing the car)
AS='127.0.0.1:5299'; [ "${PHONE:-0}" = 1 ] && AS=
sed -e "s|^  aa_server_tcp_addr = .*|  aa_server_tcp_addr = \"$AS\"|" \
    -e 's|^  logfile = .*|  logfile = "/run/aatest/aa-proxy-rs.log"|' \
    -e 's|^  debug = .*|  debug = true|' /run/aa-etc/config.toml > config.toml
dmesg -c > /dev/null 2>&1
FP=
[ "${PHONE:-0}" = 1 ] || { ./fakephone 5299 2> fakephone.log & FP=$!; }
echo "aatest: $(date) bin=$BIN dur=$DUR env: $*" > ctl.log
(cd /run/data && AA_FFS_CHUNK=${AA_FFS_CHUNK:-16384} exec "$BIN" -c "$T/config.toml" > /dev/null 2> "$T/stderr.log") &
AP=$!
# once a second: the gadget u2ac-aa's car_live reads (idProduct, UDC state), aa-proxy-rs memory, load
( while kill -0 "$AP" 2> /dev/null; do
    echo "$(cut -d' ' -f1 /proc/uptime) id=$(cat /sys/kernel/config/usb_gadget/*/idProduct 2> /dev/null | tr '\n' ,)" \
        "udc=$(cat /sys/class/udc/*/state 2> /dev/null) $(grep VmRSS /proc/$(pidof aa-proxy-rs)/status 2> /dev/null | tr -s ' ')" \
        "load=$(cut -d' ' -f1 /proc/loadavg) led=$(cat /sys/class/leds/rgb:status/color 2> /dev/null)" \
        "tcp5288=$(grep -ciE '^ *[0-9]+: [0-9A-F]+:14A8 [0-9A-F:]+ 01 ' /proc/net/tcp)"
    sleep 1; done > sample.log 2>&1 ) &
sleep "$DUR"
kill "$AP" 2> /dev/null; sleep 3; kill -9 "$AP" 2> /dev/null
[ -n "$FP" ] && kill "$FP" 2> /dev/null
dmesg > dmesg.txt 2>&1
cat /sys/class/udc/*/state > udc.txt 2>&1
usb-mode ncm >> ctl.log 2>&1
echo "aatest: done $(date)" >> ctl.log
: > done
