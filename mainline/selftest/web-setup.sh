set -e
mkdir -p /run/varlib /run/aa-etc /run/persist /run/log /run/data /var/lib/bluetooth/38:BA:B0:11:22:33/AA:BB:CC:DD:EE:01 /var/lib/bluetooth/38:BA:B0:11:22:33/cache /var/log /stub
cp /usr/share/u2ac/aa-proxy-rs.config.toml /run/aa-etc/config.toml
printf "AA:BB:CC:DD:EE:01\n11:22:33:44:55:66\n" > /run/aa-etc/known_devices
printf '[General]\nName=Pixel 9\n' > /var/lib/bluetooth/38:BA:B0:11:22:33/AA:BB:CC:DD:EE:01/info
printf '[  12.3] u2ac-aa: start\n[  14.0] u2ac-aa: aa-proxy-rs started\n' > /run/log/u2ac-aa.log
printf 'wlan0: AP-ENABLED\n' > /run/log/hostapd.log
printf '2026-11-26 [INFO] session time: 12s\n' > /var/log/aa-proxy-rs.log
for c in persist u2ac-aa reboot reboot-recovery btmgmt; do printf '#!/bin/sh\necho "$0 $*" >> /run/stub.calls\necho "stub %s ok"\n' "$c" > /stub/$c; chmod +x /stub/$c; done
FAKE_PATH=/stub httpd -f -p 0.0.0.0:80 -h /usr/share/u2ac/www &
sleep 1000
