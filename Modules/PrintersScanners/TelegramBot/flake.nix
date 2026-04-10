{
  description = "Telegram bot for print/scan — long-polling, talks to daemon via Unix socket";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: {
    nixosModules.default = { config, lib, pkgs, ... }:
      let
        cfg = config.services.printscan-telegram-bot;
        daemonCfg = config.services.printscan-daemon;
      in
      {
        options.services.printscan-telegram-bot = {
          enable = lib.mkEnableOption "Telegram bot for print/scan operations";

          tokenFile = lib.mkOption {
            type = lib.types.path;
            description = "Path to file containing the Telegram bot API token (via sops-nix/agenix)";
          };

          allowedUsers = lib.mkOption {
            type = lib.types.listOf lib.types.int;
            default = [];
            description = "Telegram user IDs allowed to use the bot (whitelist)";
          };
        };

        config = lib.mkIf cfg.enable {
          # Ensure daemon is enabled (bot needs it)
          assertions = [{
            assertion = daemonCfg.enable;
            message = "services.printscan-telegram-bot requires services.printscan-daemon to be enabled";
          }];

          systemd.services.printscan-telegram-bot = {
            description = "Print/Scan Telegram Bot";
            after = [ "printscan-daemon.socket" "network-online.target" ];
            wants = [ "printscan-daemon.socket" "network-online.target" ];
            wantedBy = [ "multi-user.target" ];

            serviceConfig = {
              Type = "simple";
              # TODO: replace with actual bot binary once built
              # ExecStart = "${telegram-bot-pkg}/bin/printscan-telegram-bot";
              ExecStart = "${pkgs.coreutils}/bin/sleep infinity"; # placeholder
              Restart = "on-failure";
              RestartSec = "10s";

              # Token access
              LoadCredential = "telegram-token:${cfg.tokenFile}";

              # Hardening
              DynamicUser = true;
              SupplementaryGroups = [ daemonCfg.group ]; # for socket access
              ProtectSystem = "strict";
              ProtectHome = true;
              PrivateTmp = true;
              NoNewPrivileges = true;
            };

            environment = {
              PRINTSCAN_SOCKET = daemonCfg.socketPath;
              PRINTSCAN_ALLOWED_USERS = lib.concatMapStringsSep "," toString cfg.allowedUsers;
            };
          };
        };
      };
  };
}
