#!/bin/sh
# Mac-side helper for the r3 install (RUNBOOK.md), dongle on the Mac's USB (NCM 192.168.50.2).
# Nothing here writes flash unless the step is given --go; without it every step only copies,
# checks hashes and runs the on-unit tool's own --dry-run.
#   flash-r3.sh preflight           r2 recovery: mtd0/1/2 hashes == the staging base ($U2AC_BACKUP/mtd{0,1,2}.bin)
#   flash-r3.sh kernel [--go]       copy + verify kernel-part.img, flash-kernel --dry-run; --go: write + reboot
#   flash-r3.sh wait                wait until the unit answers ssh again (max 180 s)
#   flash-r3.sh check               r3 recovery: kernel version, partition map, cpufreq
#   flash-r3.sh rootfs [--go]       copy + verify rootfs.img; --go: flash-rootfs, then reboot
#   flash-r3.sh verify              rootfs boot (maintenance mode): service status, logs, radio checks
#   flash-r3.sh to-recovery         from the rootfs: one recovery boot (writes a bootstate request) to re-flash
# KV=7.3.6 flash-r3.sh ... picks the other kernel (kernel and rootfs MUST be the same KV).
set -eu
D=$(cd "$(dirname "$0")" && pwd)
KV=${KV:-7.2.15}
# the staging base: dumps of THIS unit's mtd0/1/2 taken in recovery before staging (U2AC_BACKUP=<dir>)
B=${U2AC_BACKUP:-$D/../../../backup/mainline_r2_20261126}
H=root@192.168.50.2
T=$(mktemp -d /tmp/flash-r3.XXXXXX)
trap 'rm -rf "$T"' EXIT
printf '#!/bin/sh\necho baseline\n' > "$T/askpass"; chmod 700 "$T/askpass"
# host keys differ between recovery (ephemeral) and the rootfs (persisted): never pin them here
# ServerAlive: a session open while the unit reboots must fail, not hang (the kernel step's poll did)
O="-o ConnectTimeout=6 -o ServerAliveInterval=3 -o ServerAliveCountMax=2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=$T/kh -o LogLevel=ERROR"
if ssh $O -o BatchMode=yes "$H" true 2> /dev/null; then AUTH=key; else AUTH=pw; fi
r() {
    if [ $AUTH = key ]; then ssh $O -o BatchMode=yes "$H" "$@"
    else SSH_ASKPASS="$T/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 ssh $O -o PubkeyAuthentication=no "$H" "$@"; fi
}
cpy() {
    if [ $AUTH = key ]; then scp -O $O -o BatchMode=yes "$1" "$H:$2"
    else SSH_ASKPASS="$T/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 scp -O $O -o PubkeyAuthentication=no "$1" "$H:$2"; fi
}
die() { echo "STOP: $*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | cut -c1-64; }
# remote_sha FILE: the unit's sha256 of FILE (recovery has no grep/cut: parse here)
remote_sha() { r "sha256sum $1" | awk '{ print $1 }'; }
push() { # push LOCAL REMOTE: copy and prove the bytes arrived intact
    want=$(cat "$1.sha256" | cut -c1-64); [ "$(sha "$1")" = "$want" ] || die "local $1 does not match its .sha256"
    cpy "$1" "$2"; got=$(remote_sha "$2"); [ "$got" = "$want" ] || die "copy of $1 arrived corrupt ($got)"
    echo "copied $(basename "$1") ($want)"
}

step=${1:-}; go=${2:-}
case $step in
preflight)
    echo "auth: $AUTH"
    r 'cat /proc/version; cat /proc/mtd'
    for i in 0 1 2; do
        want=$(sha "$B/mtd$i.bin"); got=$(remote_sha "/dev/mtd$i")
        [ "$got" = "$want" ] && echo "mtd$i OK ($want)" || die "mtd$i differs from the staging base: re-dump and re-stage before flashing"
    done
    echo "preflight OK: $KV/kernel-part.img was staged against exactly this flash" ;;
kernel)
    push "$D/$KV/kernel-part.img" /tmp/kernel-part.img
    S=$(cut -c1-64 "$D/$KV/kernel-part.img.sha256")
    r "flash-kernel --dry-run /tmp/kernel-part.img $S" || die "flash-kernel --dry-run refused (see above)"
    if [ "$go" = --go ]; then
        echo "WRITING the kernel partition now (power must stay on ~30 s)"
        r "setsid flash-kernel /tmp/kernel-part.img $S > /tmp/flash-kernel.log 2>&1 < /dev/null &" || true
        n=0; while [ $n -lt 90 ]; do
            sleep 2; n=$((n + 1))
            out=$(r 'cat /tmp/flash-kernel.log' 2> /dev/null) || { echo "unit went away (reboot): $n x 2 s"; break; }
            printf '%s\n' "$out" | tail -n 2
        done
    else echo "dry run only: add --go to write"; fi ;;
wait)
    n=0; until ssh $O -o BatchMode=yes "$H" true 2> /dev/null || \
        SSH_ASKPASS="$T/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 ssh $O -o PubkeyAuthentication=no "$H" true 2> /dev/null; do
        n=$((n + 1)); [ $n -gt 60 ] && die "no ssh after 180 s"; sleep 3; done
    echo "unit answers ssh after ~$((n * 3)) s" ;;
check)
    r 'cat /proc/version; cat /proc/mtd; cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies 2>/dev/null; cat /run/ocbm/banner 2>/dev/null' \
        | tee "$T/check.txt"
    grep -q "$KV" "$T/check.txt" || die "not running $KV"
    for p in rootfs customer bootstate; do grep -q "\"$p\"" "$T/check.txt" || die "no '$p' partition: wrong map"; done
    echo "check OK: r3 $KV recovery with the r3 partition map" ;;
rootfs)
    push "$D/$KV/rootfs.img" /tmp/rootfs.img
    S=$(cut -c1-64 "$D/$KV/rootfs.img.sha256")
    if [ "$go" = --go ]; then
        echo "WRITING the rootfs partition (overwrites the stock 2024.10.31 rootfs; backup in backup/mainline_r1_20261126)"
        r "flash-rootfs /tmp/rootfs.img $S" || die "flash-rootfs failed: the unit stays in recovery, retry"
        echo "rootfs written and verified by flash-rootfs; rebooting"
        r 'reboot' || true
    else echo "copied and verified only: add --go to write"; fi ;;
to-recovery)
    # from the r3 rootfs: ONE recovery boot (writes a boot-slot request to bootstate; the boot after is the
    # rootfs again), e.g. to re-flash the rootfs; then: wait, check, rootfs [--go]
    r 'reboot-recovery' || true
    echo "recovery boot requested; next: flash-r3.sh wait && flash-r3.sh check" ;;
verify)
    r 'cat /proc/version; u2ac-aa status; echo; cat /run/log/u2ac-aa.log; echo; tail -n 15 /run/log/hostapd.log;
       echo; iw phy "$(cat /sys/class/net/wlan0/phy80211/name)" channels 2>/dev/null | grep -A3 "5180 MHz";
       echo; dmesg | grep -iE "brcmf|bluetooth|hci|country|error|fail|oops" | tail -n 40; echo; free; df -h /run /tmp' ;;
*) sed -n '2,12p' "$0"; exit 2 ;;
esac
