{ config, lib, pkgs, ... }:
#
# PhysicalServerProvisioning profile — minimalist first-boot image
# that flips itself onto a target nixosConfiguration once that
# configuration is "ready" upstream.
#
# Workflow (B2 in the design discussion of 2026-05-09):
#
#   1. Operator builds the SD image from this profile + the target
#      machine's hardware module + sd-image-aarch64. The resulting
#      image is small (no soffice, no realesrgan, no Mono runtime
#      — just Linux + sshd + this script). Cross-compilable from
#      x86_64 because the closure is small enough to fit in
#      cache.nixos.org's aarch64 binaries without falling back to
#      qemu-user.
#   2. Flash, boot. sshd starts, ssh host-keys generate. The
#      `first-boot-switch` systemd timer fires `OnBootSec=1m` and
#      runs the service.
#   3. The service does:
#        nixos-rebuild boot --refresh --flake <targetFlakeUri>#<name>
#        systemctl reboot
#      `--refresh` re-fetches the flake input each attempt, so a
#      previously-cached "ref doesn't exist yet" lookup gets
#      replaced by the now-pushed ref the moment the operator
#      lands the secrets. `boot` doesn't activate the new
#      generation; the reboot picks it up cleanly.
#   4. If the target ref doesn't exist (operator hasn't pushed
#      the readiness tag yet), nix returns 404 from GitHub and
#      the rebuild errors. systemd marks the service failed; the
#      timer's `OnUnitInactiveSec=1m` fires it again in a minute.
#      The image keeps retrying until the readiness signal is
#      live, then flips itself.
#
# Readiness gating via flake ref. The recommended pattern is to
# use a tag or a branch in <targetFlakeUri> that you push only
# after the target machine's secrets are encrypted to its host
# age key:
#   targetFlakeUri = "github:hypersw/HyperNix?ref=ghosthome-ready"
# Until that branch / tag exists, the rebuild fails cleanly with
# a 404. Once you push it, the next retry succeeds.
#
# After the switch lands, the new system's localFlake activation
# (from AnyMachineBase) writes /etc/nixos/flake.nix pointing at
# `github:hypersw/HyperNix` (master, no ref filter), so the
# auto-rebuild-on-push loop tracks master from then on. The
# readiness ref is one-shot — only used by the provisioning
# image's first-boot script.
#
# What the image carries: Pi-hardware module + openssh + this
# service. Deliberately not AnyMachineBase — that pulls in
# auto-rebuild + telegram-alerts + sops which we don't need on
# the provisioning side and would only fail noisily without
# secrets. The whole point is "boot, retry until success, reboot
# into the real config".
#
let
  cfg = config.profiles.physicalServerProvisioning;
in
{
  options.profiles.physicalServerProvisioning = {
    enable = lib.mkEnableOption "Minimalist first-boot provisioning image";

    targetFlakeUri = lib.mkOption {
      type = lib.types.str;
      description = ''
        Flake URI the first-boot service rebuilds against. Should
        include a ref (branch or tag) the operator only pushes
        once the target machine's secrets are encrypted upstream
        — e.g.
        <literal>github:hypersw/HyperNix?ref=ghosthome-ready</literal>.
        Until the ref exists, the rebuild errors with 404 and the
        timer keeps retrying.
      '';
    };

    targetConfigName = lib.mkOption {
      type = lib.types.str;
      description = ''
        Name of the upstream nixosConfiguration to switch into
        (e.g. "GhostHome"). This becomes the `#name` part of the
        `nixos-rebuild boot --flake URI#name` invocation.
      '';
    };

    retryIntervalSec = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = ''
        Seconds between rebuild attempts. The timer fires once
        OnBootSec from boot, then OnUnitInactiveSec from the
        service's last completion. 60 s is a sensible default
        that doesn't hammer GitHub but reacts within a minute
        of the operator landing the readiness ref.
      '';
    };

    administrator = {
      authorizedKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = ''
          Optional ssh keys for an "operator" account on the
          provisioning image. Strictly for emergency access if
          the auto-switch keeps failing and the operator wants
          to ssh in to look. The image is designed to never need
          interactive login — leave this empty unless debugging.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    networking = {
      # DHCP on every Ethernet interface; no WiFi (the operator
      # hasn't supplied a PSK, this image is short-lived anyway).
      useDHCP = true;
      firewall = {
        enable = true;
        allowedTCPPorts = [ 22 ];
      };
    };

    # sshd's only purpose here is to let the operator pull the
    # host's just-generated ssh ed25519 public key with
    # `ssh-keyscan` (or convert via ssh-to-age) so they can
    # encrypt the target machine's sops file to it without
    # logging in.
    services.openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "no";
        PasswordAuthentication = false;
      };
    };
    security.sudo.wheelNeedsPassword = false;
    users.users.root.hashedPassword = "!";

    # Optional emergency-access account. Empty by default — the
    # image isn't supposed to need login.
    users.users.operator = lib.mkIf (cfg.administrator.authorizedKeys != []) {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = cfg.administrator.authorizedKeys;
    };

    nix = {
      settings.experimental-features = [ "nix-command" "flakes" ];
    };

    # The first-boot service. Runs once per timer trigger. Type=
    # oneshot + no Restart=on-failure — we rely on the timer's
    # OnUnitInactiveSec to re-trigger, which gives a cleaner
    # "service failed, will retry in 1m" signal in journalctl
    # than systemd's restart counter.
    systemd.services.first-boot-switch = {
      description = "Switch to the target nixosConfiguration once the readiness ref is live";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        # Run from /var/empty — defensive CWD pin in case of any
        # CWD-relative writes inside nixos-rebuild.
        WorkingDirectory = "/var/empty";
        ExecStart = pkgs.writeShellScript "first-boot-switch" ''
          set -eu
          # --refresh: ignore any cached "ref doesn't exist" entry
          # so the moment the operator pushes the readiness ref,
          # the next retry picks it up. --no-write-lock-file: don't
          # try to write a flake.lock anywhere (the image's rootfs
          # is read-only at activation time anyway).
          ${pkgs.nixos-rebuild}/bin/nixos-rebuild boot \
            --refresh \
            --no-write-lock-file \
            --flake "${cfg.targetFlakeUri}#${cfg.targetConfigName}"
          # Sync filesystems, then reboot. systemctl reboot
          # returns immediately and the kernel handles the rest.
          ${pkgs.coreutils}/bin/sync
          ${pkgs.systemd}/bin/systemctl reboot
        '';
      };
    };

    systemd.timers.first-boot-switch = {
      description = "Trigger first-boot-switch ${toString cfg.retryIntervalSec}s after boot, retry every ${toString cfg.retryIntervalSec}s on failure";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "${toString cfg.retryIntervalSec}s";
        # Re-fire OnUnitInactiveSec after the service deactivates
        # (whether by success or failure). On success the reboot
        # happens before this matters; on failure it's the retry.
        OnUnitInactiveSec = "${toString cfg.retryIntervalSec}s";
        Unit = "first-boot-switch.service";
      };
    };

    # Tiny systemPackages — htop is enough for the operator to
    # `top` if they ssh in to see what's chewing CPU during a
    # rebuild. Everything else lands with the full configuration
    # on first reboot.
    environment.systemPackages = with pkgs; [ htop ];
  };
}
