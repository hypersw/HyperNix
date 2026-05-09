{ config, lib, pkgs, ... }:
#
# PhysicalServerBase profile — the "things every machine I run wants"
# baseline. Imports the cross-cutting infra modules (auto-rebuild,
# telegram alerts) plus a sane SSH/sudo/swap/nix-gc bundle, plus the
# administrator user and the local-flake activation scaffolding.
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

  # systemd OnCalendar strings for the auto-upgrade cadence enum.
  # Wrapping the enum keeps human-readable from the option side; the
  # full freedom of crontab expressions isn't needed for "should we
  # rebuild today / this week / this month".
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

  options.profiles.physicalServerBase = {
    enable = lib.mkEnableOption "Cross-cutting base profile for any physical server";

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
          systemd timer expression — no crontab flexibility on
          purpose; the enum keeps machine configs human-readable
          and we don't need finer scheduling.
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
          Typically <literal>config.sops.secrets.NAME.path</literal>;
          the path-not-secret-handle convention keeps the meta-
          module decoupled from the secret-delivery story (sops,
          agenix, raw file).
        '';
      };
      alertsChatIdFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          Path to a file containing the Telegram chat id for alerts.
          Always-channel in our deployment; the consumer accepts both
          bare-positive ids (the form Telegram clients show under
          channel properties) and the canonical
          <literal>-100…</literal> form, prepending the prefix when
          missing. So you can copy whichever Telegram surfaces and
          drop it into the secret unchanged.
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
          Git revision of the upstream config (HyperNix) — surfaced
          in alert messages so the operator knows which version is
          running. Wire from <literal>self.rev or self.dirtyRev</literal>
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
          <literal>users.users.''${config.profiles.physicalServerBase.administrator.name}.extraGroups
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
          can append (e.g. the print-scan profile adds "scanner"
          and "lp") via the standard NixOS list-merge semantics.
        '';
      };
    };

    redistributableFirmware = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Install non-free firmware blobs from
        <literal>linux-firmware</literal>. Default true because most
        physical servers we run want WiFi / BT firmware (Pi 4/5,
        x86 laptops with Intel/Atheros radios). Disable for
        FOSS-only hosts that explicitly don't want the blobs.
      '';
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
          script writes
          <literal>nixosConfigurations.default = upstream.nixosConfigurations.''${this};</literal>
          to the local flake.
        '';
      };
      upstreamUrl = lib.mkOption {
        type = lib.types.str;
        default = "github:hypersw/HyperNix";
        description = "Flake URL to use as the local flake's upstream input.";
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
      flake = "/etc/nixos#default";
      dates = autoUpgradeDates;
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

    # ── administrator user ──────────────────────────────────────────
    # Created in the base so every physical server has one
    # consistently-named human account; per-machine config supplies
    # the keys (humans + devices vary). Other modules append groups
    # via standard NixOS list-merge:
    #   users.users.${cfg.administrator.name}.extraGroups = [...];
    users.users.${cfg.administrator.name} = {
      isNormalUser = true;
      extraGroups = cfg.administrator.extraGroups;
      openssh.authorizedKeys.keys = cfg.administrator.authorizedKeys;
    };

    # ── firmware ────────────────────────────────────────────────────
    hardware.enableRedistributableFirmware = cfg.redistributableFirmware;

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

    # ── local-flake bootstrap ───────────────────────────────────────
    # Generate /etc/nixos/flake.nix on first boot. The local flake
    # owns the lock file and controls nixpkgs version. Subsequent
    # edits stay in place because the if-not-file guard skips the
    # rewrite — operators can hand-edit the file any time and the
    # next activation won't clobber.
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
  };
}
