#!/bin/sh
# dry run of the image's u2ac-aa start: real script, stubbed hardware (insmod, iw, btmgmt, hostapd, ...),
# fake /sys on tmpfs. Needs a --privileged armv7 container of the rootfs. SCEN=car|computer|dev
set -u
SCEN=${SCEN:-car}
# tests the u2ac-aa / radio-lib.sh baked into the image (no copies from the repo)
mkdir -p /run/persist /run/log /run/varlib /run/dropbear /fake
: > /run/persist.loaded
[ "$SCEN" = dev ] && : > /run/persist/u2ac-dev
# a phone paired on an earlier boot (persisted link key): state_restore must put it in known_devices
mkdir -p /run/persist/bluetooth/38:BA:B0:AA:BB:CC/11:22:33:44:55:66
printf '[General]\nName=Pixel\n\n[LinkKey]\nKey=00112233445566778899AABBCCDDEEFF\nType=4\n' \
    > /run/persist/bluetooth/38:BA:B0:AA:BB:CC/11:22:33:44:55:66/info
# fake sysfs
mount -t tmpfs none /sys
mkdir -p /sys/devices/system/cpu/cpu0/cpufreq /sys/devices/system/cpu/cpufreq/ondemand /sys/module/firmware_class/parameters /sys/class/net/usb0 /sys/class/bluetooth
echo performance > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor; echo 0 > /sys/devices/system/cpu/cpufreq/ondemand/up_threshold
mkdir -p /sys/devices/system/cpu/cpu0/cpuidle/state2; echo 1 > /sys/devices/system/cpu/cpu0/cpuidle/state2/disable
echo 0 > /sys/class/net/usb0/carrier; [ "$SCEN" = computer ] && echo 1 > /sys/class/net/usb0/carrier
: > /fake/modules
export MODLOAD_PROC=/fake/modules MODLOAD_DIR=$(ls -d /lib/modules/*/ | head -n 1)
log() { echo "$*" >> /run/stub.calls; }
mk() { rm -f "$1"; printf '#!/bin/sh\n%s\n' "$2" > "$1"; chmod +x "$1"; }
mk /usr/sbin/insmod 'echo "insmod $*" >> /run/stub.calls; n=${1##*/}; n=${n%%.ko*}; n=$(echo $n | tr - _); echo "$n 0 0 - Live 0x0" >> /fake/modules
case $n in sdhci_esdhc_imx) (sleep 1; mkdir -p /sys/class/net/wlan0/phy80211; echo phy0 > /sys/class/net/wlan0/phy80211/name; echo 02:11:22:aa:bb:cc > /sys/class/net/wlan0/address) & ;;
hci_uart) (sleep 2; mkdir -p /sys/class/bluetooth/hci0) & ;;
u2ac_ws2812) L=/sys/class/leds/rgb:status; mkdir -p $L; for f in color trigger brightness delay_on delay_off; do : > $L/$f; done ;; esac'
mk /usr/sbin/iw 'echo "iw $*" >> /run/stub.calls; case "$*" in *channels*) printf "* 5180 MHz [36]\n\t  Maximum TX power: 20.0 dBm\n\t  Channel widths: 20MHz HT40+ VHT80\n";; esac; exit 0'
# btmgmt 5.87 on the unit: with a non-FIFO stdin (/dev/null) it quits before the reply, printing nothing
mk /usr/sbin/btmgmt '[ -p /dev/stdin ] || { echo "btmgmt $* (stdin not a FIFO: no reply)" >> /run/stub.calls; exit 0; }
echo "btmgmt $*" >> /run/stub.calls; case "$*" in *info*) echo "hci0: Primary controller"; echo "	current settings: bondable ssp br/edr le";; esac'
mk /usr/sbin/hostapd 'echo "hostapd $*" >> /run/stub.calls; while [ $# -gt 1 ]; do case $1 in -P) P=$2; shift;; -f) F=$2; shift;; esac; shift; done; C=$1; grep -E "^(ssid|vht_oper_chwidth)=" $C >> /run/stub.calls; sleep 600 & echo $! > $P'
mk /usr/sbin/hostapd_cli 'echo "hostapd_cli $*" >> /run/stub.calls; [ -s /run/hostapd.pid ] && echo state=ENABLED'
mk /usr/sbin/udhcpd 'echo "udhcpd $*" >> /run/stub.calls'
mk /usr/sbin/httpd 'echo "httpd $*" >> /run/stub.calls; sleep 600 &'
mk /usr/sbin/dropbear 'echo "dropbear $*" >> /run/stub.calls'
mk /usr/sbin/persist 'echo "persist $*" >> /run/stub.calls'
mk /usr/sbin/ip 'case "$*" in "-4 addr show usb0") echo "    inet 192.168.50.2/24 scope global usb0";; *) echo "ip $*" >> /run/stub.calls;; esac; exit 0'
mk /usr/sbin/ping 'echo "ping $*" >> /run/stub.calls; [ -e /run/computer ]'
rm -f /usr/sbin/arping; mk /usr/sbin/arping 'echo "arping $*" >> /run/stub.calls; [ -e /run/computer ]'
[ "$SCEN" = computer ] && : > /run/computer
: > /run/udhcpd-ncm.pid
mk /usr/libexec/bluetooth/bluetoothd 'echo "bluetoothd $*" >> /run/stub.calls; sleep 1; echo "bluetoothd[9]: Bluetooth daemon 5.79"; echo "bluetoothd[9]: Bluetooth management interface 1.22 initialized"; sleep 600'
mk /usr/bin/aa-proxy-rs 'echo "aa-proxy-rs AA_FFS_CHUNK=$AA_FFS_CHUNK cwd=$(pwd)" >> /run/stub.calls; sleep 600'
mkdir -p /run/aa-etc /run/data
# flight recorder: a fake 'rootfs' MTD (plain file, mtd.sh's MTD_SYS/MTD_DEV) = squashfs header with
# bytes_used 10326016 (the r3 image) + erased flash; FL_ERASE writes 0xff; the saver's clock runs 25x fast
export MTD_SYS=/fake/mtdsys MTD_DEV=/fake/mtddev U2AC_TICK=0.2 FL_ERASE=/fake/erase
mkdir -p $MTD_SYS/mtd3 $MTD_DEV; echo rootfs > $MTD_SYS/mtd3/name; echo 12976128 > $MTD_SYS/mtd3/size
echo 65536 > $MTD_SYS/mtd3/erasesize
tr '\000' '\377' < /dev/zero | head -c 12976128 > $MTD_DEV/mtd3
printf 'hsqs' | dd of=$MTD_DEV/mtd3 conv=notrunc 2> /dev/null
printf '\000\220\235\000\000\000\000\000' | dd of=$MTD_DEV/mtd3 bs=1 seek=40 conv=notrunc 2> /dev/null
printf '#!/bin/sh\ntr "\\000" "\\377" < /dev/zero | head -c $(($3 * 65536)) | dd of="$1" bs=65536 seek=$(($2 / 65536)) conv=notrunc 2> /dev/null\n' > /fake/erase
chmod +x /fake/erase
SQ0=$(head -c 11927552 $MTD_DEV/mtd3 | md5sum | cut -d' ' -f1)
T0=$(cut -d. -f1 /proc/uptime)
timeout 60 u2ac-aa start; echo "start rc=$?"
sleep 1
echo "--- u2ac-aa.log"; cat /run/log/u2ac-aa.log
echo "--- stub calls"; cat /run/stub.calls
echo "--- governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor) up_threshold=$(cat /sys/devices/system/cpu/cpufreq/ondemand/up_threshold)"
echo "--- fw path: $(cat /sys/module/firmware_class/parameters/path 2>/dev/null)"
echo "--- procs:"; ps | grep -E "aa-proxy|bluetoothd|dbus|hostapd|sleep 30" | grep -v grep
# saver: writes flash only when /run/persist really changed
c0=$(grep -c "^persist save" /run/stub.calls)
u2ac-aa persist; u2ac-aa persist
c1=$(grep -c "^persist save" /run/stub.calls)
mkdir -p /run/varlib/bluetooth/38:BA:B0:AA:BB:CC/AA:BB:CC:DD:EE:01; echo "[LinkKey]" > /run/varlib/bluetooth/38:BA:B0:AA:BB:CC/AA:BB:CC:DD:EE:01/info
u2ac-aa persist; u2ac-aa persist
c2=$(grep -c "^persist save" /run/stub.calls)
mkdir -p /run/varlib/bluetooth/38:BA:B0:AA:BB:CC/cache/AA:BB:CC:DD:EE:01; echo x > /run/varlib/bluetooth/38:BA:B0:AA:BB:CC/cache/AA:BB:CC:DD:EE:01/x
u2ac-aa persist
c3=$(grep -c "^persist save" /run/stub.calls)
echo "--- saver writes: idle=$((c1 - c0)) pairing=$((c2 - c1)) cache-only=$((c3 - c2))"
# log cap: a 2 MB log with an appending writer shrinks to the newest 256 KiB, the writer keeps appending
sed -n '/^cap_logs() {/,/^}/p' /usr/sbin/u2ac-aa > /tmp/cap.sh; . /tmp/cap.sh
head -c 2000000 /dev/zero | tr '\000' 'x' > /run/log/big.log; echo >> /run/log/big.log
exec 7>> /run/log/big.log; cap_logs; echo TAIL >&7; exec 7>&-
sz=$(wc -c < /run/log/big.log); last=$(tail -n 1 /run/log/big.log)
[ "$sz" -le 262200 ] && [ "$last" = TAIL ] && echo "--- cap_logs ok ($sz B)" || echo "--- cap_logs BAD ($sz B, last=$last)"
echo "--- state2=$(cat /sys/devices/system/cpu/cpu0/cpuidle/state2/disable)"
echo "--- known_devices: $(tr '\n' ' ' < /run/aa-etc/known_devices 2> /dev/null)"
# flight recorder (car mode: aa-proxy-rs is ours): the 90 s trigger = tick 18 = ~4 s here
[ "$SCEN" = car ] && sleep 5
echo "--- flightlog list: $(u2ac-aa flightlog 2>&1 | head -n 1)"
echo "--- flightlog last: $(u2ac-aa flightlog last 2>&1 | grep -c '^=== ')"
[ "$(head -c 11927552 $MTD_DEV/mtd3 | md5sum | cut -d' ' -f1)" = "$SQ0" ] && echo "--- squashfs region intact" \
    || echo "--- squashfs region CHANGED"
# the guard: a squashfs that reaches into the area -> no flight log at all
printf '\000\000\300\000' | dd of=$MTD_DEV/mtd3 bs=1 seek=40 conv=notrunc 2> /dev/null
echo "--- flightlog guard: $(u2ac-aa flightlog 2>&1 | head -n 1)"
L=/sys/class/leds/rgb:status; echo "--- led: color=$(cat $L/color 2>/dev/null) trigger=$(cat $L/trigger 2>/dev/null)"
echo "--- status:"; u2ac-aa status
echo "--- persisted:"; ls -la /run/persist
