#!/usr/bin/env python3
# ─────────────────────────────────────────────────────────────────────────
# Scan-button probe for the Epson Perfection V33 (USB 04b8:0142).
#
# epkowa doesn't surface the scanner's physical buttons via SANE, and
# the V33 is not a USB-HID button device — button state is only
# retrievable by sending a vendor-specific ESC/I bulk command and
# reading the response. This script is the reverse-engineering step
# before we wire button polling into the daemon.
#
# Usage (on the Pi, with the scanner attached):
#
#   1. Make sure no SANE client is talking to the scanner
#      (stop any in-flight scanimage / saned). scanimage -L holds the
#      device briefly; wait a few seconds after it returns.
#
#   2. Run this script as a user in the `scanner` group (or as root):
#
#        nix-shell -p python3 python3Packages.pyusb --run \
#          'python3 probe-button.py'
#
#   3. Follow the prompts: release all buttons, press Enter; then
#      hold each button in turn, press Enter, note the bytes that
#      differ. The script diffs and highlights the changed bits.
#
# The response format is modeled after scanbuttond's
# backends/epson.c (ESC ! query, 4-byte reply). The V33 may differ;
# that's exactly what we're finding out.
# ─────────────────────────────────────────────────────────────────────────

import sys
import time

try:
    import usb.core
    import usb.util
except ImportError:
    print("pyusb is required. Try:  nix-shell -p python3Packages.pyusb", file=sys.stderr)
    sys.exit(1)

VID, PID = 0x04b8, 0x0142


def find_scanner():
    dev = usb.core.find(idVendor=VID, idProduct=PID)
    if dev is None:
        print(f"Scanner {VID:04x}:{PID:04x} not found on USB bus.", file=sys.stderr)
        sys.exit(2)
    return dev


def open_device(dev):
    # Detach any kernel driver (usbscanner, usblp) that might be holding the
    # interface. SANE/epkowa uses libusb so isn't a kernel-driver holder, but
    # belt-and-braces.
    for cfg in dev:
        for intf in cfg:
            if dev.is_kernel_driver_active(intf.bInterfaceNumber):
                try:
                    dev.detach_kernel_driver(intf.bInterfaceNumber)
                except usb.core.USBError:
                    pass
    dev.set_configuration()
    cfg = dev.get_active_configuration()
    intf = cfg[(0, 0)]
    # Find the first bulk-in + bulk-out endpoints on this interface.
    ep_in = usb.util.find_descriptor(intf, custom_match=lambda e:
        usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_IN and
        usb.util.endpoint_type(e.bmAttributes) == usb.util.ENDPOINT_TYPE_BULK)
    ep_out = usb.util.find_descriptor(intf, custom_match=lambda e:
        usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_OUT and
        usb.util.endpoint_type(e.bmAttributes) == usb.util.ENDPOINT_TYPE_BULK)
    if ep_in is None or ep_out is None:
        print("No bulk endpoints found.", file=sys.stderr)
        sys.exit(3)
    return dev, ep_in, ep_out


def poll_button(dev, ep_in, ep_out, timeout_ms=500):
    # ESC '!' = 0x1B 0x21 — scanbuttond's "request button status" on Epsons.
    try:
        dev.write(ep_out.bEndpointAddress, b"\x1b!", timeout=timeout_ms)
    except usb.core.USBError as e:
        return None, f"write failed: {e}"
    try:
        data = dev.read(ep_in.bEndpointAddress, 64, timeout=timeout_ms)
    except usb.core.USBError as e:
        return None, f"read failed: {e}"
    return bytes(data), None


def diff_hex(a: bytes, b: bytes) -> str:
    # Highlight byte positions that differ.
    if len(a) != len(b):
        return f"(length differs: {len(a)} vs {len(b)})"
    out = []
    for i, (x, y) in enumerate(zip(a, b)):
        if x == y:
            out.append(f"  {x:02x}")
        else:
            out.append(f"[{y:02x}]")
    return " ".join(out)


def main():
    dev = find_scanner()
    dev, ep_in, ep_out = open_device(dev)

    print("\n=== button probe ===\n")
    print("Baseline capture (all buttons released).")
    input("Press Enter once no button is pressed…")
    base, err = poll_button(dev, ep_in, ep_out)
    if err:
        print(f"baseline failed: {err}", file=sys.stderr)
        sys.exit(4)
    print(f"baseline bytes: {base.hex(' ')}  (len={len(base)})\n")

    buttons = ["Scan (single-sheet)", "Copy", "PDF", "Send (email)"]
    observations = {}
    for name in buttons:
        input(f"Hold the [{name}] button and press Enter…")
        captures = []
        for _ in range(5):
            reply, err = poll_button(dev, ep_in, ep_out)
            if reply is not None:
                captures.append(reply)
            time.sleep(0.1)
        if not captures:
            print(f"  no successful poll for {name}")
            continue
        majority = max(set(captures), key=captures.count)
        print(f"  {name}: {diff_hex(base, majority)}")
        observations[name] = majority

    print("\nSummary (bold = differs from baseline):\n")
    for name, reply in observations.items():
        print(f"  {name}: {diff_hex(base, reply)}")
    print("\nLook for a byte whose value differs only while the Scan button is held; that's our bit.")


if __name__ == "__main__":
    main()
