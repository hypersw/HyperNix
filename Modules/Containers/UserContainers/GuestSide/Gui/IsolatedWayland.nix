{ config, lib, pkgs, ... }:
let
  cfg = config.hypersw.containers.UserContainers.Guest;
in
{
  config = lib.mkIf (cfg.Enable && cfg.Gui.Mode == "IsolatedWayland") {
    environment.systemPackages = [
      pkgs.weston
    ];

    environment.sessionVariables = {
      WAYLAND_DISPLAY = cfg.Gui.IsolatedWaylandSocketName;
      GDK_BACKEND = "wayland,x11";
      QT_QPA_PLATFORM = "wayland;xcb";
      SDL_VIDEODRIVER = "wayland,x11";
      MOZ_ENABLE_WAYLAND = "1";
      NO_AT_BRIDGE = "1";
      GTK_A11Y = "none";
    };

    # Draft only. For a stronger boundary, move the nested compositor outside
    # this container and bind only its produced socket in. Running Weston here
    # requires making the host compositor socket reachable to this service while
    # keeping normal app users pointed at wayland-isolated.
    systemd.user.services.nested-wayland-compositor = {
      description = "Nested Wayland compositor for isolated container GUI";
      wantedBy = [ "default.target" ];
      after = [ "dbus.socket" ];
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        ExecStart = pkgs.writeShellScript "nested-wayland-compositor" ''
          set -euo pipefail
          RTDIR="/run/user/$(id -u)"
          # Same convention as SharedWayland: host-provided sockets are mounted
          # under ${cfg.HostBridgeDir}, then linked into XDG_RUNTIME_DIR
          # because Wayland compositors and clients resolve socket names there.
          [ ! -L "$RTDIR/${cfg.Gui.HostWaylandSocketName}" ] && \
            ln -s ${cfg.HostBridgeDir}/${cfg.Gui.HostWaylandSocketName} "$RTDIR/${cfg.Gui.HostWaylandSocketName}"
          export WAYLAND_DISPLAY=${cfg.Gui.HostWaylandSocketName}
          exec ${pkgs.weston}/bin/weston --backend=wayland-backend.so --socket=${cfg.Gui.IsolatedWaylandSocketName}
        '';
      };
    };
  };
}
