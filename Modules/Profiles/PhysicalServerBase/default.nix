{ config, lib, pkgs, ... }:
#
# PhysicalServerBase profile — the "things every machine I run wants"
# baseline. Imports the cross-cutting infra modules (auto-rebuild,
# telegram alerts) plus a sane SSH/sudo/swap/nix-gc bundle.
#
# Anything Pi-specific (hardware blobs, brownout-targeting kernel
# modules, multi-homed networking) stays in the per-machine
# configuration; this profile is hardware-agnostic and applies the
# same on Pi 4, Pi 5, x86_64 lab boxes, microVM front-ends, etc.
#
# Convention: option-based, not just import-based. The caller sets
# `profiles.physicalServerBase.alerts.tokenFile` etc., and the type
# system flags missing values at eval time — which is exactly the
# "list of secrets you must supply" surface we want, visible without
# having to grep for sops keys across submodules.
#
let
  cfg = config.profiles.physicalServerBase;
in
{
  imports = [
    ../../System/AutoRebuildOnPush
    ../../Monitoring/TelegramAlerts
  ];

  options.profiles.physicalServerBase = {
    enable = lib.mkEnableOption "Cross-cutting base profile for any physical server";

    autoUpgrade = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run nixos-rebuild monthly to pick up nixpkgs+upstream changes.";
      };
      flake = lib.mkOption {
        type = lib.types.str;
        default = "/etc/nixos#default";
        description = ''
          Flake reference the auto-upgrade service rebuilds against.
          Defaults to the local /etc/nixos flake's "default" output —
          the localFlake activation script (machine-specific config)
          generates that file pointing at the upstream HyperNix
          configuration.
        '';
      };
    };

    autoRebuildOnPush = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Poll upstream HyperNix for changes every few minutes, rebuild
          when something lands. Cheap config-iteration loop while the
          machine is being shaped; can be disabled on machines whose
          config has stabilised.
        '';
      };
    };

    alerts = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Telegram-alerts service for systemd OnFailure events,
          monthly auto-upgrade reports, and explicit operator
          messages.
        '';
      };
      tokenFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          Path to a file containing the monitoring bot's API token.
          Typically <literal>config.sops.secrets.NAME.path</literal>
          where the sops secret lives in the per-machine
          configuration's secrets file. The base profile takes a
          path rather than a sops-secret reference so the secret-
          delivery story (sops, agenix, raw file, …) stays in the
          machine config.
        '';
      };
      alertsChatIdFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to file containing the Telegram chat id for alerts.";
      };
      logChatIdFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to file containing the Telegram chat id for log forwards.";
      };
      configRevision = lib.mkOption {
        type = lib.types.str;
        default = "unknown";
        description = ''
          Git revision of the upstream config (HyperNix) — surfaced in
          alert messages so operator knows which version is running.
          Wire from <literal>self.rev or self.dirtyRev or "dirty"</literal>
          in the flake.
        '';
      };
      nixpkgsRevision = lib.mkOption {
        type = lib.types.str;
        default = "unknown";
        description = "Git revision of nixpkgs the system was built against.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # ── nix daemon settings ─────────────────────────────────────────
    nix = {
      settings = {
        experimental-features = [ "nix-command" "flakes" ];
        # Hardlink identical store paths — saves SD-card / SSD space
        # on disk-constrained physical servers.
        auto-optimise-store = true;

        # Keep build closures alive as long as the system generation
        # that built them is within gc retention. Without these, every
        # on-push rebuild would re-fetch toolchains the previous
        # rebuild evicted, defeating the iteration loop. Trade-off:
        # a slightly larger store; bounded by the gc settings below.
        keep-outputs = true;
        keep-derivations = true;
      };
      gc = {
        automatic = true;
        # Day after the auto-upgrade window so any breakage gets at
        # least one rollback generation kept.
        dates = "*-*-02 04:00";
        randomizedDelaySec = "6h";
        options = "--delete-older-than 30d";
        persistent = true;
      };
    };
    nixpkgs.config.allowUnfree = true;

    # ── auto-upgrade ────────────────────────────────────────────────
    system.autoUpgrade = lib.mkIf cfg.autoUpgrade.enable {
      enable = true;
      flake = cfg.autoUpgrade.flake;
      dates = "*-*-01 02:00";
      randomizedDelaySec = "6h";
      allowReboot = true;
      flags = [ "--refresh" ];
    };
    # Pull the latest of every flake input before each upgrade —
    # without this we'd rebuild against the locked nixpkgs forever.
    systemd.services.nixos-upgrade.preStart =
      lib.mkIf cfg.autoUpgrade.enable
        "nix flake update --flake /etc/nixos";

    # ── auto-rebuild-on-push ────────────────────────────────────────
    services.auto-rebuild-on-push.enable = cfg.autoRebuildOnPush.enable;

    # ── telegram-alerts ─────────────────────────────────────────────
    services.telegram-alerts = lib.mkIf cfg.alerts.enable {
      enable = true;
      tokenFile = cfg.alerts.tokenFile;
      alertsChatIdFile = cfg.alerts.alertsChatIdFile;
      logChatIdFile = cfg.alerts.logChatIdFile;
      configRevision = cfg.alerts.configRevision;
      nixpkgsRevision = cfg.alerts.nixpkgsRevision;
    };

    # ── sshd ────────────────────────────────────────────────────────
    services.openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "no";
        PasswordAuthentication = false;
      };
    };

    # ── sudo / root ─────────────────────────────────────────────────
    security.sudo.wheelNeedsPassword = false;
    users.users.root.hashedPassword = "!";  # disable root login entirely

    # ── memory ──────────────────────────────────────────────────────
    # zramSwap first (compressed RAM), disk-backed swap as the OOM
    # safety net. Suits the typical "homelab box with 1-4 GB RAM and
    # disk you don't want to wear out" shape.
    zramSwap = {
      enable = true;
      memoryPercent = 50;
      algorithm = "zstd";
    };
    swapDevices = [{
      device = "/var/swapfile";
      size = 2048;
    }];
    boot.kernel.sysctl."vm.swappiness" = 1;

    # ── disk-write minimisation ─────────────────────────────────────
    # /tmp on tmpfs — works on any non-pathological RAM budget; small
    # enough tmp jobs use real fs only when explicitly directed.
    boot.tmp.useTmpfs = true;
    fileSystems."/".options = lib.mkDefault [ "noatime" ];

    # ── tools every server should have ──────────────────────────────
    environment.systemPackages = with pkgs; [
      htop
      usbutils
    ];
  };
}
