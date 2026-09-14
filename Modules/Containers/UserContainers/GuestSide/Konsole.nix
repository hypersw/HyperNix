{ config, lib, pkgs, ... }:
let
  cfg = config.hypersw.containers.UserContainers.Guest;
  guestCompositorUnit =
    if cfg.Gui.Mode == "RdpWeston"
    then "rdp-weston-compositor.service"
    else if cfg.Gui.Mode == "RdpGnome"
    then "gnome-remote-desktop-headless.service"
    else null;
in
{
  # The RdpGnome and RdpKde modes own and start their own Wayland session.
  # A standalone Konsole user unit races that session and has no display
  # before a client connects, so this legacy console launcher does not apply
  # to them; their desktop shell provides the terminal instead.
  config = lib.mkIf (cfg.Enable && cfg.Konsole.Enable && !(lib.elem cfg.Gui.Mode [ "RdpGnome" "RdpKdeIsolated" "RdpKdeWithDevices" ])) {
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
      wants = lib.optionals (guestCompositorUnit != null) [ guestCompositorUnit ];
      after = lib.optionals (guestCompositorUnit != null) [ guestCompositorUnit ];
      serviceConfig = {
        Type = "simple";
        # The old -name argument was only used for X11 wmctrl matching and is
        # no longer accepted by current Konsole. Wayland does not need it.
        ExecStart = "${pkgs.kdePackages.konsole}/bin/konsole";
        Restart = "on-failure";
      } // lib.optionalAttrs (cfg.Gui.Mode == "PropagatedX11") {
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
