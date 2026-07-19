{ config, lib, pkgs, ... }:
let
  cfg = config.hypersw.containers.UserContainers.Guest;
in
{
  # RDP is a separate isolated mode. It creates its own compositor and does not
  # mount, link, or ACL the host Wayland socket at all.
  config = lib.mkIf (cfg.Enable && cfg.Gui.Mode == "IsolatedRdpWayland") {
    environment.systemPackages = [ pkgs.weston pkgs.freerdp ];

    environment.sessionVariables = {
      WAYLAND_DISPLAY = cfg.Gui.IsolatedWaylandSocketName;
      NIXOS_OZONE_WL = "1";
      OZONE_PLATFORM = "wayland";
      ELECTRON_OZONE_PLATFORM_HINT = "wayland";
      GDK_BACKEND = "wayland";
      QT_QPA_PLATFORM = "wayland";
      SDL_VIDEODRIVER = "wayland";
      GLFW_PLATFORM = "wayland";
      CLUTTER_BACKEND = "wayland";
      XDG_SESSION_TYPE = "wayland";
      WINIT_UNIX_BACKEND = "wayland";
      MOZ_ENABLE_WAYLAND = "1";
      NO_AT_BRIDGE = "1";
      GTK_A11Y = "none";
    };

    systemd.user.services.isolated-rdp-wayland-compositor = {
      description = "Isolated RDP Wayland compositor";
      wantedBy = [ "default.target" ];
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        ExecStart = pkgs.writeShellScript "isolated-rdp-wayland-compositor" ''
          set -euo pipefail
          state="$HOME/.local/state/hypersw/isolated-rdp-wayland"
          mkdir -p "$state"

          # RDP security is needed for a TCP listener when TLS is disabled.
          # Keep the private key in user state, never in the Nix store.
          if [ ! -s "$state/rdp-security.key" ]; then
            cd "$state"
            ${pkgs.freerdp}/bin/winpr-makecert -rdp -silent -n rdp-security
          fi

          exec ${pkgs.weston}/bin/weston \
            --backend=rdp-backend.so \
            --shell=desktop-shell.so \
            --address=${lib.escapeShellArg cfg.Gui.RdpListenAddress} \
            --port=${toString cfg.Gui.RdpPort} \
            --rdp4-key="$state/rdp-security.key" \
            --socket=${lib.escapeShellArg cfg.Gui.IsolatedWaylandSocketName}
        '';
      };
    };
  };
}
