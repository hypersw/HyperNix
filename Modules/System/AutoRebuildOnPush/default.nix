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

    LATEST_REV=$(${pkgs.git}/bin/git ls-remote "https://github.com/$OWNER_REPO" "refs/heads/$BRANCH" \
      | ${pkgs.coreutils}/bin/cut -f1)

    if [ -z "$LATEST_REV" ]; then
      echo "$LOG_TAG: could not resolve latest rev for $OWNER_REPO/$BRANCH" >&2
      exit 1
    fi

    if [ "$CURRENT_REV" = "$LATEST_REV" ]; then
      echo "$LOG_TAG: up to date ($CURRENT_REV)"
      exit 0
    fi

    echo "$LOG_TAG: upstream changed $CURRENT_REV -> $LATEST_REV, updating..."

    # Update only the upstream input, not nixpkgs
    ${pkgs.nix}/bin/nix flake update "$INPUT_NAME" --flake "$FLAKE_DIR"

    echo "$LOG_TAG: rebuilding..."
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

        # Network access needed for git ls-remote and nix flake update
        # but restrict everything else
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;

        # Allow writes to /etc/nixos (flake.lock update) and nix store
        ReadWritePaths = [ cfg.flakeDir "/nix" ];
      };
      path = [ pkgs.git ];
    };
  };
}
