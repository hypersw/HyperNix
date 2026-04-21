#!/usr/bin/env python3
# ─────────────────────────────────────────────────────────────────────────
# Scan-button probe for the Epson Perfection V33 (USB 04b8:0142).
#
# This is the "session-locked" variant. The V33 only returns a full
# 4-byte info header + data payload to `ESC !` (0x1B 0x21) if the
# scanner is in the locked state. Without the lock it just ACKs (0x06)
# the first byte and stops responding — which is what our earlier
# minimal probe hit. The full ESC/I sequence:
#
#   ESC (      0x1B 0x28            → lock,  expect 0x80 (OK) / 0x40 (busy) / 0x15 (NAK)
#   ESC @      0x1B 0x40            → init
#   ESC FS I   0x1B 0x1C 0x49       → read 80-byte extended identity;
#                                      byte 44 bit 0 = "has push button"
#   ESC !      0x1B 0x21            → poll button; reply = "0x02 STS LEN_LO LEN_HI"
#                                      + LEN bytes of data; data[0] low bits encode
#                                      which button is pressed (0 = none).
#   ESC )      0x1B 0x29            → unlock on exit
#
# Sources: iscan backend/epkowa.c get_push_button_status() +
# backend/command.c lines 419-420, 543-544 (see project PLAN.md
# "Scanner Button Detection (Epson V33)" section for the research
# that nailed this down).
#
# USAGE — on the Pi, with scanner attached and no SANE client in use:
#
#   # If scanimage just ran, wait ~5 s for the plugin to let go of the
#   # scanner, otherwise ESC ( will get 0x40 (busy) forever.
#   sudo nix-shell -p python3 python3Packages.pyusb \
#     --run 'python3 /tmp/probe-button.py'
#
# The script prints each poll whose bytes differ from the previous
# one. Walk to the scanner, press buttons slowly in sequence, come
# back, read the log.
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
POLL_INTERVAL_S = 0.15
TIMEOUT_MS = 1000

# ESC/I command bytes
ESC = 0x1B
FS  = 0x1C
LOCK   = bytes([ESC, 0x28])   # ESC '('
UNLOCK = bytes([ESC, 0x29])   # ESC ')'
INIT   = bytes([ESC, 0x40])   # ESC '@'
EXT_ID = bytes([ESC, FS, 0x49])  # ESC FS I
BUTTON = bytes([ESC, 0x21])   # ESC '!'

ACK = 0x06
NAK = 0x15

_dev = None       # keep globals so the signal handler can see them
_ep_out = None
_ep_in = None
_locked = False


def log(msg):
    ts = time.strftime("%H:%M:%S") + f".{int((time.time() % 1) * 1000):03d}"
    print(f"[{ts}] {msg}", flush=True)


def find_scanner():
    dev = usb.core.find(idVendor=VID, idProduct=PID)
    if dev is None:
        log(f"ERROR scanner {VID:04x}:{PID:04x} not found on USB")
        sys.exit(2)
    return dev


def open_device(dev):
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
        log("ERROR no bulk endpoints found")
        sys.exit(3)
    return dev, ep_in, ep_out


def bulk_write(cmd):
    _dev.write(_ep_out.bEndpointAddress, cmd, timeout=TIMEOUT_MS)


def bulk_read(n, timeout_ms=TIMEOUT_MS):
    return bytes(_dev.read(_ep_in.bEndpointAddress, n, timeout=timeout_ms))


def hex_of(data):
    return " ".join(f"{b:02x}" for b in data)


def cleanup(*_args):
    global _locked
    if _locked and _dev is not None and _ep_out is not None:
        try:
            bulk_write(UNLOCK)
            reply = bulk_read(1)
            log(f"cleanup: unlock → {hex_of(reply)}")
        except Exception as e:
            log(f"cleanup: unlock failed ({e})")
        finally:
            _locked = False
    sys.exit(0)


def lock_session():
    """Send ESC ( and interpret the single-byte response."""
    global _locked
    bulk_write(LOCK)
    reply = bulk_read(1)
    if not reply:
        log("ERROR lock: no reply")
        return False
    b = reply[0]
    if b == 0x80:
        log(f"lock OK (0x{b:02x})")
        _locked = True
        return True
    if b == 0x40:
        log(f"lock BUSY (0x{b:02x}) — another client has it; wait for it to release")
        return False
    if b == NAK:
        log(f"lock NAK (0x{b:02x}) — device may not support session locking")
        return False
    log(f"lock unexpected reply: 0x{b:02x}")
    return False


def init_device():
    """ESC @ — initialize."""
    bulk_write(INIT)
    # ESC @ usually returns nothing / ACK. Try to read an optional ACK
    # with a short timeout; don't care if nothing comes back.
    try:
        reply = bulk_read(1, timeout_ms=200)
        log(f"init: reply {hex_of(reply)}")
    except usb.core.USBError:
        log("init: no reply (ok)")


def get_extended_identity():
    """ESC FS I — returns an 80-byte "extended identity" block.

    Byte 44 bit 0 = has-push-button capability.
    """
    bulk_write(EXT_ID)
    # 4-byte info header + body. Info header is 0x02 STS LEN_LO LEN_HI
    info = bulk_read(4)
    log(f"ext id info header: {hex_of(info)}")
    if len(info) < 4 or info[0] != 0x02:
        log(f"ext id: unexpected info header")
        return None
    body_len = info[2] | (info[3] << 8)
    body = bulk_read(body_len) if body_len else b""
    log(f"ext id body ({body_len} bytes): {hex_of(body[:16])}{' …' if len(body) > 16 else ''}")
    if len(body) > 44:
        has_button = bool(body[44] & 0x01)
        log(f"ext id byte 44 = 0x{body[44]:02x}  → push-button capability: {has_button}")
    return body


def poll_button():
    """Send ESC ! and parse the reply.

    Reply layout:  0x02 STS LEN_LO LEN_HI  |  LEN data bytes
    data[0] low bits = which button (0 = none pressed).
    """
    bulk_write(BUTTON)
    info = bulk_read(4)
    if len(info) < 4:
        return None, f"short info header ({hex_of(info)})"
    if info[0] != 0x02:
        return None, f"bad info header first byte ({hex_of(info)})"
    data_len = info[2] | (info[3] << 8)
    data = bulk_read(data_len) if data_len else b""
    return (info, data), None


def main():
    global _dev, _ep_in, _ep_out

    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, cleanup)

    _dev = find_scanner()
    _dev, _ep_in, _ep_out = open_device(_dev)

    log("acquiring session lock…")
    if not lock_session():
        log("could not acquire lock — exiting")
        sys.exit(4)

    init_device()
    get_extended_identity()

    log("listening — press Ctrl-C to stop. Press scanner buttons slowly.")
    previous = None
    last_err = None
    while True:
        try:
            result, err = poll_button()
        except usb.core.USBError as e:
            err_txt = str(e)
            if err_txt != last_err:
                log(f"ERR poll: {err_txt}")
                last_err = err_txt
            time.sleep(POLL_INTERVAL_S)
            continue
        last_err = None

        if err is not None:
            if err != last_err:
                log(f"malformed: {err}")
                last_err = err
        else:
            info, data = result
            combined = hex_of(info) + "  ║  " + (hex_of(data) if data else "(no data)")
            if combined != previous:
                marker = "  (baseline)" if previous is None else ""
                pressed = data[0] & 0x03 if data else 0
                label = {0: "none", 1: "scan", 2: "alt1", 3: "alt2"}.get(pressed, f"?{pressed}")
                log(f"button={label:>5}  {combined}{marker}")
                previous = combined

        time.sleep(POLL_INTERVAL_S)


if __name__ == "__main__":
    main()
