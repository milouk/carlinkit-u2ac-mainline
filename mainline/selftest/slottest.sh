# Boot-slot logic (common/shared/mtd.sh + the init's parse block) under the RECOVERY busybox ash with only
# its applets on PATH, against a loop device standing in for the bootstate MTD (mtd9). Run by run.sh.
. /w/mtd.sh
MTD_DEV=/mtd
STATE_N=9
pass=0; failn=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else failn=$((failn+1)); echo "FAIL $1: got '$2' want '$3'"; fi; }
init_decide() {   # mirror of the init's decision (parse + branch order) for one boot
    . /w/initparse.sh
    if [ "$BS_REQ" = 1 ]; then bootslot_visit "$STATE_N"; echo recovery-req
    elif [ "$BS_FAIL" -ge "$BOOTSLOT_MAXFAIL" ]; then bootslot_visit "$STATE_N"; echo recovery-fail
    else bootslot_attempt "$STATE_N" && echo "$BOOTSLOT_IDX" > /tmp/bootslot && echo rootfs; fi
}
rcs_ok() { bootslot_ok "$STATE_N" "$(cat /tmp/bootslot 2>/dev/null)"; }
raw() { hexdump -v -s $((BOOTSLOT_BASE + 2 * $1)) -n 2 -e '2/1 "%02x"' /mtd/mtd9; }
used() { set -- $(bootslot_scan 9); echo "$1"; }
fails() { set -- $(bootslot_scan 9); echo "$2"; }
poke() { printf "$2" | dd of=/mtd/mtd9 bs=1 seek=$((BOOTSLOT_BASE + 2 * $1)) count=2 2>/dev/null; }

chk fresh "$(bootslot_scan 9)" "0 0 0"
chk b1 "$(init_decide)" rootfs; rcs_ok
chk b1scan "$(bootslot_scan 9)" "1 0 0"
# three boots that never come up -> the 4th is ONE recovery visit, the 5th tries the rootfs again
chk c1 "$(init_decide)" rootfs; chk c2 "$(init_decide)" rootfs; chk c3 "$(init_decide)" rootfs
chk c3scan "$(bootslot_scan 9)" "4 3 0"
chk c4 "$(init_decide)" recovery-fail
chk c4slot "$(raw 4)" 5555
chk c5 "$(init_decide)" rootfs; rcs_ok
chk c5scan "$(bootslot_scan 9)" "6 0 0"
# two failures then a good boot: the count resets
init_decide > /dev/null; init_decide > /dev/null; chk d3 "$(init_decide)" rootfs; rcs_ok
chk dscan "$(bootslot_scan 9)" "9 0 0"
# reboot-recovery: one visit, then the rootfs
bootslot_request 9
chk rq "$(bootslot_scan 9)" "10 0 1"
chk r1 "$(init_decide)" recovery-req
chk r1scan "$(bootslot_scan 9)" "11 0 0"
chk r2 "$(init_decide)" rootfs; rcs_ok
chk r2scan "$(bootslot_scan 9)" "12 0 0"
# a request made BEFORE rcS marked its boot: rcS marks its own slot (index), the request survives
chk e1 "$(init_decide)" rootfs
bootslot_request 9
rcs_ok
chk e1slot "$(raw 12)" 0000
chk e1scan "$(bootslot_scan 9)" "14 0 1"
chk e2 "$(init_decide)" recovery-req
chk e3 "$(init_decide)" rootfs; rcs_ok
# garbage from a power cut during an erase (a3 12 x3): one recovery visit, never a stuck unit
I=$(used)
poke $I '\243\022'; poke $((I + 1)) '\243\022'; poke $((I + 2)) '\243\022'
chk g0 "$(fails)" 3
chk g1 "$(init_decide)" recovery-fail
chk g2 "$(init_decide)" rootfs; rcs_ok
chk g2scan "$(fails)" 0
echo "bytes:"; hexdump -v -s 4096 -n 48 -e '2/1 "%02x" " "' /mtd/mtd9; echo
echo "pass=$pass fail=$failn"
