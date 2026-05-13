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
  # No `imports` here — `Modules/default.nix` (the module-list)
  # loads AutoRebuildOnPush and TelegramAlerts centrally, so this
  # profile can reference their options without pulling them in
  # again (which would create a duplicate route through the
  # import graph). See `Modules/default.nix` for the rationale.

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
      upstreamPin = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            rev = lib.mkOption { type = lib.types.str; };
            narHash = lib.mkOption { type = lib.types.str; };
            lastModified = lib.mkOption { type = lib.types.int; };
          };
        });
        default = null;
        description = ''
          When non-null, the activation script writes
          <literal>/etc/nixos/flake.lock</literal> alongside the
          generated <literal>flake.nix</literal>, pinning the
          <literal>upstream</literal> input to this rev/narHash/
          lastModified. Avoids the first-boot chicken-and-egg where
          the first auto-rebuild-checker tick has to fetch all
          transitive inputs from GitHub and trips its secondary
          rate limit before any subsequent tick can win.

          Set this from <literal>self</literal> in the flake's
          outputs — typically
          <literal>{ rev = self.rev; narHash = self.narHash;
          lastModified = self.lastModified; }</literal>, conditional
          on <literal>self ? rev</literal> so dirty trees fall back
          to lazy resolution.
        '';
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

      # ── DNS: systemd-resolved with DoT + DNSSEC ─────────────────
      # Override the ISP's DHCP-supplied DNS with known-good
      # privacy-respecting resolvers. ISP DNS is opaque (no
      # logging policy commitment, often logs + sells, no DNSSEC
      # validation, no DoT support), so we always route through
      # Quad9 → Cloudflare instead.
      #
      # * `settings.Resolve.DNS` (primary): Quad9, security-
      #   focused — DNSSEC-validating, blocks known-malware
      #   domains via PCH/threat intel. Both v4 and v6, with
      #   the SNI hint after `#` for DoT certificate
      #   validation. Quad9's primary anycast endpoint plus
      #   the secondary for resilience.
      # * `fallbackDns` (used when primary fails to respond):
      #   Cloudflare 1.1.1.1 — fastest commercial resolver,
      #   DoT-capable, DNSSEC-validating. Same v4+v6 pair
      #   with SNI.
      # * `domains = [ "~." ]`: wildcard match — route ALL
      #   queries to the global DNS above, overriding any
      #   per-link DHCP-supplied DNS. Without this, dhcpcd /
      #   networkd would install the ISP's DNS as the link's
      #   resolver and resolved would prefer it over our global.
      # * `dnsovertls = "true"`: REQUIRE DoT. If TLS to the
      #   upstream fails for any reason, queries fail (rather
      #   than silently downgrading to plain UDP/53 which the
      #   ISP can read + manipulate). `opportunistic` would
      #   downgrade silently, `false` would never use DoT.
      # * `dnssec = "allow-downgrade"`: validate DNSSEC when
      #   the zone is signed; allow unsigned zones through
      #   (most of the long tail of the web isn't DNSSEC-
      #   signed yet, "true" would break those).
      #
      # mDNS (`*.local`) handling lives in MultiHomedNetworking
      # which flips `MulticastDNS = "no"` so Avahi can own it
      # without fighting resolved.
      services.resolved = {
        enable = true;
        settings.Resolve = {
          DNS =
            "9.9.9.9#dns.quad9.net "
            + "149.112.112.112#dns.quad9.net "
            + "2620:fe::fe#dns.quad9.net "
            + "2620:fe::9#dns.quad9.net";
          FallbackDNS =
            "1.1.1.1#cloudflare-dns.com "
            + "1.0.0.1#cloudflare-dns.com "
            + "2606:4700:4700::1111#cloudflare-dns.com "
            + "2606:4700:4700::1001#cloudflare-dns.com";
          Domains = "~.";
          DNSOverTLS = "true";
          DNSSEC = "allow-downgrade";
        };
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
      # Two files written as a pair iff neither exists yet:
      #
      #   - /etc/nixos/flake.nix  — a one-input shim re-exporting
      #     upstream.nixosConfigurations.<name>. No nixpkgs /
      #     nixos-hardware declared at the shim level: they're not
      #     used by anyone (the shim's outputs only touch upstream),
      #     and dropping them shrinks /etc/nixos/flake.lock to two
      #     nodes (root + upstream) instead of the full transitive
      #     closure. Upstream resolves its own inputs from ITS own
      #     flake.lock, which is in the store at evaluation time.
      #
      #   - /etc/nixos/flake.lock — pinned upstream entry from
      #     `localFlake.upstreamPin` (which the flake's outputs
      #     wires from `self`). Skips the chicken-and-egg of "first
      #     auto-rebuild tick has to lock from cold and trips
      #     GitHub's secondary rate limit". Subsequent ticks just
      #     read this file + `git ls-remote` upstream master — no
      #     archive fetches, no api.github.com calls.
      #
      # If the lock pin is null (dirty tree, build without rev),
      # only flake.nix is written; the first checker tick will
      # generate the lock the slow way.
      system.activationScripts.localFlake = lib.mkIf cfg.localFlake.enable (
        let
          pin = cfg.localFlake.upstreamPin;
          # Parse the upstream URL into owner/repo for the lock's
          # `original` block. We only support the github:owner/repo
          # form here; anything else and we'd need a parser, which
          # isn't worth it for a default we own.
          urlNoScheme = lib.removePrefix "github:" cfg.localFlake.upstreamUrl;
          urlParts = lib.splitString "/" urlNoScheme;
          upstreamOwner = lib.head urlParts;
          upstreamRepo  = lib.elemAt urlParts 1;
        in ''
          if [ ! -f /etc/nixos/flake.nix ] && [ ! -f /etc/nixos/flake.lock ]; then
            mkdir -p /etc/nixos
            cat > /etc/nixos/flake.nix << 'FLAKE'
          # GENERATED by NixOS activation script — to customize, delete
          # this file and create your own.
          {
            inputs.upstream.url = "${cfg.localFlake.upstreamUrl}";
            outputs = { upstream, ... }: {
              nixosConfigurations.default =
                upstream.nixosConfigurations.${cfg.localFlake.configurationName};
            };
          }
          FLAKE
        '' + lib.optionalString (pin != null) ''
            cat > /etc/nixos/flake.lock << 'LOCK'
          {
            "version": 7,
            "root": "root",
            "nodes": {
              "root": { "inputs": { "upstream": "upstream" } },
              "upstream": {
                "locked": {
                  "type": "github",
                  "owner": "${upstreamOwner}",
                  "repo": "${upstreamRepo}",
                  "rev": "${pin.rev}",
                  "narHash": "${pin.narHash}",
                  "lastModified": ${toString pin.lastModified}
                },
                "original": {
                  "type": "github",
                  "owner": "${upstreamOwner}",
                  "repo": "${upstreamRepo}"
                }
              }
            }
          }
          LOCK
        '' + ''
          fi
        ''
      );
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
