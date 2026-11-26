#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""mockhu.py: the Mac plays the car's head unit on the dongle's USB port (pyusb + libusb).

What a wired-Android-Auto head unit does with a phone, against aa-proxy-rs's FunctionFS gadget:
  1. sees the phone-like MTP device (18d1:4ee1, aa-proxy-rs "legacy" stage), asks AOA GET_PROTOCOL,
     sends the six identity strings, waits --consent seconds (a car that asks the driver "Enable Android
     Auto?" before it switches the phone, e.g. Ford SYNC 3), then ACCESSORY_START;
  2. opens the re-enumerated accessory (18d1:2d00), sends VERSION_REQUEST, expects the phone's
     VERSION_RESPONSE (carsim/fakephone.c on the dongle answers it);
  3. echo tests through car -> dongle -> phone -> car: frame sizes around the 512-byte packet boundary
     (a missing zero-length packet stalls exactly those), then a bulk run for throughput.
Exit 0 only when every step passed. Usage: mockhu.py [--consent S] [--wait S] [--bulk N]
"""
import argparse
import os
import random
import sys
import time

import usb.backend.libusb1
import usb.core
import usb.util

GOOG = 0x18D1
MTP_PID, ACC_PIDS = 0x4EE1, (0x2D00, 0x2D01)
T0 = time.time()


def log(*a):
    print(f"[{time.time() - T0:6.2f}] ", *a, flush=True)


def backend():
    for p in ("/opt/homebrew/lib/libusb-1.0.dylib", "/usr/local/lib/libusb-1.0.dylib"):
        if os.path.exists(p):
            return usb.backend.libusb1.get_backend(find_library=lambda _x, p=p: p)
    return None


BE = backend()


def find(pids):
    for p in pids:
        d = usb.core.find(idVendor=GOOG, idProduct=p, backend=BE)
        if d is not None:
            return d
    return None


def wait_for(pids, secs):
    end = time.time() + secs
    while time.time() < end:
        d = find(pids)
        if d is not None:
            return d
        time.sleep(0.1)
    return None


def describe(d):
    try:
        s = f"{d.idVendor:04x}:{d.idProduct:04x} '{usb.util.get_string(d, d.iManufacturer)}' " \
            f"'{usb.util.get_string(d, d.iProduct)}' serial '{usb.util.get_string(d, d.iSerialNumber)}'"
    except Exception as e:  # strings need the device open; macOS may refuse
        s = f"{d.idVendor:04x}:{d.idProduct:04x} (strings: {e})"
    for cfg in d:
        for intf in cfg:
            eps = ", ".join(f"{e.bEndpointAddress:02x}/{e.wMaxPacketSize}" for e in intf)
            s += f"\n           intf {intf.bInterfaceNumber} class {intf.bInterfaceClass:02x}/" \
                 f"{intf.bInterfaceSubClass:02x}/{intf.bInterfaceProtocol:02x} eps {eps}"
    return s


def aoa_switch(d, consent):
    ver = d.ctrl_transfer(0xC0, 51, 0, 0, 2, timeout=2000)
    log(f"AOA GET_PROTOCOL -> {ver[0] | ver[1] << 8}")
    ids = ["Android", "Android Auto", "Android Auto", "2.0.1", "https://www.android.com/auto/", "HU-MOCK-0001"]
    for i, s in enumerate(ids):
        d.ctrl_transfer(0x40, 52, 0, i, s.encode() + b"\0", timeout=2000)
    log("AOA identity strings sent")
    if consent:
        log(f"car shows 'Enable Android Auto?' for {consent} s before ACCESSORY_START")
        time.sleep(consent)
    try:
        d.ctrl_transfer(0x40, 53, 0, 0, None, timeout=2000)
        log("AOA ACCESSORY_START sent")
    except usb.core.USBError as e:  # the device may drop off the bus while answering
        log(f"AOA ACCESSORY_START: {e} (device re-enumerating?)")
    usb.util.dispose_resources(d)


class Link:
    def __init__(self, d):
        self.d = d
        try:
            d.set_configuration()
        except usb.core.USBError as e:
            log(f"set_configuration: {e} (continuing)")
        cfg = d.get_active_configuration()
        intf = cfg[(0, 0)]
        usb.util.claim_interface(d, intf.bInterfaceNumber)
        self.out = usb.util.find_descriptor(
            intf, custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_OUT)
        self.inp = usb.util.find_descriptor(
            intf, custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_IN)
        self.rx = bytearray()
        log(f"accessory open: OUT {self.out.bEndpointAddress:02x} IN {self.inp.bEndpointAddress:02x} "
            f"(max packet {self.inp.wMaxPacketSize})")

    zlp = True

    def send(self, frame):
        n = self.out.write(frame, timeout=5000)
        if n != len(frame):
            raise IOError(f"short write {n}/{len(frame)}")
        # a transfer that ends on a full packet needs a zero-length packet to end it for a reader that asked for
        # more (a phone's f_accessory reads 16 KiB): what a head unit that works with phones sends
        if self.zlp and len(frame) % self.out.wMaxPacketSize == 0:
            self.out.write(b"", timeout=5000)

    def frame(self, secs):
        """next frame from the car's read side: (channel, flags, payload)"""
        end = time.time() + secs
        while True:
            if len(self.rx) >= 4:
                ln = self.rx[2] << 8 | self.rx[3]
                hl = 8 if (self.rx[1] & 3) == 1 else 4
                if len(self.rx) >= hl + ln:
                    ch, fl, pl = self.rx[0], self.rx[1], bytes(self.rx[hl:hl + ln])
                    del self.rx[:hl + ln]
                    return ch, fl, pl
            left = end - time.time()
            if left <= 0:
                raise TimeoutError(f"no complete frame within {secs} s (have {len(self.rx)} B)")
            try:
                self.rx += bytes(self.inp.read(16384, timeout=int(max(left, 0.05) * 1000)))
            except usb.core.USBTimeoutError:
                pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--consent", type=float, default=0, help="seconds between AOA strings and ACCESSORY_START")
    ap.add_argument("--wait", type=float, default=120, help="seconds to wait for the dongle's gadget")
    ap.add_argument("--bulk", type=int, default=200, help="16 KiB frames in the throughput run")
    ap.add_argument("--no-zlp", action="store_true", help="car sends no zero-length packet after full-packet writes")
    ap.add_argument("--version-only", action="store_true", help="stop after VERSION_RESPONSE (real phone on the far side)")
    a = ap.parse_args()
    Link.zlp = not a.no_zlp
    if BE is None:
        sys.exit("no libusb-1.0 found (brew install libusb)")

    log(f"waiting up to {a.wait:.0f} s for the dongle's Android device (18d1:4ee1) or accessory (18d1:2d00)")
    d = wait_for((MTP_PID,) + ACC_PIDS, a.wait)
    if d is None:
        log("FAIL: the dongle never showed an Android device on USB")
        return 1
    log("device: " + describe(d))
    if d.idProduct == MTP_PID:
        aoa_switch(d, a.consent)
        d = wait_for(ACC_PIDS, 30)
        if d is None:
            log("FAIL: no accessory (18d1:2d00) within 30 s of ACCESSORY_START")
            return 1
        log("accessory: " + describe(d))
    else:
        log("note: the dongle came up directly as an accessory (no MTP stage)")

    link = Link(d)
    fails = 0
    link.send(bytes([0, 3, 0, 6, 0, 1, 0, 1, 0, 7]))
    log("VERSION_REQUEST 1.7 sent")
    try:
        ch, fl, pl = link.frame(15)
        if ch == 0 and pl[:2] == b"\x00\x02":
            log(f"PASS version: VERSION_RESPONSE {pl[2] << 8 | pl[3]}.{pl[4] << 8 | pl[5]} status {pl[6] << 8 | pl[7]}")
        else:
            log(f"FAIL version: unexpected frame ch {ch} flags {fl:02x} {pl[:8].hex()}")
            fails += 1
    except Exception as e:
        log(f"FAIL version: {e}")
        return 1

    if a.version_only:  # a real phone answered: it would want the car's TLS next, which a mock cannot do
        log(f"mockhu: {fails} failure(s) (version exchange only)")
        return 1 if fails else 0

    rnd = random.Random(7)
    # frame sizes (header + payload) on both sides of the 512-byte packet boundary
    for total in (64, 511, 512, 513, 1024, 4096, 8192, 16384, 1000, 5000, 12345):
        pl = b"\x80\x03" + bytes(rnd.getrandbits(8) for _ in range(total - 6))
        f = bytes([3, 3, len(pl) >> 8, len(pl) & 255]) + pl
        t = time.time()
        try:
            link.send(f)
            ch, fl, got = link.frame(5)
            ok = ch == 3 and got == pl
            log(f"{'PASS' if ok else 'FAIL'} echo {total:5d} B in {1000 * (time.time() - t):6.1f} ms")
            fails += not ok
        except Exception as e:
            log(f"FAIL echo {total:5d} B: {e}")
            fails += 1

    pl = b"\x80\x03" + os.urandom(16380 - 2)
    f = bytes([3, 3, len(pl) >> 8, len(pl) & 255]) + pl
    t, got_n, sent_n = time.time(), 0, 0
    try:
        for _ in range(a.bulk):  # keep at most 4 frames in flight
            link.send(f)
            sent_n += 1
            if sent_n - got_n >= 4:
                _, _, g = link.frame(5)
                got_n += g == pl
        while got_n < sent_n:
            _, _, g = link.frame(5)
            got_n += g == pl
        dt = time.time() - t
        mb = 2 * a.bulk * len(f) / 1e6
        log(f"PASS bulk: {a.bulk} x 16 KiB echoed intact in {dt:.2f} s = {mb / dt:.2f} MB/s both directions combined")
    except Exception as e:
        log(f"FAIL bulk after {sent_n} sent / {got_n} back: {e}")
        fails += 1
    log(f"mockhu: {fails} failure(s)")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
