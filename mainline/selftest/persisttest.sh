#!/bin/sh
# persist load, all or nothing, under the RECOVERY busybox applets in /rb (recovery loads the archive too):
# a whole archive loads, an archive cut short by a power loss (0xFF after the cut, as the erased NOR reads)
# loads nothing. Prints one "result" line. Runs in the armv7 rootfs container (the image's /usr/sbin/persist).
set -u
export PERSIST_DEV=/tmp/cust.img
P=/run/persist
mkdir -p /run/etc
# an archive like the unit's: a host key, a pairing, a flag (tar of the rootfs busybox, as `persist save` makes it)
rm -rf $P /tmp/src; mkdir -p /tmp/src/bluetooth/38:BA:B0:AA:BB:CC/11:22:33:44:55:66
head -c 3000 /dev/urandom > /tmp/src/dropbear_ed25519_host_key
printf '[LinkKey]\nKey=00112233445566778899AABBCCDDEEFF\n' > /tmp/src/bluetooth/38:BA:B0:AA:BB:CC/11:22:33:44:55:66/info
head -c 9000 /dev/urandom | od -An -tx1 > /tmp/src/zz-big.conf
: > /tmp/src/u2ac-dev
(cd /tmp/src && tar -cf /tmp/a.tar .)
pad() { tr '\000' '\377' < /dev/zero | head -c $((65536 - $(wc -c < "$1"))); }
{ cat /tmp/a.tar; pad /tmp/a.tar; } > $PERSIST_DEV
PATH=/rb /rb/sh /usr/sbin/persist load > /tmp/l1.txt 2>&1; r1=$?
f1=$(cd $P 2> /dev/null && find . -type f | sort | tr '\n' ' ')
ok1=0; cmp -s /tmp/src/zz-big.conf $P/zz-big.conf && cmp -s /tmp/src/dropbear_ed25519_host_key $P/dropbear_ed25519_host_key && ok1=1
# the same archive cut short halfway (inside file data, well before its end-of-archive blocks), 0xFF after the cut
cut=$(( $(wc -c < /tmp/a.tar) / 2 ))
{ head -c $cut /tmp/a.tar; tr '\000' '\377' < /dev/zero | head -c $((65536 - cut)); } > $PERSIST_DEV
rm -rf $P
PATH=/rb /rb/sh /usr/sbin/persist load > /tmp/l2.txt 2>&1; r2=$?
f2=$(cd $P 2> /dev/null && find . -type f | sort | tr '\n' ' ')
echo "result whole_rc=$r1 whole_same=$ok1 cut_rc=$r2 cut_files=[${f2}] whole_files=[${f1}] msg=[$(tail -n 1 /tmp/l2.txt)]"
