{ config, lib, pkgs, ... }:
let
  cfg = config.services.printscan-daemon;
  sharedPackage = import ../Shared/package.nix { inherit pkgs; };
  daemonPackage = import ./package.nix { inherit pkgs sharedPackage; };
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
    users.users.printscan-daemon = {
      isSystemUser = true;
      group = cfg.group;
      description = "PrintScan daemon service user";
    };

    # Socket unit — systemd creates the socket with correct ownership/permissions
    # declaratively, then passes the fd to the daemon via socket activation.
    systemd.sockets.printscan-daemon = {
      description = "Print/Scan Daemon Socket";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = cfg.socketPath;
        SocketMode = "0660";
        SocketUser = "printscan-daemon";
        SocketGroup = cfg.group;
        RuntimeDirectory = "printscan";
        RuntimeDirectoryMode = "0755";
      };
    };

    systemd.services.printscan-daemon = {
      description = "Print/Scan Daemon";
      after = [ "cups.service" ];
      wants = [ "cups.service" ];
      # No wantedBy — socket activation starts the service on first connection

      environment = {
        PRINTSCAN_SOCKET = cfg.socketPath;
        # Don't set ASPNETCORE_URLS — Kestrel picks up the socket fd from
        # systemd via LISTEN_FDS (UseSystemd()). Setting ASPNETCORE_URLS
        # would make Kestrel try to bind a second socket, failing with
        # "address already in use".
      };

      serviceConfig = {
        # notify: UseSystemd() sends sd_notify(READY=1) when the app is ready
        Type = "notify";
        ExecStart = "${daemonPackage}/bin/PrintScan.Daemon";
        Restart = "on-failure";
        RestartSec = "5s";

        User = "printscan-daemon";
        Group = cfg.group;
        SupplementaryGroups = [ "lp" "scanner" ];

        # Hardening
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };
  };
}
