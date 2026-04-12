{ config, lib, pkgs, ... }:
let
  cfg = config.services.printscan-telegram-bot;
  daemonCfg = config.services.printscan-daemon;
  sharedPackage = import ../Shared/package.nix { inherit pkgs; };
  botPackage = import ./package.nix { inherit pkgs sharedPackage; };
in
{
  options.services.printscan-telegram-bot = {
    enable = lib.mkEnableOption "Telegram bot for print/scan operations";

    tokenFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to file containing the Telegram bot API token (via sops-nix/agenix)";
    };

    allowedUsers = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          id = lib.mkOption { type = lib.types.int; description = "Telegram user ID"; };
          name = lib.mkOption { type = lib.types.str; description = "Display name (for logging and accounting)"; };
        };
      });
      default = [];
      description = "Telegram users allowed to use the bot";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = daemonCfg.enable;
      message = "services.printscan-telegram-bot requires services.printscan-daemon to be enabled";
    }];

    systemd.services.printscan-telegram-bot = {
      description = "Print/Scan Telegram Bot";
      after = [ "printscan-daemon.service" "network-online.target" ];
      wants = [ "printscan-daemon.service" "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      # Token provided via systemd LoadCredential → $CREDENTIALS_DIRECTORY/telegram-token
      environment = {
        PRINTSCAN_SOCKET = daemonCfg.socketPath;
        PRINTSCAN_ALLOWED_USERS = builtins.toJSON (map (u: { inherit (u) id name; }) cfg.allowedUsers);
      };

      serviceConfig = {
        Type = "simple";
        ExecStart = "${botPackage}/bin/PrintScan.TelegramBot";
        Restart = "on-failure";
        RestartSec = "10s";

        # systemd credential — decrypted file available at $CREDENTIALS_DIRECTORY/telegram-token
        LoadCredential = "telegram-token:${cfg.tokenFile}";

        DynamicUser = true;
        SupplementaryGroups = [ daemonCfg.group ];

        # Hardening
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };
  };
}
