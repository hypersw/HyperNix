{ config, lib, pkgs, ... }:
let
  cfg = config.hypersw.containers.UserContainers.Guest;
in
{
  config = lib.mkIf (cfg.Enable && cfg.Gui.Mode == "SharedWayland") {
    environment.sessionVariables = {
      WAYLAND_DISPLAY = cfg.Gui.HostWaylandSocketName;
      GDK_BACKEND = "wayland,x11";
      QT_QPA_PLATFORM = "wayland;xcb";
      SDL_VIDEODRIVER = "wayland,x11";
      MOZ_ENABLE_WAYLAND = "1";
      NO_AT_BRIDGE = "1";
      GTK_A11Y = "none";
    };

    systemd.user.services.host-wayland-socket-link = {
      description = "Link host Wayland socket into XDG_RUNTIME_DIR for client lookup";
      wantedBy = [ "default.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "host-wayland-socket-link" ''
          set -euo pipefail
          RTDIR="/run/user/$(id -u)"
          # The host bind mount lives under ${cfg.HostBridgeDir} so the
          # boundary crossing is obvious and host-controlled. Wayland clients,
          # however, resolve WAYLAND_DISPLAY relative to XDG_RUNTIME_DIR, so we
          # expose a same-named symlink there and set WAYLAND_DISPLAY to that
          # basename.
          [ ! -L "$RTDIR/${cfg.Gui.HostWaylandSocketName}" ] && \
            ln -s ${cfg.HostBridgeDir}/${cfg.Gui.HostWaylandSocketName} "$RTDIR/${cfg.Gui.HostWaylandSocketName}"
        '';
      };
    };
  };
}
