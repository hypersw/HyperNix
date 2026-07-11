{ config, lib, pkgs, ... }:
let
  cfg = config.hypersw.containers.UserContainers.Guest;
in
{
  config = lib.mkIf (cfg.Enable && cfg.Konsole.Enable) {
    environment.systemPackages = [ pkgs.kdePackages.konsole ];

    systemd.services.AutoLogin = {
      wantedBy = [ "multi-user.target" ];
      after = [ "multi-user.target" ];
      serviceConfig = {
        Type = "idle";
        Restart = "always";
        RestartSec = 16;
        StandardInput = "tty";
        StandardOutput = "journal+console";
        StandardError = "inherit";
        TTYPath = "/dev/console";
        ExecStart = "${pkgs.util-linux}/bin/login -f ${cfg.User}";
        KillMode = "process";
      };
    };

    systemd.user.services.auto-konsole = {
      description = "Start Konsole on user login";
      wantedBy = [ "default.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.kdePackages.konsole}/bin/konsole -name konsole-${cfg.User}";
        Restart = "on-failure";
        ExecStartPost = lib.mkIf (cfg.Gui.Mode == "SharedX11") (pkgs.writeShellScript "move-konsole-window" ''
          for ((attempt=0; attempt<32; attempt++)); do
            WINDOW_ID=$(${pkgs.wmctrl}/bin/wmctrl -lx | ${pkgs.gawk}/bin/awk '/konsole-${cfg.User}\.konsole/ {print $1}')
            if [ -n "$WINDOW_ID" ]; then
              ${pkgs.wmctrl}/bin/wmctrl -i -r "$WINDOW_ID" -t ${toString cfg.Konsole.WorkspaceId}
              exit 0
            fi
            sleep 0.1
          done
          exit 0
        '');
      };
    };
  };
}
