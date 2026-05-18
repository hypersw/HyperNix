{ config, lib, pkgs, ... }:
let
  cfg = config.hypersw.services.auto-rebuild-on-push;

  # Unprivileged user for the checker. Named after what it *does* (poll
  # github for changes) rather than the wider system name, to make the
  # privilege boundary obvious: this user can't rebuild anything, can't
  # write /etc/nixos, can't touch the nix store beyond reading. All it
  # can do is drop a trigger file.
  checkerUser = "auto-rebuild-github-checker";

  # /run/auto-rebuild/ holds bookkeeping files owned by the checker
  # (lock file, cache etc). /run/auto-rebuild/triggers/ is the watched
  # inbox — the switcher's path unit fires on any file there, so we
  # MUST keep sibling files (check.lock, nix cache) out of it or the
  # path unit loops forever.
  runtimeDir = "/run/auto-rebuild";
  triggerDir = "${runtimeDir}/triggers";

  checkerScript = pkgs.writeShellScript "auto-rebuild-github-check" ''
    set -euo pipefail

    # Mutex via flock — if a previous check is still running (slow network,
    # stalled nix flake metadata) skip this tick cleanly rather than
    # queueing concurrent checks. Kernel releases the flock if the holder
    # dies unexpectedly — no stale-lock wedge on crash.
    # Lock sits in the parent runtime dir, not the watched trigger subdir
    # (which would make DirectoryNotEmpty always true).
    LOCK=${runtimeDir}/check.lock
    exec 9>>"$LOCK"
    if ! ${pkgs.util-linux}/bin/flock -n 9; then
      echo "previous check still active — skipping this tick"
      exit 0
    fi

    FLAKE_DIR="${cfg.flakeDir}"
    INPUT_NAME="${cfg.inputName}"
    LOCK="$FLAKE_DIR/flake.lock"

    # Read straight from flake.lock — don't invoke `nix flake metadata`.
    #
    # The natural-feeling choice (`nix flake metadata --json` then jq
    # `.locks.nodes.X`) has two failure modes that bit us in production:
    # if any flake input is declared in flake.nix but missing from
    # flake.lock, nix attempts to lock it on the fly (fetchTree +
    # lock-file write). The checker runs as an unprivileged user with
    # NO write perm on /etc/nixos/flake.lock, so the write step fails;
    # before that, the fetchTree can hit GitHub's anonymous rate limit
    # (≥30 s wall-clock then exit 1). Both surface as a generic
    # "metadata failed" and trip the OnFailure notifier. We don't
    # actually need any input to be fetched — we just want upstream's
    # already-recorded locked.rev to compare with the GitHub HEAD.
    # jq on flake.lock gives us exactly that, without nix in the loop:
    # no network call, no write attempt, no rate limit.
    #
    # We deliberately compare against the LOCKED rev (not the activated
    # rev) because it's self-limiting: on a broken upstream rev we
    # attempt one switch, nix flake update writes the new rev into the
    # lock, and the next tick sees "up to date" — no retry storm.

    if [ ! -f "$LOCK" ]; then
      # Fresh-deploy bootstrap: the activation script writes flake.nix
      # but the lock can be absent (no upstream pin at image-build time,
      # or operator wiped it for re-locking). Fire a trigger so the
      # switcher's `nix flake update upstream` creates the lock from
      # scratch. Soft-exit either way — this isn't a failure mode.
      echo "$LOCK missing — firing initial switch to bootstrap lock" >&2
      ${pkgs.coreutils}/bin/mktemp -p ${triggerDir} trigger.XXXXXX > /dev/null
      exit 0
    fi

    CURRENT_REV=$(${pkgs.jq}/bin/jq -r \
      ".nodes.\"$INPUT_NAME\".locked.rev // empty" "$LOCK" 2>/dev/null)

    if [ -z "$CURRENT_REV" ]; then
      echo "could not read .nodes.$INPUT_NAME.locked.rev from $LOCK" >&2
      exit 1
    fi

    # Extract upstream coordinates straight from the same lock. Handles
    # both the structured input form (type+owner+repo+ref) and the url
    # form (github:owner/repo/ref).
    ORIGINAL=$(${pkgs.jq}/bin/jq -c \
      ".nodes.\"$INPUT_NAME\".original" "$LOCK" 2>/dev/null)

    UPSTREAM_TYPE=$(echo "$ORIGINAL" | ${pkgs.jq}/bin/jq -r '.type // empty')
    if [ "$UPSTREAM_TYPE" = "github" ]; then
      OWNER=$(echo "$ORIGINAL" | ${pkgs.jq}/bin/jq -r '.owner // empty')
      REPO=$(echo "$ORIGINAL" | ${pkgs.jq}/bin/jq -r '.repo // empty')
      BRANCH=$(echo "$ORIGINAL" | ${pkgs.jq}/bin/jq -r '.ref // "master"')
      OWNER_REPO="$OWNER/$REPO"
    else
      UPSTREAM_URL=$(echo "$ORIGINAL" | ${pkgs.jq}/bin/jq -r '.url // empty')
      if [ -z "$UPSTREAM_URL" ]; then
        echo "unsupported upstream type '$UPSTREAM_TYPE' for input '$INPUT_NAME'" >&2
        exit 1
      fi
      GITHUB_PART=$(echo "$UPSTREAM_URL" | sed 's|^github:||')
      OWNER_REPO=$(echo "$GITHUB_PART" | cut -d/ -f1-2)
      BRANCH=$(echo "$GITHUB_PART" | cut -d/ -f3-)
      BRANCH="''${BRANCH:-master}"
    fi

    # Transient network issues are not a service failure — exit 0 so the
    # OnFailure notifier doesn't fire. The next timer tick retries.
    if ! LATEST_REV=$(${pkgs.git}/bin/git ls-remote "https://github.com/$OWNER_REPO" "refs/heads/$BRANCH" 2>/dev/null | ${pkgs.coreutils}/bin/cut -f1); then
      echo "git ls-remote failed (likely transient network issue) — will retry next tick" >&2
      exit 0
    fi

    if [ -z "$LATEST_REV" ]; then
      echo "empty ls-remote response — will retry next tick" >&2
      exit 0
    fi

    if [ "$CURRENT_REV" = "$LATEST_REV" ]; then
      echo "up to date ($CURRENT_REV)"
      exit 0
    fi

    echo "upstream changed $CURRENT_REV -> $LATEST_REV — queueing a switch"
    # mktemp a unique name per trigger. If the switcher is mid-run when
    # we fire, successive queue-drops create distinct files; the switcher
    # sweeps the dir in ExecStartPre so no trigger is ever "stuck".
    ${pkgs.coreutils}/bin/mktemp -p ${triggerDir} trigger.XXXXXX > /dev/null
  '';

  switchScript = pkgs.writeShellScript "auto-rebuild-switch" ''
    set -euo pipefail
    # Update the lock for the watched input, then activate. Both steps run
    # as root (nixos-rebuild switch requires it), but the service takes no
    # parameters — its entire behavior is determined by the flake.nix at
    # ${cfg.flakeDir}, which only root can modify. A compromised checker
    # cannot alter what this does beyond "run it now".
    ${pkgs.nix}/bin/nix flake update ${cfg.inputName} --flake ${cfg.flakeDir}
    ${config.system.build.nixos-rebuild}/bin/nixos-rebuild switch --flake ${cfg.flakeDir}#${cfg.configName}
  '';
in
{
  options.hypersw.services.auto-rebuild-on-push = {
    enable = lib.mkEnableOption "Poll upstream flake for changes and rebuild when new commits are pushed";

    interval = lib.mkOption {
      type = lib.types.str;
      default = "5min";
      description = "How often to check for upstream changes";
    };

    flakeDir = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nixos";
      description = "Path to the local flake directory";
    };

    configName = lib.mkOption {
      type = lib.types.str;
      default = "default";
      description = "NixOS configuration name to build (the #name in --flake)";
    };

    inputName = lib.mkOption {
      type = lib.types.str;
      default = "upstream";
      description = "Name of the flake input to watch for changes";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${checkerUser} = {
      isSystemUser = true;
      group = checkerUser;
      description = "Unprivileged user that polls github for upstream changes";
    };
    users.groups.${checkerUser} = {};

    # Pre-create both dirs at activation time (via systemd-tmpfiles) so the
    # path unit has something to watch at boot, before the checker has ever
    # run. RuntimeDirectory= on the checker would also create them but only
    # when the checker runs first — risk of a race where the path unit's
    # inotify fails on a missing dir.
    systemd.tmpfiles.rules = [
      "d ${runtimeDir}          0700 ${checkerUser} ${checkerUser} -"
      "d ${triggerDir}          0700 ${checkerUser} ${checkerUser} -"
    ];

    # Timer drives the *checker*. The switcher is path-activated — it
    # fires when (and only when) the checker has decided to trigger a
    # switch. No direct timer → switcher coupling.
    #
    # Cadence note: `OnUnitInactiveSec` rather than `OnUnitActiveSec`.
    # The difference matters on the unhappy path — if a tick takes a
    # long time (slow Pi unpacking nix flake metadata's transitive
    # fetches, a 76 s GitHub-rate-limit retry-after wait, …), Active
    # would back-to-back-fire the next tick the moment the slow one
    # finishes (a "missed" fire that's now overdue). Inactive waits
    # for the full interval *after* the previous attempt completes —
    # what we actually want for a poller against a rate-limited
    # external endpoint. No bursts, no thundering on recovery.
    systemd.timers.auto-rebuild-github-checker = {
      description = "Poll upstream flake for changes";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitInactiveSec = cfg.interval;
        RandomizedDelaySec = "30s";
      };
    };

    # ── Checker: unprivileged, hardened, internet-facing ────────────
    systemd.services.auto-rebuild-github-checker = {
      description = "Check upstream flake for changes; queue a switch if any";
      # Wait for the network stack AND DNS resolution to be ready before we
      # attempt `git ls-remote` to github. Without this we race early-boot
      # ticks before systemd-resolved is up and get "Name or service not
      # known" — the script soft-exits on that, but the first tick is
      # wasted and shows up as transient failures in the journal.
      after = [ "network-online.target" "nss-lookup.target" ];
      wants = [ "network-online.target" "nss-lookup.target" ];
      # HOME defaults to /var/empty for isSystemUser (which is 0555 immutable),
      # but `nix flake metadata` wants to mkdir $HOME/.cache/nix for its eval
      # cache. Point HOME at the writable runtime directory instead. Cleared
      # on reboot (tmpfs); acceptable for a 5-min-interval checker.
      environment.HOME = "%t/auto-rebuild";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = checkerScript;

        # First-ever tick on a fresh /etc/nixos has to do real work:
        # nix lazily fetches every transitive input and unpacks it on
        # a Pi-class CPU. If the unit times out mid-fetch, the next
        # tick starts the same burst over against a still-cooling
        # GitHub rate-limit window — escalating, not converging.
        # 15 min is generous enough to absorb nix's 76 s
        # retry-after sleeps + slow tarball unpacks on SD/WiFi,
        # without being so long that a genuinely-stuck tick blocks
        # the next attempt for half an hour.
        TimeoutStartSec = "15min";

        User = checkerUser;
        Group = checkerUser;

        # Owns /run/auto-rebuild/ (parent — holds lock + $HOME cache) and
        # /run/auto-rebuild/triggers/ (watched inbox — only trigger files
        # go here so DirectoryNotEmpty= doesn't trip on sibling bookkeeping).
        # Switcher is root so it can sweep regardless of ownership.
        # Preserve=yes so pending trigger files survive the checker's
        # oneshot exit — otherwise systemd would GC the dir immediately
        # after ExecStart returns, and the path unit would never see it.
        RuntimeDirectory = [ "auto-rebuild" "auto-rebuild/triggers" ];
        RuntimeDirectoryMode = "0700";
        RuntimeDirectoryPreserve = "yes";

        WorkingDirectory = "/var/empty";

        # Full hardening bundle. First-hop exposed — talks HTTPS to
        # github and consumes whatever it returns via git/jq/nix.
        #
        # Skipped: MemoryDenyWriteExecute (JIT is a legitimate technique
        # used by real tools like PCRE2, ripgrep with -P, etc.; the cost
        # of a future tool breaking silently outweighs the marginal
        # defensive value here).
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        LockPersonality = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        RestrictNamespaces = true;
        # AF_INET/INET6 for HTTPS to github; AF_UNIX for nix daemon RPC.
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      };
      # Transient network failures soft-exit 0 (don't fire this). Hard
      # failures — parse errors, malformed flake.lock, unsupported
      # upstream type — are bugs worth alerting on. Service defined in
      # Modules/Monitoring/TelegramAlerts/default.nix.
      unitConfig.OnFailure = "auto-rebuild-checker-failure-notify.service";
      path = [ pkgs.git ];
    };

    # ── Switch trigger: path-activated ──────────────────────────────
    # The path unit watches the trigger dir for non-emptiness. When the
    # checker drops a file, it fires auto-rebuild-switch.service. Unlike
    # PathModified= (edge-triggered), DirectoryNotEmpty= is level-triggered:
    # the unit's behavior is a function of current state, not individual
    # events — so a missed inotify event doesn't drop a signal.
    systemd.paths.auto-rebuild-switch = {
      description = "Fire auto-rebuild-switch when a trigger file lands";
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        DirectoryNotEmpty = triggerDir;
      };
    };

    # ── Switcher: root, minimal, zero-input ─────────────────────────
    # This is the only privileged component. It has no configuration
    # surface exposed to the checker — no arguments, no env vars, no
    # stdin. Its behavior is entirely determined by the flake at
    # ${cfg.flakeDir}, which only root can modify. A compromised checker
    # gets "trigger a rebuild now" (DoS) and nothing more.
    systemd.services.auto-rebuild-switch = {
      description = "Update flake lock and activate new NixOS configuration";
      # Don't let nixos-rebuild restart this service mid-self-switch.
      # The unit file for auto-rebuild-switch.service ~always changes
      # whenever we update anything in this module; with the default
      # restartIfChanged=true, switch-to-configuration stops the
      # currently-running switcher as part of activation — which
      # SIGTERMs the nixos-rebuild child mid-flight. Setting this to
      # false means: the running switcher finishes with the OLD unit
      # definition intact; the NEW definition only takes effect on the
      # NEXT path-triggered switch. Exactly what we want for oneshot.
      restartIfChanged = false;
      serviceConfig = {
        Type = "oneshot";
        WorkingDirectory = "/var/empty";

        # Sweep triggers BEFORE attempting the switch. If the switch
        # fails at any point, the dir is already empty — the path unit
        # won't re-fire in a loop. Next attempt is whenever the checker
        # next sees a rev difference (minutes later, via its timer).
        ExecStartPre = "${pkgs.findutils}/bin/find ${triggerDir} -maxdepth 1 -name 'trigger.*' -delete";
        ExecStart = switchScript;

        # Restart=no is the oneshot default; keep it. A failed switch
        # should freeze visibly in `systemctl --failed` and alert via
        # OnFailure below, not thrash.
      };
      # Defense-in-depth against runaway path-activation loops. If some
      # future bug makes a trigger file reappear on its own, cap the
      # switcher at 3 starts per 5 minutes; after that, systemd refuses
      # further starts until the sliding window clears — no ExecStart
      # runs, no CPU/SD burn, just a "Start request repeated too
      # quickly" journal line every tick. Refused starts don't fire
      # OnFailure= so we don't flood the alert queue either.
      unitConfig = {
        OnFailure = "auto-rebuild-switch-failure-notify.service";
        StartLimitIntervalSec = "5min";
        StartLimitBurst = 3;
      };
    };
  };
}
