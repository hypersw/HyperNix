{ config, lib, pkgs, ... }:
#
# AnyMachineBase profile — the "things any NixOS host I run wants"
# baseline. Hardware-agnostic, applies to Pi 4 / Pi 5 / x86_64 lab
# boxes / VMs / nspawn containers alike — anything that's a managed
# host under operator-driven configuration.
#
# Excluded: Modules/MicroVM/VmSshFront and friends — microVMs have
# very different lifecycle (ephemeral, no auto-upgrade, no
# ssh-administrator-with-keys, nothing of the sort) and explicitly
# don't import this profile.
#
# Container vs non-container split. A subset of the bundle below
# requires a kernel of its own (zram, swapfile, vm.swappiness, /tmp
# on tmpfs, redistributable firmware blobs, noatime on /). Inside a
# nixos-container / systemd-nspawn host the kernel belongs to the
# outer host — `config.boot.isContainer` is true and those options
# are either inert or actively wrong. We gate that subset on
# `!boot.isContainer` so the same profile imports cleanly into
# container configs without errors. Everything else (nix daemon,
# auto-upgrade, sshd, sudo, the administrator user, telegram-alerts,
# the local-flake bootstrap) applies uniformly.
#
let
  cfg = config.hypersw.profiles.anyMachineBase;

  autoUpgradeDates = {
    daily   = "*-*-* 02:00";
    weekly  = "Sun *-*-* 02:00";
    monthly = "*-*-01 02:00";
  }.${cfg.autoUpgrade.cadence};
in
{
  imports = [
    ../../System/AutoRebuildOnPush
    ../../Monitoring/TelegramAlerts
  ];

  options.hypersw.profiles.anyMachineBase = {
    enable = lib.mkEnableOption "Cross-cutting base profile for any NixOS host";

    redistributableFirmware = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Install non-free firmware blobs from
        <literal>linux-firmware</literal>. Default true because most
        hosts we run want WiFi / BT / GPU microcode (Pi 4/5, x86 lab
        boxes with Intel/Atheros radios, VM hosts that pass through
        peripherals). No runtime side effects beyond more firmware
        files on disk that the kernel loads only when a driver
        requests them; closure cost is offset by the fact most of
        these hosts genuinely need a subset of these blobs anyway.
        Auto-skipped on containers (no kernel of their own).
      '';
    };

    autoUpgrade = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run nixos-rebuild on a recurring cadence to pick up nixpkgs+upstream changes.";
      };
      cadence = lib.mkOption {
        type = lib.types.enum [ "daily" "weekly" "monthly" ];
        default = "monthly";
        description = ''
          How often to attempt an upgrade. Mapped to a fixed
          systemd timer expression — keeps the option surface
          human-readable; no crontab flexibility on purpose.
        '';
      };
    };

    autoRebuildOnPush = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Poll upstream HyperNix for changes every few minutes,
          rebuild when something lands. Cheap config-iteration
          loop while the machine is being shaped; can be disabled
          on machines whose config has stabilised.
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
          Typically <literal>config.sops.secrets.NAME.path</literal>;
          the path-not-secret-handle convention keeps the meta-
          module decoupled from the secret-delivery story.
        '';
      };
      alertsChatIdFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          Path to a file containing the Telegram chat id for alerts.
          Always-channel in our deployment; the consumer accepts
          both bare-positive ids (the form Telegram clients show
          under channel properties) and the canonical
          <literal>-100…</literal> form, prepending the prefix
          when missing.
        '';
      };
      logChatIdFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          Path to a file containing the Telegram chat id for log
          forwards. Same accepted-forms rules as
          <literal>alertsChatIdFile</literal>.
        '';
      };
      configRevision = lib.mkOption {
        type = lib.types.str;
        default = "unknown";
        description = ''
          Git revision of the upstream config — surfaced in alert
          messages. Wire from <literal>self.rev or self.dirtyRev</literal>
          in the flake.
        '';
      };
      nixpkgsRevision = lib.mkOption {
        type = lib.types.str;
        default = "unknown";
        description = "Git revision of nixpkgs the system was built against.";
      };
    };

    administrator = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "administrator";
        description = ''
          Login name of the box's main human-administrator account.
          Exposed as an option (rather than hard-coded) so other
          modules can pin extra-groups onto the same user without
          having to know the name —
          <literal>users.users.''${config.hypersw.profiles.anyMachineBase.administrator.name}.extraGroups
          = [ "scanner" "lp" ];</literal> from the print-scan profile,
          for instance.
        '';
      };
      authorizedKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = ''
          OpenSSH-format public keys allowed to log in as the
          administrator. Per-machine, since the human + their
          devices vary across hosts.
        '';
      };
      extraGroups = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "wheel" ];
        description = ''
          Default groups for the administrator user. Other modules
          append (e.g. the print-scan profile adds "scanner" and
          "lp") via the standard NixOS list-merge semantics.
        '';
      };
    };

    localFlake = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Generate /etc/nixos/flake.nix at first boot so
          nixos-rebuild can run from a local lock file pointing at
          the upstream HyperNix flake. Subsequent edits to the
          local flake stay in place; the activation script only
          writes if the file doesn't already exist.
        '';
      };
      configurationName = lib.mkOption {
        type = lib.types.str;
        description = ''
          Name of the upstream nixosConfiguration to default to
          (e.g. "PrintScanServerPi4", "GhostHome"). The activation
          script writes <literal>nixosConfigurations.default =
          upstream.nixosConfigurations.''${this};</literal> to the
          local flake.
        '';
      };
      upstreamUrl = lib.mkOption {
        type = lib.types.str;
        default = "github:hypersw/HyperNix";
        description = "Flake URL to use as the local flake's upstream input.";
      };
    };
  };

  config = lib.mkMerge [
    # ── Always-applies (containers + everything else) ────────────────
    (lib.mkIf cfg.enable {
      # ── nix daemon settings ───────────────────────────────────────
      nix = {
        settings = {
          experimental-features = [ "nix-command" "flakes" ];
          # Hardlink identical store paths — saves SD-card / SSD
          # space on disk-constrained hosts.
          auto-optimise-store = true;
          # Keep build closures alive as long as the system
          # generation that built them is within gc retention.
          keep-outputs = true;
          keep-derivations = true;
        };
        gc = {
          automatic = true;
          # Day after the auto-upgrade window so any breakage gets
          # at least one rollback generation kept.
          dates = "*-*-02 04:00";
          randomizedDelaySec = "6h";
          options = "--delete-older-than 30d";
          persistent = true;
        };
      };
      nixpkgs.config.allowUnfree = true;

      # ── auto-upgrade ──────────────────────────────────────────────
      system.autoUpgrade = lib.mkIf cfg.autoUpgrade.enable {
        enable = true;
        flake = "/etc/nixos#default";
        dates = autoUpgradeDates;
        randomizedDelaySec = "6h";
        allowReboot = true;
        flags = [ "--refresh" ];
      };
      systemd.services.nixos-upgrade.preStart =
        lib.mkIf cfg.autoUpgrade.enable
          "nix flake update --flake /etc/nixos";

      # ── auto-rebuild-on-push ──────────────────────────────────────
      hypersw.services.auto-rebuild-on-push.enable = cfg.autoRebuildOnPush.enable;

      # ── telegram-alerts ───────────────────────────────────────────
      hypersw.services.telegram-alerts = lib.mkIf cfg.alerts.enable {
        enable = true;
        tokenFile = cfg.alerts.tokenFile;
        alertsChatIdFile = cfg.alerts.alertsChatIdFile;
        logChatIdFile = cfg.alerts.logChatIdFile;
        configRevision = cfg.alerts.configRevision;
        nixpkgsRevision = cfg.alerts.nixpkgsRevision;
      };

      # ── sshd ──────────────────────────────────────────────────────
      services.openssh = {
        enable = true;
        settings = {
          PermitRootLogin = "no";
          PasswordAuthentication = false;
        };
      };

      # ── sudo / root ───────────────────────────────────────────────
      security.sudo.wheelNeedsPassword = false;
      users.users.root.hashedPassword = "!";  # disable root login entirely

      # ── administrator user ────────────────────────────────────────
      users.users.${cfg.administrator.name} = {
        isNormalUser = true;
        extraGroups = cfg.administrator.extraGroups;
        openssh.authorizedKeys.keys = cfg.administrator.authorizedKeys;
      };

      # ── tools every host should have ──────────────────────────────
      environment.systemPackages = with pkgs; [
        htop
      ];

      # ── local-flake bootstrap ─────────────────────────────────────
      system.activationScripts.localFlake = lib.mkIf cfg.localFlake.enable ''
        if [ ! -f /etc/nixos/flake.nix ]; then
          mkdir -p /etc/nixos
          cat > /etc/nixos/flake.nix << 'FLAKE'
        # GENERATED by NixOS activation script — to customize, delete
        # this file and create your own.
        {
          inputs = {
            nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
            nixos-hardware.url = "github:NixOS/nixos-hardware";
            upstream = {
              url = "${cfg.localFlake.upstreamUrl}";
              inputs.nixpkgs.follows = "nixpkgs";
              inputs.nixos-hardware.follows = "nixos-hardware";
            };
          };

          outputs = { upstream, ... }: {
            nixosConfigurations.default =
              upstream.nixosConfigurations.${cfg.localFlake.configurationName};
          };
        }
        FLAKE
        fi
      '';
    })

    # ── Non-container only (need own kernel + own rootfs) ────────────
    # Inside an nspawn container the kernel + swap come from the host;
    # `boot.isContainer = true` makes these options either inert
    # (silently dropped by the option system) or actively wrong, so we
    # gate the whole block out cleanly. Same gate works for VMs and
    # bare metal alike (`isContainer = false`), which is the broad
    # majority of cases.
    (lib.mkIf (cfg.enable && !config.boot.isContainer) {
      hardware.enableRedistributableFirmware = cfg.redistributableFirmware;

      # zramSwap first (compressed RAM), disk-backed swap as the OOM
      # safety net. Suits the typical "homelab box with 1-4 GB RAM
      # and disk you don't want to wear out" shape.
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

      # /tmp on tmpfs — works on any non-pathological RAM budget;
      # small enough tmp jobs use real fs only when explicitly
      # directed.
      boot.tmp.useTmpfs = true;
      fileSystems."/".options = lib.mkDefault [ "noatime" ];
    })
  ];
}
