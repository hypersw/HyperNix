#!/usr/bin/env python3
# ─────────────────────────────────────────────────────────────────────────
# Scan-button probe for the Epson Perfection V33 (USB 04b8:0142).
#
# Non-interactive: starts polling, prints every response that differs
# from the previous one, keeps running until Ctrl-C. Go to the scanner,
# press buttons slowly in a known order, come back, read the log, map
# the bytes/bits to buttons.
#
# epkowa doesn't surface the scanner's physical buttons via SANE, and
# the V33 is not a USB-HID button device — button state is only
# retrievable by sending a vendor-specific ESC/I bulk command and
# reading the response. We send `ESC !` (0x1B 0x21) on the bulk-out
# endpoint, read the bulk-in response, watch for changes.
#
# Usage (on the Pi, with the scanner attached, no SANE client running):
#
#   nix-shell -p python3 python3Packages.pyusb --run 'python3 probe-button.py'
#
# Suggested button sequence to press: Scan → (wait) → Copy → (wait) → PDF →
# (wait) → Send. A few seconds between each, so the baseline-return
# transition is visible and the "pressed" window is unambiguous in the log.
# ─────────────────────────────────────────────────────────────────────────

import signal
import sys
import time

try:
    import usb.core
    import usb.util
except ImportError:
    print("pyusb is required. Try:  nix-shell -p python3Packages.pyusb",
          file=sys.stderr)
    sys.exit(1)

VID, PID = 0x04b8, 0x0142
POLL_INTERVAL_S = 0.15   # 150ms — fast enough to catch a press, slow enough
                         # to not saturate the USB bus
READ_LEN = 64            # generous; real response is expected to be 4 bytes
READ_TIMEOUT_MS = 500


def find_scanner():
    dev = usb.core.find(idVendor=VID, idProduct=PID)
    if dev is None:
        print(f"Scanner {VID:04x}:{PID:04x} not found on USB bus.",
              file=sys.stderr)
        sys.exit(2)
    return dev


def open_device(dev):
    # Detach kernel driver if any (usbscanner, usblp) is holding the
    # interface. SANE/epkowa uses libusb so isn't a kernel-driver holder,
    # but belt-and-braces.
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
    ep_in = usb.util.find_descriptor(
        intf, custom_match=lambda e:
        usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_IN
        and usb.util.endpoint_type(e.bmAttributes) == usb.util.ENDPOINT_TYPE_BULK)
    ep_out = usb.util.find_descriptor(
        intf, custom_match=lambda e:
        usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_OUT
        and usb.util.endpoint_type(e.bmAttributes) == usb.util.ENDPOINT_TYPE_BULK)
    if ep_in is None or ep_out is None:
        print("No bulk endpoints found.", file=sys.stderr)
        sys.exit(3)
    return dev, ep_in, ep_out


def poll_once(dev, ep_in, ep_out):
    try:
        dev.write(ep_out.bEndpointAddress, b"\x1b!", timeout=READ_TIMEOUT_MS)
    except usb.core.USBError as e:
        return None, f"write: {e}"
    try:
        data = dev.read(ep_in.bEndpointAddress, READ_LEN, timeout=READ_TIMEOUT_MS)
    except usb.core.USBError as e:
        return None, f"read: {e}"
    return bytes(data), None


def fmt(data: bytes) -> str:
    hex_part = " ".join(f"{b:02x}" for b in data)
    ascii_part = "".join(
        chr(b) if 32 <= b < 127 else "." for b in data)
    return f"{hex_part}   |{ascii_part}|   ({len(data)} bytes)"


def ts() -> str:
    return time.strftime("%H:%M:%S") + f".{int((time.time() % 1) * 1000):03d}"


def main():
    # Ctrl-C: clean exit, no traceback
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))

    dev = find_scanner()
    dev, ep_in, ep_out = open_device(dev)

    print("listening — press Ctrl-C to stop. Go press buttons slowly.\n",
          flush=True)

    previous = None
    error_seen = None
    while True:
        reply, err = poll_once(dev, ep_in, ep_out)
        if err is not None:
            # Only print the error once per distinct message so we don't
            # spam the log on chronic failures.
            if err != error_seen:
                print(f"[{ts()}]  ERR {err}", flush=True)
                error_seen = err
            time.sleep(POLL_INTERVAL_S)
            continue
        error_seen = None

        if reply != previous:
            marker = "  (baseline)" if previous is None else ""
            print(f"[{ts()}]  {fmt(reply)}{marker}", flush=True)
            previous = reply

        time.sleep(POLL_INTERVAL_S)


if __name__ == "__main__":
    main()
