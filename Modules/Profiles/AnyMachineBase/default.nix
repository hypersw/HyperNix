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
    # Tuesday, in homage to Microsoft's Patch Tuesday — the de
    # facto industry-wide "expect updates this day" slot, picked
    # by MS deliberately to give admins a known weekday window
    # for vendor rollouts. Same idea on this side: predictable
    # mid-week tick that's neither a weekend (operator away,
    # nobody watching the alerts channel) nor a Monday (week's
    # already loaded). 04:00 base + the existing 6h randomized
    # delay puts the actual window at Tue 04:00-10:00 local.
    weekly  = "Tue *-*-* 04:00";
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
          Generate /etc/nixos/flake.nix from this profile's template
          on every activation so nixos-rebuild can run from a local
          lock file pointing at the upstream HyperNix flake.
          Desired-state: the file's content is module-owned —
          operator edits go through the template, NOT through
          /etc/nixos/flake.nix directly. flake.lock is operator /
          nix-tooling state and is left alone after the initial
          bake.
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
            rev          = lib.mkOption { type = lib.types.str;  };
            narHash      = lib.mkOption { type = lib.types.str;  };
            lastModified = lib.mkOption { type = lib.types.int;  };
            sourcePath   = lib.mkOption { type = lib.types.path; };
          };
        });
        default = null;
        description = ''
          When non-null, the activation script writes
          <literal>/etc/nixos/flake.lock</literal> alongside the
          generated <literal>flake.nix</literal>. The lock is
          derived from <literal>sourcePath/flake.lock</literal>
          (the upstream HyperNix flake's own lock, in-store) by a
          jq transform that:
            1. Renames upstream's "root" node → "upstream" and
               attaches the pin (rev / narHash / lastModified) as
               its <literal>locked</literal> entry.
            2. Overrides upstream's <literal>nixpkgs</literal> and
               <literal>nixos-hardware</literal> inputs to be
               follows-pointers to the shim root — matching the
               <literal>upstream.inputs.X.follows = "X"</literal>
               directives in the shim's flake.nix.
            3. Adds a new "root" node with three direct inputs:
               <literal>nixpkgs</literal>,
               <literal>nixos-hardware</literal>,
               <literal>upstream</literal>.
            4. Prepends <literal>"upstream"</literal> to every
               follows-path in non-root nodes (their targets used
               to be root-relative in upstream's lock, now they're
               reachable via <literal>upstream</literal> from the
               shim root).

          Wire from <literal>self</literal> in the flake's
          outputs:
          <literal>{ rev = self.rev; narHash = self.narHash;
          lastModified = self.lastModified; sourcePath = self; }</literal>,
          conditional on <literal>self ? rev</literal> so dirty
          trees fall back to lazy resolution (no pre-baked lock,
          the first auto-rebuild tick generates one from cold).

          Without this baking, the first checker tick has to do
          full transitive flake-locking from GitHub anonymously,
          which trips the secondary rate limit before any tick
          can win and persist a lock to disk. See the long
          header comment of
          <literal>Modules/System/LocalFlakeShim</literal>
          for why the shim has the multi-input shape
          rather than a single-input one.
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
        # Deprioritise nix-daemon (and the build workers it spawns)
        # to the kernel's lowest scheduling class on both CPU and
        # IO. SCHED_IDLE / ionice idle means "run only when nothing
        # else wants the CPU / disk" — so a months-spanning kernel
        # rebuild on a Pi 5 (where nixpkgs' linuxPackages_rpi5
        # cache-misses against our nixos-unstable pin and we pay a
        # ~3h source build each monthly auto-upgrade) yields
        # immediately to telegram-bot, scanner driver, Home
        # Assistant, etc.  Build wall-time goes up under contention
        # (an idle box still gets full CPU/IO), but the box stays
        # responsive throughout the build window.
        daemonCPUSchedPolicy = "idle";
        daemonIOSchedClass   = "idle";
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
          # Advance every declared input (production trio + any
          # candidate trio that happens to be present). The candidate
          # trio's purpose is short-lived major-upgrade probing;
          # operator is expected to promote-or-discard within the
          # monthly cadence. If they don't, the next monthly tick
          # rolls the candidate forward — same effect as starting a
          # fresh probe at that point.
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
      # The shim and its baked lock live in Modules/System/LocalFlakeShim;
      # this profile keeps its `localFlake` options and renders the full
      # Pi-capable shape with the candidate quartet.
      hypersw.system.localFlakeShim = lib.mkIf cfg.localFlake.enable {
        enable = true;
        inherit (cfg.localFlake) configurationName upstreamUrl upstreamPin;
      };
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
