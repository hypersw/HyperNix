{ config, lib, pkgs, ... }:
let
  cfg = config.hypersw.containers.UserContainers.Guest;
  isolatedCompositorUnit =
    if cfg.Gui.Mode == "IsolatedWayland"
    then "nested-wayland-compositor.service"
    else if cfg.Gui.Mode == "IsolatedRdpWayland"
    then "isolated-rdp-wayland-compositor.service"
    else if cfg.Gui.Mode == "IsolatedGnomeRdp"
    then "gnome-remote-desktop-headless.service"
    else null;
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
      wants = lib.optionals (isolatedCompositorUnit != null) [ isolatedCompositorUnit ];
      after = lib.optionals (isolatedCompositorUnit != null) [ isolatedCompositorUnit ];
      serviceConfig = {
        Type = "simple";
        # The old -name argument was only used for X11 wmctrl matching and is
        # no longer accepted by current Konsole. Wayland does not need it.
        ExecStart = "${pkgs.kdePackages.konsole}/bin/konsole";
        Restart = "on-failure";
      } // lib.optionalAttrs (cfg.Gui.Mode == "SharedX11") {
        ExecStartPost = pkgs.writeShellScript "move-konsole-window" ''
          for ((attempt=0; attempt<32; attempt++)); do
            WINDOW_ID=$(${pkgs.wmctrl}/bin/wmctrl -lx | ${pkgs.gawk}/bin/awk '/konsole-${cfg.User}\.konsole/ {print $1}')
            if [ -n "$WINDOW_ID" ]; then
              ${pkgs.wmctrl}/bin/wmctrl -i -r "$WINDOW_ID" -t ${toString cfg.Konsole.WorkspaceId}
              exit 0
            fi
            sleep 0.1
          done
          exit 0
        '';
      };
    };
  };
}
