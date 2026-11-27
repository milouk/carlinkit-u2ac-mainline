# Third-party components

## Source used by the build

| Component | License | Where |
|---|---|---|
| Linux 7.2.15 / 7.3.6 | GPL-2.0 | kernel.org, with this project's kernel patches and configuration in `mainline/ocbm-u2ac.patch` |
| ocbm `baseline/` recipe (derived from f-io/LIVI) | GPL-3.0-or-later | [lvalen91/ocbm](https://github.com/lvalen91/ocbm) at the commit in `mainline/OCBM_BASE` |
| BusyBox, dropbear, hostapd, mtd-utils | GPL-2.0 / MIT-style / BSD | fetched and built from upstream source by the recipe (pinned versions and hashes in its `versions.env`) |
| aa-proxy-rs v1.3.0 | MIT | [aa-proxy/aa-proxy-rs](https://github.com/aa-proxy/aa-proxy-rs) tag `v1.3.0`, plus `mainline/aa-build/patches` |
| u2ac-ws2812 LED driver | GPL-2.0 | this project (`baseline/arm-imx6ul-u2ac/modules/` in the patch) |

## Prebuilt binaries in `mainline/ocbm-u2ac.patch`

These are carried in the board's rootfs overlay so that the image builds without a separate userland toolchain.

| Binary | Version | License | Source |
|---|---|---|---|
| `usr/bin/aa-proxy-rs` | v1.3.0 + patches 0001-0004 | MIT | built by `mainline/aa-build/build.sh v1.3.0` (static, armv7 musl) |
| `lib/libc.so.6`, `libm.so.6`, `ld-linux-armhf.so.3` | glibc 2.41 | LGPL-2.1-or-later | https://ftp.gnu.org/gnu/glibc/ |
| `lib/libgcc_s.so.1` | GCC runtime | GPL-3.0 with the GCC Runtime Library Exception | https://gcc.gnu.org/ |
| `usr/libexec/bluetooth/bluetoothd` | BlueZ 5.79 | GPL-2.0-or-later | https://www.kernel.org/pub/linux/bluetooth/ |
| `usr/bin/dbus-daemon`, `usr/lib/libdbus-1.so.3` | D-Bus 1.14.10 | AFL-2.1 or GPL-2.0-or-later | https://dbus.freedesktop.org/releases/dbus/ |
| `usr/lib/libglib-2.0.so.0` | GLib 2.x | LGPL-2.1-or-later | https://download.gnome.org/sources/glib/ |
| `usr/lib/libpcre2-8.so.0` | PCRE2 10.47 | BSD-3-Clause | https://github.com/PCRE2Project/pcre2/releases |
| `usr/lib/libexpat.so.1` | expat 2.7.4 | MIT | https://github.com/libexpat/libexpat/releases |

The glibc, BlueZ, D-Bus, GLib, PCRE2 and expat binaries are unmodified copies from the aa-proxy project's
Buildroot-based release images. The corresponding source is the upstream release of each version listed above.

## Firmware that is not included

The Broadcom BCM4358 firmware (Wi-Fi `brcmfmac4358-sdio.bin`, its board file `brcmfmac4358-sdio.txt` and the
Bluetooth patch `BCM4358A3.hcd`) is Broadcom's and is not redistributed here. `mainline/firmware/fetch-bcm4358.sh`
takes it, hash-checked, from Carlinkit's own U2AC_AUTOKIT 2023.10.14.1711 update image as mirrored publicly by
[ludwig-v/wireless-carplay-dongle-reverse-engineering](https://github.com/ludwig-v/wireless-carplay-dongle-reverse-engineering).
