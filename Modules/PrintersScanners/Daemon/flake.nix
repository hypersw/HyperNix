{
  description = "Print/Scan daemon — REST API over Unix socket for print/scan job management";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: {
    nixosModules.default = { config, lib, pkgs, ... }:
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
          # Create the printscan group for socket access control
          users.groups.${cfg.group} = {};

          # Socket-activated service via systemd
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
              # TODO: replace with actual daemon binary once built
              # ExecStart = "${printscan-daemon-pkg}/bin/printscan-daemon";
              ExecStart = "${pkgs.coreutils}/bin/sleep infinity"; # placeholder
              Restart = "on-failure";
              RestartSec = "5s";

              # Hardening
              DynamicUser = true;
              SupplementaryGroups = [
                cfg.group
                "lp"       # for CUPS/printing
                "scanner"  # for SANE/scanning
              ];
              ProtectSystem = "strict";
              ProtectHome = true;
              PrivateTmp = true;
              NoNewPrivileges = true;
            };
          };
        };
      };
  };
}
