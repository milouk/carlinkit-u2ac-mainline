#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# carsim/run.sh [--consent S] [--bin LOCAL_AA_PROXY_RS] [--dur S] [--env VAR=VALUE]... [--hu "MOCKHU ARGS"] [--hu-delay S]
# The car test without the car: dongle on the Mac's USB in maintenance mode (NCM 192.168.50.2, ssh key).
# On the dongle: aa-proxy-rs (the flashed one, or --bin copied to RAM) + fakephone (the phone); on the Mac:
# mockhu.py (the head unit, over USB). The dongle gives the port back to NCM after --dur seconds and the logs
# land in carsim/out/<time>/. RAM only on the dongle: no flash write, the flashed binary is untouched.
set -eu
D=$(cd "$(dirname "$0")" && pwd)
H=root@192.168.50.2
O="-o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
CONSENT=0 BIN= DUR=150 ENVS= HUARGS= HUDELAY=0
while [ $# -gt 0 ]; do
    case $1 in
        --consent) CONSENT=$2; shift ;;
        --bin) BIN=$2; shift ;;
        --dur) DUR=$2; shift ;;
        --env) ENVS="$ENVS $2"; shift ;;
        --hu) HUARGS=$2; shift ;;
        --hu-delay) HUDELAY=$2; shift ;;   # the car comes up late (SYNC still booting)
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
PY=${PY:-$D/.venv/bin/python}
[ -x "$PY" ] || { python3 -m venv "$D/.venv" && "$D/.venv/bin/pip" install -q pyusb; }
if [ ! -s "$D/.fakephone" ] || [ "$D/fakephone.c" -nt "$D/.fakephone" ]; then
    docker run --rm -v "$D:/c" u2ac-aa-build sh -c \
        'python3 -m ziglang cc -target arm-linux-musleabihf -static -Os -o /c/.fakephone /c/fakephone.c'
fi
OUT=$D/out/$(date +%Y%m%d-%H%M%S); mkdir -p "$OUT"
ssh $O $H 'mkdir -p /run/aatest; pgrep -x aa-proxy-rs > /dev/null && echo "aa-proxy-rs already running: not maintenance mode" && exit 1; exit 0'
scp -O $O "$D/.fakephone" $H:/run/aatest/fakephone > /dev/null
scp -O $O "$D/aatest.sh" $H:/run/aatest/aatest.sh > /dev/null
RB=/usr/bin/aa-proxy-rs
if [ -n "$BIN" ]; then scp -O $O "$BIN" $H:/run/aatest/aa-proxy-rs > /dev/null; RB=/run/aatest/aa-proxy-rs; fi
ssh $O $H "chmod +x /run/aatest/fakephone /run/aatest/aa-proxy-rs 2>/dev/null; cd /run/aatest && setsid sh ./aatest.sh $RB $DUR $ENVS < /dev/null > /dev/null 2>&1 &"
echo "carsim: aa-proxy-rs $RB started on the dongle for $DUR s (NCM drops now); car consent delay $CONSENT s"
rc=0
[ "$HUDELAY" = 0 ] || { echo "carsim: the car stays away for $HUDELAY s"; sleep "$HUDELAY"; }
"$PY" "$D/mockhu.py" --consent "$CONSENT" --wait ${HUWAIT:-60} $HUARGS 2>&1 | tee "$OUT/mockhu.log" || true
grep -q 'mockhu: 0 failure' "$OUT/mockhu.log" || rc=1
echo "carsim: waiting for NCM to come back (up to $((DUR + 90)) s)"
n=0; until ssh $O $H 'test -e /run/aatest/done' 2> /dev/null; do
    n=$((n + 1)); [ $n -gt $(((DUR + 90) / 3)) ] && { echo "carsim: dongle not back on NCM: replug it (logs lost)"; exit 1; }
    sleep 3
done
for f in ctl.log aa-proxy-rs.log stderr.log fakephone.log dmesg.txt udc.txt config.toml sample.log; do
    scp -O $O "$H:/run/aatest/$f" "$OUT/" > /dev/null 2>&1 || true
done
echo "carsim: logs in $OUT"
sed 's/\x1b\[[0-9;]*m//g' "$OUT/aa-proxy-rs.log" 2> /dev/null | grep -E 'ffs:|USB|AOA|accessory|proxy data|Timed out|No USB|restart|error|ERROR|WARN' | tail -n 40 || true
echo "--- fakephone"; cat "$OUT/fakephone.log" 2> /dev/null || true
exit $rc
