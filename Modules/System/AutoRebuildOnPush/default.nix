{ config, lib, pkgs, ... }:
let
  cfg = config.services.auto-rebuild-on-push;

  # Unprivileged user for the checker. Named after what it *does* (poll
  # github for changes) rather than the wider system name, to make the
  # privilege boundary obvious: this user can't rebuild anything, can't
  # write /etc/nixos, can't touch the nix store beyond reading. All it
  # can do is drop a trigger file.
  checkerUser = "auto-rebuild-github-checker";

  # /run/auto-rebuild/ is owned by the checker (via RuntimeDirectory=)
  # and watched by the switcher's path unit (DirectoryNotEmpty=). The
  # checker mktemp's a unique filename per trigger; the switcher sweeps
  # the dir in ExecStartPre and then runs. If the switcher fails after
  # the sweep, the dir is already empty, so no path-unit re-fire storm.
  triggerDir = "/run/auto-rebuild";

  checkerScript = pkgs.writeShellScript "auto-rebuild-github-check" ''
    set -euo pipefail

    # Mutex via flock — if a previous check is still running (slow network,
    # stalled nix flake metadata) skip this tick cleanly rather than
    # queueing concurrent checks. Kernel releases the flock if the holder
    # dies unexpectedly — no stale-lock wedge on crash.
    LOCK=/run/auto-rebuild-github-checker.lock
    exec 9>>"$LOCK"
    if ! ${pkgs.util-linux}/bin/flock -n 9; then
      echo "previous check still active — skipping this tick"
      exit 0
    fi

    FLAKE_DIR="${cfg.flakeDir}"
    INPUT_NAME="${cfg.inputName}"

    # Locked rev in the flake we'd activate. We deliberately compare this
    # to upstream (not the activated rev) because it's self-limiting: on a
    # broken upstream rev, we attempt one switch, nix flake update writes
    # the new rev into the lock, and the next tick sees "up to date" —
    # no retry storm, no wasted CPU / SD on a doomed build.
    CURRENT_REV=$(${pkgs.nix}/bin/nix flake metadata "$FLAKE_DIR" --json 2>/dev/null \
      | ${pkgs.jq}/bin/jq -r ".locks.nodes.\"$INPUT_NAME\".locked.rev // empty")

    if [ -z "$CURRENT_REV" ]; then
      echo "could not read current locked rev for input '$INPUT_NAME'" >&2
      exit 1
    fi

    # Extract upstream coordinates from the flake metadata. Handles both
    # the structured input form (type+owner+repo+ref) and the url form
    # (github:owner/repo/ref).
    ORIGINAL=$(${pkgs.nix}/bin/nix flake metadata "$FLAKE_DIR" --json 2>/dev/null \
      | ${pkgs.jq}/bin/jq -c ".locks.nodes.\"$INPUT_NAME\".original")

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
  options.services.auto-rebuild-on-push = {
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

    # Timer drives the *checker*. The switcher is path-activated — it
    # fires when (and only when) the checker has decided to trigger a
    # switch. No direct timer → switcher coupling.
    systemd.timers.auto-rebuild-github-checker = {
      description = "Poll upstream flake for changes";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = cfg.interval;
        RandomizedDelaySec = "30s";
      };
    };

    # ── Checker: unprivileged, hardened, internet-facing ────────────
    systemd.services.auto-rebuild-github-checker = {
      description = "Check upstream flake for changes; queue a switch if any";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = checkerScript;

        User = checkerUser;
        Group = checkerUser;

        # Owns /run/auto-rebuild/ where trigger files land. Switcher is
        # root so it can sweep regardless of ownership. RuntimeDirectory
        # auto-creates the dir before we exec. Preserve=yes so the dir
        # (and any pending trigger files we drop in it) survives the
        # checker's oneshot exit — otherwise systemd would GC the dir
        # immediately after ExecStart returns, and the path unit would
        # never see the trigger.
        RuntimeDirectory = "auto-rebuild";
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
      unitConfig.OnFailure = "auto-rebuild-switch-failure-notify.service";
    };
  };
}
