#!/bin/sh
# Home upload (u2ac-home) in the image: fake flight-log slots on a fake rootfs MTD, stubbed iw / wpa_supplicant /
# udhcpc / ip, the real busybox wget, nc and httpd (a CGI stands in for the Pushgateway). Run by run.sh.
set -u
pass=0; failn=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else failn=$((failn + 1)); echo "FAIL $1: got '$2' want '$3'"; fi; }
has() { if grep -q -e "$2" "$3" 2> /dev/null; then pass=$((pass + 1)); else failn=$((failn + 1)); echo "FAIL $1: no '$2' in $3"; fi; }
hasnt() { if grep -q -e "$2" "$3" 2> /dev/null; then failn=$((failn + 1)); echo "FAIL $1: '$2' in $3"; else pass=$((pass + 1)); fi; }
cs() { read -r _u _ < /proc/uptime; _c=${_u#*.}; echo $(( ${_u%.*} * 100 + ${_c#0} )); }
mk() { rm -f "$1"; printf '#!/bin/sh\n%s\n' "$2" > "$1"; chmod +x "$1"; }

mkdir -p /run/persist /run/log /fake/net/wlan0
: > /run/log/u2ac-aa.log; : > /run/calls
export U2AC_HOME_SYS=/fake/net U2AC_HOME_KEEP=2
# fake rootfs MTD: squashfs header (bytes_used 10326016) + erased flash; the flight-log area is the last 1 MiB
export MTD_SYS=/fake/mtdsys MTD_DEV=/fake/mtddev
mkdir -p $MTD_SYS/mtd3 $MTD_DEV; echo rootfs > $MTD_SYS/mtd3/name; echo 12976128 > $MTD_SYS/mtd3/size
echo 65536 > $MTD_SYS/mtd3/erasesize
tr '\000' '\377' < /dev/zero | head -c 12976128 > $MTD_DEV/mtd3
printf 'hsqs' | dd of=$MTD_DEV/mtd3 conv=notrunc 2> /dev/null
printf '\000\220\235\000\000\000\000\000' | dd of=$MTD_DEV/mtd3 bs=1 seek=40 conv=notrunc 2> /dev/null
FLOFF=$((12976128 - 1048576))
# slot SEQ WHY METRICS(1/0) [HOME] [T]: a slot as fl_write lays it out; /tmp/recs (lines) = its drive records
slot() {
    { echo "=== u2ac flight log: up 88.00 s"; echo "=== status"; echo "aa-proxy-rs  running"
      if [ "$3" = 1 ]; then
          echo "=== metrics"
          printf '# HELP u2ac_up 1 while the exporter answers\n# TYPE u2ac_up gauge\nu2ac_up 1\n'
          printf '# HELP u2ac_aa_event_seconds seconds after power-on\n# TYPE u2ac_aa_event_seconds gauge\n'
          printf 'u2ac_aa_event_seconds{event="bt_try"} 11.5\nu2ac_aa_event_seconds{event="proxying"} 2%s.3\n' "$1"
      fi
      echo "=== usb:configured gadget 0x2d00"; echo "=== tcp"; } | gzip -c > /tmp/g
    _l="U2AC-FLIGHTLOG 1 seq=$1 up=88 why=$2 bytes=$(wc -c < /tmp/g)${4:+ home=$4}${5:+ t=$5}"
    { echo "$_l"; head -c $((512 - ${#_l} - 1)) /dev/zero; cat /tmp/g; } > /tmp/slot
    dd if=/tmp/slot of=$MTD_DEV/mtd3 bs=512 seek=$(((FLOFF + ($1 % 8) * 131072) / 512)) conv=notrunc 2> /dev/null
    _r=0; [ -s /tmp/recs ] && while read -r _x; do printf '%-255.255s\n' "$_x" \
        | dd of=$MTD_DEV/mtd3 bs=256 seek=$(((FLOFF + ($1 % 8) * 131072 + 65536) / 256 + _r)) conv=notrunc 2> /dev/null; _r=$((_r + 1)); done < /tmp/recs
    rm -f /tmp/recs
}
slot 1 bench-test 0
printf '%s\n' 'D1 up=900 t=x ls=850 ses=1 err=0 ring=0 rst=0 rep=0 tmax=55 smin=-60 sta=1 dev=1 join=1 txf=2 rx=100 tx=10 mem=70000 cpu=30' \
    'D1 up=1800 t=x ls=1700 ses=2 err=1 ring=4 rst=0 rep=1 tmax=61 smin=-71 sta=2 dev=2 join=3 txf=12 rx=500000000 tx=20000000 mem=60000 cpu=35' > /tmp/recs
slot 2 session+60s 1
slot 3 start+90s 1 "" 1795870000

# stubs: the home network "Home Net" (two access points, the second stronger) while /run/home-here exists
mk /usr/sbin/iw 'echo "iw $*" >> /run/calls
case "$*" in *scan*) [ -e /run/home-here ] && printf "BSS 0a:0b:0c:0d:0e:01(on wlan0)\n\tfreq: 2437.0\n\tsignal: -70.00 dBm\n\tSSID: Home Net\nBSS 0a:0b:0c:0d:0e:02(on wlan0)\n\tfreq: 2437.0\n\tsignal: -48.00 dBm\n\tSSID: Home Net\nBSS 0a:0b:0c:0d:0e:03(on wlan0)\n\tfreq: 2412.0\n\tsignal: -30.00 dBm\n\tSSID: Home Net 2\n";; esac; exit 0'
# wpa_supplicant runs in the foreground (u2ac-home backgrounds it and logs its events): joined 0.3 s later, or
# never with /run/home-nojoin (then it reports association rejects like the BCM4358 on a weak link)
mk /usr/sbin/wpa_supplicant 'echo "wpa_supplicant $*" >> /run/calls
while [ $# -gt 0 ]; do case $1 in -c) CF=$2; shift;; esac; shift; done
cp "$CF" /run/wpa.seen; echo "wlan0: Trying to associate with SSID Home Net"
if [ -e /run/home-nojoin ]; then echo "wlan0: CTRL-EVENT-ASSOC-REJECT bssid=0a:0b:0c:0d:0e:02 status_code=16"
else (sleep 0.3; echo up > /fake/net/wlan0/operstate) & fi
exec sleep 600'
mk /sbin/udhcpc 'echo "udhcpc $*" >> /run/calls; while [ $# -gt 0 ]; do case $1 in -s) S=$2; shift;; esac; shift; done
[ -e /run/home-nodhcp ] && { sleep 5; exit 1; }
interface=wlan0 ip=192.168.77.20 mask=24 router=192.168.77.1 "$S" bound'
mk /usr/sbin/ip 'echo "ip $*" >> /run/calls; exit 0'
for b in /sbin/ip /bin/ip /usr/bin/ip; do [ -e $b ] && ln -sf /usr/sbin/ip $b; done
# the Pushgateway stand-in (busybox httpd refuses DELETE): nc as a persistent server, one handler per request
# logging method, path (minus the /pg prefix the URL carries) and body; /run/pgw.fail = a server error
mk /fake/pgw.sh 'read -r m p v; n=0; cr=$(printf "\r")
while read -r l; do l=${l%"$cr"}; [ -z "$l" ] && break; case $l in [Cc]ontent-[Ll]ength:*) n=${l#*: };; esac; done
b=; [ "$n" -gt 0 ] && b=$(head -c "$n")
p=${p#/pg}; echo "$m $p $n" >> /run/pgw.log
[ -n "$b" ] && printf "%s\n" "$b" > "/run/pgw.body.${p##*/}"
if [ -e /run/pgw.fail ]; then printf "HTTP/1.0 500 Internal Server Error\r\nContent-Type: text/plain\r\n\r\nno\n"
else printf "HTTP/1.0 200 OK\r\nDate: Sat, 28 Nov 2026 15:00:00 GMT\r\nContent-Type: text/plain\r\n\r\n"; fi'
: > /run/pgw.log
nc -lk -s 127.0.0.1 -p 19091 -e /fake/pgw.sh &
sleep 1
R() { cat /run/u2ac-home/result 2> /dev/null; }
state() { cut -d' ' -f1 /run/u2ac-home/result 2> /dev/null; }

# A. not set up: no network at all
u2ac-home prep; u2ac-home push 4 > /dev/null; chk "unset rc" $? 1
chk "unset state" "$(state)" failed
hasnt "unset: no scan" '^iw dev wlan0 scan' /run/calls

# B. set up, two new slots with metrics (seq 1 has none): both sent, oldest first, the old group pruned
PMK=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
printf 'SSID=Home Net\nPMK=%s\nURL=http://127.0.0.1:19091/pg\n' "$PMK" > /run/persist/u2ac-home.conf
: > /run/home-here
u2ac-home prep
chk "prep queue" "$(ls /run/u2ac-home/q | tr '\n' ' ')" "2.prom 3.prom "
hasnt "no HELP in the body" '^# HELP' /run/u2ac-home/q/2.prom
has "slot seq added" '^u2ac_flightlog_seq 2$' /run/u2ac-home/q/2.prom
has "slot why added" '^u2ac_flightlog_info{why="session+60s"} 1$' /run/u2ac-home/q/2.prom
t0=$(cs); u2ac-home push 8 > /dev/null; rc=$?; dt=$(( $(cs) - t0 ))
chk "push rc" $rc 0
chk "push state" "$(state)" pushed
has "posted 2" '^POST /metrics/job/u2ac/log_seq/2 ' /run/pgw.log
has "posted 3" '^POST /metrics/job/u2ac/log_seq/3 ' /run/pgw.log
chk "order" "$(grep -o 'log_seq/[0-9]*' /run/pgw.log | tr '\n' ' ')" "log_seq/2 log_seq/3 log_seq/1 "
has "pruned seq 1 (KEEP 2)" '^DELETE /metrics/job/u2ac/log_seq/1 ' /run/pgw.log
has "body as sent" '^u2ac_aa_event_seconds{event="proxying"} 22.3$' /run/pgw.body.2
# the drive summary (last record) and the wall-clock times
has "drive length" '^u2ac_drive_seconds 1800$' /run/pgw.body.2
has "drive drops" '^u2ac_drive_drops 1$' /run/pgw.body.2
has "drive worst signal" '^u2ac_drive_signal_min_dbm -71$' /run/pgw.body.2
has "drive devices" '^u2ac_drive_hotspot_devices 2$' /run/pgw.body.2
has "drive memory" '^u2ac_drive_memory_available_min_bytes 61440000$' /run/pgw.body.2
has "drive cpu" '^u2ac_drive_cpu_busy_ratio 0.35$' /run/pgw.body.2
has "drive records" '^u2ac_drive_records 2$' /run/pgw.body.2
hasnt "no end time without a clock" '^u2ac_drive_end_timestamp_seconds' /run/pgw.body.2
has "start time from the header" '^u2ac_drive_start_timestamp_seconds 1795869912$' /run/pgw.body.3
grep -q '^u2ac_drive_records' /run/pgw.body.3 && { failn=$((failn + 1)); echo "FAIL drive summary without records"; } || pass=$((pass + 1))
sh /o/metricscheck.sh /run/pgw.body.2 | grep -q -- '--- metrics: [0-9]* samples, 0 bad, 0 dup, 0 outside' && pass=$((pass + 1)) \
    || { failn=$((failn + 1)); echo "FAIL body format: $(sh /o/metricscheck.sh /run/pgw.body.2 | tail -n 2)"; }
# the clock from the server's Date (15:00:00 = 1795878000), never the system clock
ck=$(( $(cat /run/u2ac-clock) + $(cut -d. -f1 /proc/uptime) - 1795878000 ))
[ $ck -ge -2 ] && [ $ck -le 30 ] && pass=$((pass + 1)) || { failn=$((failn + 1)); echo "FAIL clock offset off by $ck s"; }
has "upload stats" '^scan=[0-9]* join=[0-9]* address=[0-9]* signal=-48 lease=0$' /run/u2ac-home/stats
chk "mark (RAM)" "$(cat /run/u2ac-home/sent)" 3
chk "mark (persist)" "$(cat /run/persist/u2ac-home.sent)" 3
chk "channel learned" "$(cat /run/persist/u2ac-home.freq)" 2437
has "wpa: ssid as hex" "ssid=486f6d65204e6574$" /run/wpa.seen
has "wpa: the stronger AP" "bssid=0a:0b:0c:0d:0e:02$" /run/wpa.seen
has "wpa: the stored key" "psk=$PMK$" /run/wpa.seen
has "wpa: its channel only" "freq_list=2437$" /run/wpa.seen
has "dhcp address removed" '^ip addr del 192.168.77.20/24 dev wlan0' /run/calls
chk "lease kept" "$(cat /run/persist/u2ac-home.lease)" "192.168.77.20/24 192.168.77.1"
has "phase times in the result" 'by DHCP)$' /run/u2ac-home/result
chk "left wlan0 down" "$(grep '^ip ' /run/calls | tail -n 1)" "ip link set wlan0 down"
chk "wpa_supplicant stopped" "$(pgrep -f 'sleep 600' | wc -l)" 0
chk "nothing left in RAM" "$(ls /run/u2ac-home/wpa.conf /run/u2ac-home/ip 2> /dev/null | wc -l)" 0
[ $dt -lt 800 ] && pass=$((pass + 1)) || { failn=$((failn + 1)); echo "FAIL push took $dt cs"; }
echo "--- B: $(R)"

# C. nothing new: no network
: > /run/calls; u2ac-home prep; u2ac-home push 4 > /dev/null; chk "nothing rc" $? 0
chk "nothing state" "$(state)" none
hasnt "nothing: no scan" '^iw dev wlan0 scan' /run/calls

# D. the mark a drive left in a slot header (home=) counts like the persisted one
rm -f /run/persist/u2ac-home.sent; slot 4 session+60s 1 4
u2ac-home prep; chk "header mark" "$(cat /run/u2ac-home/base) $(ls /run/u2ac-home/q | wc -l)" "4 0"
slot 5 session+60s 1
u2ac-home prep; chk "after the header mark" "$(ls /run/u2ac-home/q | tr '\n' ' ')" "5.prom "

# E. away from home: the last channel, then the usual ones, then give up (no join attempt)
rm -f /run/home-here; : > /run/calls
t0=$(cs); u2ac-home push 4 > /dev/null; rc=$?; dt=$(( $(cs) - t0 ))
chk "absent rc" $rc 3
chk "absent state" "$(state)" absent
chk "absent scans" "$(grep -c '^iw dev wlan0 scan' /run/calls)" 2
has "absent: last channel first" '^iw dev wlan0 scan freq 2437 ssid Home Net$' /run/calls
hasnt "absent: no join" '^wpa_supplicant' /run/calls
[ $dt -lt 150 ] && pass=$((pass + 1)) || { failn=$((failn + 1)); echo "FAIL absent took $dt cs"; }

# F. the network is there but the join never completes: the box ends it, nothing left running
: > /run/home-here; : > /run/home-nojoin; rm -f /fake/net/wlan0/operstate; : > /run/calls
t0=$(cs); u2ac-home push 2 > /dev/null; rc=$?; dt=$(( $(cs) - t0 ))
chk "nojoin rc" $rc 1
chk "nojoin state" "$(state)" failed
chk "nojoin wpa stopped" "$(pgrep -f 'sleep 600' | wc -l)" 0
has "nojoin reason" 'association rejects (status 16), weak signal?$' /run/u2ac-home/result
[ $dt -ge 180 ] && [ $dt -lt 400 ] && pass=$((pass + 1)) || { failn=$((failn + 1)); echo "FAIL nojoin took $dt cs"; }
echo "--- F: $(R)"

# F2. DHCP silent within a boot's box: the last lease as it was (asked for with -r first); by hand (20 s) no lease = fail
rm -f /run/home-nojoin; : > /run/home-nodhcp; : > /run/calls
t0=$(cs); u2ac-home push 4 > /dev/null; rc=$?; dt=$(( $(cs) - t0 ))
chk "lease fallback rc" $rc 0
has "lease fallback used" 'by the last lease)$' /run/u2ac-home/result
has "lease asked for" '^udhcpc .* -r 192.168.77.20 ' /run/calls
has "lease address set" '^ip addr add 192.168.77.20/24 dev wlan0' /run/calls
[ $dt -lt 400 ] && pass=$((pass + 1)) || { failn=$((failn + 1)); echo "FAIL lease fallback took $dt cs"; }
rm -f /run/persist/u2ac-home.lease; slot 6 session+60s 1; u2ac-home prep
t0=$(cs); u2ac-home push 4 > /dev/null; rc=$?; dt=$(( $(cs) - t0 ))
chk "no lease, no DHCP rc" $rc 1
has "no lease, no DHCP" 'no address from DHCP on Home Net' /run/u2ac-home/result
rm -f /run/home-nodhcp
echo "--- F2: $(R)"

# G. the server refuses: nothing marked as sent
rm -f /run/home-nojoin; : > /run/pgw.fail
u2ac-home prep; u2ac-home push 4 > /dev/null; chk "refused rc" $? 1
chk "refused state" "$(state)" failed
chk "refused mark unchanged" "$(cat /run/persist/u2ac-home.sent 2> /dev/null)" 5
echo "--- G: $(R)"
rm -f /run/pgw.fail

# H. status line, and the log carries the outcomes
chk "status" "$(u2ac-home status | cut -c1-48)" "home upload: on (to 127.0.0.1:19091 over Home Ne"
has "log" 'home upload: sent 2 log(s) up to seq 3' /run/log/u2ac-aa.log
echo "home: pass=$pass fail=$failn"
