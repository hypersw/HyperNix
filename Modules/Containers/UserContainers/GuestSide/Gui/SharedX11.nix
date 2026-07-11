{ config, lib, pkgs, ... }:
let
  cfg = config.hypersw.containers.UserContainers.Guest;
in
{
  config = lib.mkIf (cfg.Enable && cfg.Gui.Mode == "SharedX11") {
    environment = {
      sessionVariables = {
        XAUTHORITY = "/home/${cfg.User}/.Xauth/.Xauth_container";
        QT_X11_NO_MITSHM = "1";
        _JAVA_AWT_NO_MITSHM = "1";
        SDL_VIDEO_X11_NODIRECTCOLOR = "1";
        XCB_FAKE_MONITORS = pkgs.writeText "libxcb-fake-monitors.xml" "<monitors version=\"1\"><configuration><disable_shm/></configuration></monitors>";
        NO_AT_BRIDGE = "1";
        GTK_A11Y = "none";
      } // lib.optionalAttrs (cfg.Gui.MesaDriverName != "") {
        LIBVA_DRIVER_NAME = cfg.Gui.MesaDriverName;
        MESA_LOADER_DRIVER_OVERRIDE = cfg.Gui.MesaDriverName;
      };

      shellInit = ''
        if [ -z "''${DISPLAY:-}" ] && [ -r "$HOME/.Xauth/display.env" ]; then
          . "$HOME/.Xauth/display.env"
          export DISPLAY
        fi
      '';
    };

    systemd.tmpfiles.rules = [
      "d /etc/environment.d 0755 root root -"
      "L+ /etc/environment.d/10-host-display.conf - - - - /home/${cfg.User}/.Xauth/display.env"
    ];
  };
}
