#!/bin/sh
# board_usb_probe (the image's /etc/baseline/board-rcS.sh) against a stand-in u2ac-usbprobe and a fake configfs.
# PSCEN=car|computer|nohost|late|fail|dev. The real probe binary is tested on the dongle (FunctionFS); this
# tests the shell around it: return code, verdict, timing, the late-host path. Prints one "result" line.
set -u
mkdir -p /run/persist /run/log /fake/bin
: > /run/calls
[ "$PSCEN" = dev ] && : > /run/persist/u2ac-dev
mount -t tmpfs none /sys
mkdir -p /sys/kernel/config/usb_gadget /sys/firmware/devicetree/base /fake/soc/2184200.usb/ci_hdrc.0/udc/ci_hdrc.0 /sys/class/udc
ln -s /fake/soc/2184200.usb/ci_hdrc.0/udc/ci_hdrc.0 /sys/class/udc/ci_hdrc.0
printf 'Carlinkit U2AC AutoKit mainline (i.MX6ULL)\000' > /sys/firmware/devicetree/base/model
mk() { printf '#!/bin/sh\n%s\n' "$2" > "/fake/bin/$1"; chmod +x "/fake/bin/$1"; }
mk mount 'echo "mount $*" >> /run/calls; mkdir -p "$4"'
mk umount 'echo "umount $*" >> /run/calls'
mk net-up 'echo "net-up $*" >> /run/calls; echo usb0'
mk ssh-up 'echo "ssh-up $*" >> /run/calls'
mk u2ac-usbprobe 'echo "probe $*" >> /run/calls
[ "$PSCEN" = fail ] && { echo "u2ac-usbprobe: writing descriptors: Invalid argument" >&2; exit 2; }
: > "$1/ep1"
case $PSCEN in
car) sleep 0.3; echo car ;;
computer) sleep 0.3; echo configured; sleep 3; echo noaoa ;;
nohost) sleep 10; echo none ;;
late) sleep 6; echo configured; sleep 3; echo noaoa ;;
esac'
export PATH=/fake/bin:$PATH PSCEN
. /etc/baseline/board.env
. /etc/baseline/ncm.conf
. /etc/baseline/board-rcS.sh
up() { cut -d' ' -f1 /proc/uptime; }
t0=$(up)
board_usb_probe; rc=$?
t1=$(up)
v1=$(cat /run/u2ac-usbprobe 2> /dev/null || echo -)
n=0; while [ ! -s /run/u2ac-usbprobe ] && [ $n -lt 150 ]; do sleep 0.1; n=$((n + 1)); done
sleep 0.5
udc=$(cat /sys/kernel/config/usb_gadget/u2acprobe/UDC 2> /dev/null || echo gone)
echo "result rc=$rc ret=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }') at_return=$v1" \
     "final=$(cat /run/u2ac-usbprobe) how=$(cat /run/u2ac-usbprobe.how 2> /dev/null || echo -) udc=[${udc}]" \
     "netup=$(grep -c '^net-up ncm' /run/calls 2> /dev/null) sshup=$(grep -c '^ssh-up' /run/calls 2> /dev/null)" \
     "probe=$(grep -c '^probe ' /run/calls 2> /dev/null)" \
     "ids=$(cat /sys/kernel/config/usb_gadget/u2acprobe/idVendor /sys/kernel/config/usb_gadget/u2acprobe/idProduct 2> /dev/null | tr '\n' :)" \
     "product=[$(cat /sys/kernel/config/usb_gadget/u2acprobe/strings/0x409/product 2> /dev/null)]"
