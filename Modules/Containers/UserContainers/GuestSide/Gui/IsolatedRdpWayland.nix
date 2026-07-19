{ config, lib, pkgs, ... }:
let
  cfg = config.hypersw.containers.UserContainers.Guest;
in
{
  # RDP is a separate isolated mode. It creates its own compositor and does not
  # mount, link, or ACL the host Wayland socket at all.
  config = lib.mkIf (cfg.Enable && cfg.Gui.Mode == "IsolatedRdpWayland") {
    environment.systemPackages = [ pkgs.weston pkgs.openssl ];

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

          # Weston 15 requires security material for every TCP RDP listener.
          # FreeRDP 3 no longer creates legacy RDP4 keys, so use a local TLS
          # pair even when SSH is the outer transport. Keep it out of the Nix
          # store because the private key belongs to this guest instance.
          if [ ! -s "$state/tls.key" ] || [ ! -s "$state/tls.crt" ]; then
            ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 -nodes \
              -keyout "$state/tls.key" \
              -out "$state/tls.crt" \
              -days 3650 \
              -subj ${lib.escapeShellArg "/CN=${cfg.Name}-rdp"}
          fi

          exec ${pkgs.weston}/bin/weston \
            --backend=rdp-backend.so \
            --shell=desktop-shell.so \
            --address=${lib.escapeShellArg cfg.Gui.RdpListenAddress} \
            --port=${toString cfg.Gui.RdpPort} \
            --rdp-tls-key="$state/tls.key" \
            --rdp-tls-cert="$state/tls.crt" \
            --socket=${lib.escapeShellArg cfg.Gui.IsolatedWaylandSocketName}
        '';
      };
    };
  };
}
