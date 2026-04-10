{ config, lib, pkgs, ... }:
let
  cfg = config.services.printscan-daemon;
in
{
  options.services.printscan-daemon = {
    enable = lib.mkEnableOption "Print/Scan daemon with Unix socket API";

    socketPath = lib.mkOption {
      type = lib.types.str;
      default = "/run/printscan/api.sock";
      description = "Path to the Unix domain socket";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "printscan";
      description = "Group that can connect to the daemon socket";
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.${cfg.group} = {};

    systemd.sockets.printscan-daemon = {
      description = "Print/Scan Daemon Socket";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = cfg.socketPath;
        SocketMode = "0660";
        SocketGroup = cfg.group;
        DirectoryMode = "0755";
        RuntimeDirectory = "printscan";
      };
    };

    systemd.services.printscan-daemon = {
      description = "Print/Scan Daemon";
      after = [ "cups.service" ];
      wants = [ "cups.service" ];
      serviceConfig = {
        Type = "notify";
        ExecStart = "${pkgs.coreutils}/bin/sleep infinity"; # placeholder
        Restart = "on-failure";
        RestartSec = "5s";
        DynamicUser = true;
        SupplementaryGroups = [ cfg.group "lp" "scanner" ];
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };
  };
}
