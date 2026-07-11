{ config, lib, pkgs, options, ... }:
let
  cfg = config.hypersw.containers.UserContainers.Guest;
  switchCfg = cfg.SelfSwitch;
  rebuildCommand = "/run/current-system/sw/bin/systemctl start hypersw-container-rebuild.service";
  logCommand = "/run/current-system/sw/bin/journalctl -u hypersw-container-rebuild.service";
  hasAutoRebuildOnPush = lib.hasAttrByPath [ "hypersw" "services" "auto-rebuild-on-push" "activationCommand" ] options;

  containerRebuild = pkgs.writeShellScriptBin "container-rebuild" ''
    set -euo pipefail

    mode="''${1:-${switchCfg.DefaultMode}}"
    case "$mode" in
      switch|test)
        exec ${config.system.build.nixos-rebuild}/bin/nixos-rebuild "$mode" \
          --flake ${lib.escapeShellArg switchCfg.Flake}#${lib.escapeShellArg switchCfg.ConfigName}
        ;;
      boot)
        workdir=$(${pkgs.coreutils}/bin/mktemp -d)
        cleanup() {
          ${pkgs.coreutils}/bin/rm -rf "$workdir"
        }
        trap cleanup EXIT

        (
          cd "$workdir"
          ${config.system.build.nixos-rebuild}/bin/nixos-rebuild build \
            --flake ${lib.escapeShellArg switchCfg.Flake}#${lib.escapeShellArg switchCfg.ConfigName}
        )

        system_path=$(${pkgs.coreutils}/bin/readlink -f "$workdir/result")
        case "$system_path" in
          /nix/store/*) ;;
          *)
            echo "container-rebuild boot produced non-store path: $system_path" >&2
            exit 1
            ;;
        esac

        request_dir=${lib.escapeShellArg switchCfg.HostBootRequestDir}
        request_tmp="$request_dir/next-system.tmp"
        request_dst="$request_dir/next-system"
        ${pkgs.coreutils}/bin/mkdir -p "$request_dir"
        printf '%s\n' "$system_path" > "$request_tmp"
        ${pkgs.coreutils}/bin/mv -f "$request_tmp" "$request_dst"
        echo "requested host boot path for container ${cfg.Name}: $system_path"
        ;;
      *)
        echo "usage: container-rebuild [switch|test|boot]" >&2
        exit 2
        ;;
    esac
  '';
in
{
  config = lib.mkIf (cfg.Enable && switchCfg.Enable) (lib.mkMerge [
    {
    environment.systemPackages = [
      containerRebuild
      (pkgs.writeShellScriptBin "container-switch" ''
        exec /run/wrappers/bin/sudo ${rebuildCommand}
      '')
      (pkgs.writeShellScriptBin "container-switch-log" ''
        exec /run/wrappers/bin/sudo ${logCommand} "$@"
      '')
    ];

    systemd.services.hypersw-container-rebuild = {
      description = "Rebuild this managed container using its configured mode";
      serviceConfig = {
        Type = "oneshot";
        WorkingDirectory = "/";
      };
      path = [ pkgs.nix pkgs.git pkgs.coreutils ];
      script = ''
        set -euo pipefail
        ${containerRebuild}/bin/container-rebuild ${lib.escapeShellArg switchCfg.DefaultMode}
      '';
    };

    system.build.hypersw-container-rebuild = containerRebuild;

    security.sudo.extraRules = lib.mkIf (cfg.User != null) [
      {
        users = [ cfg.User ];
        commands = [
          {
            command = rebuildCommand;
            options = [ "NOPASSWD" ];
          }
          {
            command = logCommand;
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];
    }

    (lib.mkIf hasAutoRebuildOnPush {
      hypersw.services.auto-rebuild-on-push.activationCommand =
        "${containerRebuild}/bin/container-rebuild ${lib.escapeShellArg switchCfg.DefaultMode}";
    })
  ]);
}
