{ ... }:
#
# BCM2712 D0 stepping support for a known D0 Raspberry Pi 5 target.
#
# The generic Pi 5 DTB describes the C0 pin-controller register layout.
# Select the vendor's D0-specific board DTB before Linux probes UART, GPIO, or
# any other pinctrl client. Without it, D0 boards fault with an asynchronous
# SError in `brcmstb_pull_config_set`.
#
# This is deliberately not part of the universal Pi 5 base: C0 and D0 are
# different physical SoC steppings. Import it only for a confirmed D0 machine
# and every image that is intended to boot that same machine.
{
  hardware.raspberry-pi.config.all.options.device_tree = {
    enable = true;
    value = "bcm2712d0-rpi-5-b.dtb";
  };
}
