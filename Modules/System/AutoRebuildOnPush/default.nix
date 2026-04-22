{ config, lib, pkgs, ... }:
let
  cfg = config.services.auto-rebuild-on-push;

  checkScript = pkgs.writeShellScript "check-upstream-and-rebuild" ''
    set -euo pipefail

    FLAKE_DIR="${cfg.flakeDir}"
    INPUT_NAME="${cfg.inputName}"
    LOG_TAG="auto-rebuild-on-push"

    # Extract the currently locked revision for the upstream input
    CURRENT_REV=$(${pkgs.nix}/bin/nix flake metadata "$FLAKE_DIR" --json 2>/dev/null \
      | ${pkgs.jq}/bin/jq -r ".locks.nodes.\"$INPUT_NAME\".locked.rev // empty")

    if [ -z "$CURRENT_REV" ]; then
      echo "$LOG_TAG: could not read current locked rev for input '$INPUT_NAME'" >&2
      exit 1
    fi

    # Extract owner/repo/ref from the flake metadata.
    # Handles both structured format (type+owner+repo) and url format (github:owner/repo).
    ORIGINAL=$(${pkgs.nix}/bin/nix flake metadata "$FLAKE_DIR" --json 2>/dev/null \
      | ${pkgs.jq}/bin/jq -c ".locks.nodes.\"$INPUT_NAME\".original")

    UPSTREAM_TYPE=$(echo "$ORIGINAL" | ${pkgs.jq}/bin/jq -r '.type // empty')
    if [ "$UPSTREAM_TYPE" = "github" ]; then
      OWNER=$(echo "$ORIGINAL" | ${pkgs.jq}/bin/jq -r '.owner // empty')
      REPO=$(echo "$ORIGINAL" | ${pkgs.jq}/bin/jq -r '.repo // empty')
      BRANCH=$(echo "$ORIGINAL" | ${pkgs.jq}/bin/jq -r '.ref // "master"')
      OWNER_REPO="$OWNER/$REPO"
    else
      # Fallback: try .url field (github:owner/repo format)
      UPSTREAM_URL=$(echo "$ORIGINAL" | ${pkgs.jq}/bin/jq -r '.url // empty')
      if [ -z "$UPSTREAM_URL" ]; then
        echo "$LOG_TAG: unsupported upstream type '$UPSTREAM_TYPE' for input '$INPUT_NAME'" >&2
        exit 1
      fi
      GITHUB_PART=$(echo "$UPSTREAM_URL" | sed 's|^github:||')
      OWNER_REPO=$(echo "$GITHUB_PART" | cut -d/ -f1-2)
      BRANCH=$(echo "$GITHUB_PART" | cut -d/ -f3-)
      BRANCH="''${BRANCH:-master}"
    fi

    # git ls-remote over flaky / missing network is expected — do NOT treat
    # it as a service failure (would otherwise cascade through netdata's
    # systemd-unit-failed alarm into a false-positive alert). Capture both
    # stdout and exit status; on network error, log and exit 0 so systemd
    # counts this tick as a clean no-op and the next timer firing retries.
    if ! LATEST_REV=$(${pkgs.git}/bin/git ls-remote "https://github.com/$OWNER_REPO" "refs/heads/$BRANCH" 2>/dev/null | ${pkgs.coreutils}/bin/cut -f1); then
      echo "$LOG_TAG: git ls-remote failed (likely transient network issue) — will retry next tick" >&2
      exit 0
    fi

    if [ -z "$LATEST_REV" ]; then
      echo "$LOG_TAG: empty ls-remote response — will retry next tick" >&2
      exit 0
    fi

    if [ "$CURRENT_REV" = "$LATEST_REV" ]; then
      echo "$LOG_TAG: up to date ($CURRENT_REV)"
      exit 0
    fi

    echo "$LOG_TAG: upstream changed $CURRENT_REV -> $LATEST_REV, updating..."

    # flake update needs network too — same treatment.
    if ! ${pkgs.nix}/bin/nix flake update "$INPUT_NAME" --flake "$FLAKE_DIR"; then
      echo "$LOG_TAG: flake update failed (likely transient network issue) — will retry next tick" >&2
      exit 0
    fi

    echo "$LOG_TAG: rebuilding..."
    # nixos-rebuild switch failure IS a real error worth alerting on —
    # it means the fetched flake actually built/activated badly. No soft-
    # fail here. Note this path requires `set +e` around the git/flake
    # ls-remote parts; pipefail stays on for rebuild's subprocesses.
    ${config.system.build.nixos-rebuild}/bin/nixos-rebuild switch --flake "$FLAKE_DIR#${cfg.configName}"
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
    systemd.timers.auto-rebuild-on-push = {
      description = "Poll upstream flake for changes";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";       # first check shortly after boot
        OnUnitActiveSec = cfg.interval;
        RandomizedDelaySec = "30s"; # jitter to avoid exact-interval patterns
      };
    };

    systemd.services.auto-rebuild-on-push = {
      description = "Check upstream flake and rebuild if changed";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = checkScript;

        # Needs network (git ls-remote, nix flake update), /etc/nixos (lock file),
        # /nix (store), and /root/.cache/nix (nix cache during flake update)
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
      path = [ pkgs.git ];
    };
  };
}
