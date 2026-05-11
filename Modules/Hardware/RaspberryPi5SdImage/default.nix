{ lib, pkgs, ... }:
#
# Pi-5-aware augmentation for `sd-image-aarch64.nix`.
#
# The stock nixpkgs sd-image-aarch64 module only populates the
# firmware partition for Pi 2 / Pi 3 / Pi 4 / CM4 — it copies the
# bcm2710 + bcm2711 DTBs, the Pi 3/4 u-boot blobs, and writes a
# config.txt with [pi3] / [pi02] / [pi4] / [cm4] sections but no
# [pi5]. On a Pi 5 the EEPROM-resident bootloader reads
# config.txt, finds no [pi5] section, looks for
# `bcm2712-rpi-5-b.dtb`, doesn't find it, and refuses to chain
# with "Device-tree file bcm2712-rpi-5-b.dtb not found / The
# installed operating system (OS) does not indicate support for
# Raspberry Pi 5".
#
# This module fixes that by appending three commands to
# populateFirmwareCommands:
#   * copy bcm2712-rpi-5-b.dtb (Pi 5 device tree, present in
#     pkgs.raspberrypifw)
#   * copy a generic ARM64 u-boot (rpi_arm64_defconfig, which
#     works on Pi 5 — also Pi 3/4 — so the same blob serves all
#     three) as u-boot-rpi-arm64.bin
#   * overwrite config.txt with a Pi-5-aware version that adds
#     [pi5] pointing kernel= at the new u-boot blob; other Pi
#     sections from the upstream template are preserved so the
#     same image still boots on a Pi 3/4 if anyone tries
#
# Pulled into a separate module so any future Pi-5-bound sd-image
# in `flake.nix` picks it up by adding this path to its
# `modules =` list. Pi 4 images don't need this — the upstream
# sd-image-aarch64.nix already handles bcm2711 correctly.
#
let
  # Built as a fixed file rather than a heredoc inside the shell
  # commands so we don't have to fight Nix's indented-string
  # whitespace handling around the section headers.
  configTxt = pkgs.writeText "config.txt" ''
    [pi3]
    kernel=u-boot-rpi3.bin
    core_freq=250

    [pi02]
    kernel=u-boot-rpi3.bin

    [pi4]
    kernel=u-boot-rpi4.bin
    enable_gic=1
    armstub=armstub8-gic.bin
    disable_overscan=1
    arm_boost=1

    [pi5]
    kernel=u-boot-rpi-arm64.bin

    [cm4]
    otg_mode=1

    [all]
    arm_64bit=1
    enable_uart=1
    avoid_warnings=1
  '';
in
{
  sdImage.populateFirmwareCommands = lib.mkAfter ''
    cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2712-rpi-5-b.dtb firmware/
    cp ${pkgs.ubootRaspberryPiAarch64}/u-boot.bin firmware/u-boot-rpi-arm64.bin
    # `install` rather than `cp` for the config.txt overwrite —
    # the upstream populateFirmwareCommands already copied its own
    # config.txt here, and `cp` from a Nix store path preserves
    # the 0444 source mode on the destination, so a subsequent
    # `cp` to the same path fails with EACCES. `install -m 0644`
    # always creates the destination fresh with explicit mode.
    install -m 0644 ${configTxt} firmware/config.txt
  '';
}
