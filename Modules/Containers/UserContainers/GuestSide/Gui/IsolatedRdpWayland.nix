{ config, lib, pkgs, ... }:
let
  cfg = config.hypersw.containers.UserContainers.Guest;
  hasRdpCredentials =
    cfg.Gui.RdpNlaUsername != null
    && cfg.Gui.RdpNlaPassword != null;
  hasCustomTlsIdentity =
    cfg.Gui.RdpCertificateFile != null
    && cfg.Gui.RdpCertificateKeyFile != null;
  compositorUnit = "isolated-rdp-wayland-compositor.service";
  rdpOutputLifecycle = import ./RdpOutputLifecycle.nix { inherit pkgs; };
in
{
  # This mode is deliberately independent from host graphics: KWin renders to
  # a virtual framebuffer, KRdp captures it through the patched QPainter path,
  # and the only exposed transport is the guest's loopback RDP listener.
  config = lib.mkIf (cfg.Enable && cfg.Gui.Mode == "IsolatedRdpWayland") {
    nixpkgs.overlays = [ (import ./KRdpOverlay.nix) ];

    warnings = lib.optional (!hasRdpCredentials) ''
      IsolatedRdpWayland is not starting KRdp: configure Gui.RdpNlaUsername and
      Gui.RdpNlaPassword. The current test password is intentionally temporary;
      replace it with a guest-local runtime secret before real use.
    '';

    assertions = [
      {
        assertion =
          (cfg.Gui.RdpCertificateFile == null)
          == (cfg.Gui.RdpCertificateKeyFile == null);
        message = ''
          IsolatedRdpWayland requires Gui.RdpCertificateFile and
          Gui.RdpCertificateKeyFile to be configured together.
        '';
      }
    ];

    environment.systemPackages = [
      pkgs.kdePackages.kwin
      pkgs.kdePackages.krdp
      pkgs.kdePackages.plasma-workspace
      pkgs.kdePackages.plasma-desktop
      pkgs.kdePackages.kglobalacceld
      pkgs.openssl
      rdpOutputLifecycle
    ];

    environment.sessionVariables = {
      WAYLAND_DISPLAY = cfg.Gui.IsolatedWaylandSocketName;
      XDG_SESSION_TYPE = "wayland";
      XDG_CURRENT_DESKTOP = "KDE";
      KDE_FULL_SESSION = "true";
      KDE_SESSION_VERSION = "6";
      QT_QPA_PLATFORM = "wayland";
      QT_QPA_PLATFORMTHEME = "kde";
      NIXOS_OZONE_WL = "1";
      OZONE_PLATFORM = "wayland";
      ELECTRON_OZONE_PLATFORM_HINT = "wayland";
      GDK_BACKEND = "wayland";
      SDL_VIDEODRIVER = "wayland";
      GLFW_PLATFORM = "wayland";
      CLUTTER_BACKEND = "wayland";
      WINIT_UNIX_BACKEND = "wayland";
      MOZ_ENABLE_WAYLAND = "1";
      NO_AT_BRIDGE = "1";
      GTK_A11Y = "none";
    };

    systemd.user.services.isolated-rdp-wayland-compositor = {
      description = "Headless KWin compositor for isolated KRdp desktop";
      wantedBy = [ "default.target" ];
      after = [ "dbus.socket" ];
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = 2;
        UnsetEnvironment = [ "WAYLAND_DISPLAY" ];
        ExecStart = "${pkgs.kdePackages.kwin}/bin/kwin_wayland --virtual --no-lockscreen --socket=${cfg.Gui.IsolatedWaylandSocketName}";
      };
    };

    systemd.user.services.isolated-rdp-wayland-plasma = {
      description = "Plasma desktop shell for isolated KRdp desktop";
      wantedBy = [ "default.target" ];
      requires = [ compositorUnit ];
      after = [ compositorUnit ];
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = 2;
        ExecStartPre = pkgs.writeShellScript "wait-for-isolated-rdp-wayland" ''
          set -euo pipefail
          socket="/run/user/$(id -u)/${cfg.Gui.IsolatedWaylandSocketName}"
          for attempt in $(seq 1 100); do
            [ -S "$socket" ] && exit 0
            sleep 0.1
          done
          echo "KWin Wayland socket did not appear: $socket" >&2
          exit 1
        '';
        ExecStart = "${pkgs.kdePackages.plasma-workspace}/bin/plasmashell --no-respawn";
      };
    };

    systemd.user.services.isolated-rdp-wayland-server = lib.mkIf hasRdpCredentials {
      description = "Loopback-only KRdp server for isolated Plasma desktop";
      wantedBy = [ "default.target" ];
      requires = [ compositorUnit "isolated-rdp-wayland-plasma.service" ];
      after = [ compositorUnit "isolated-rdp-wayland-plasma.service" ];
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = 2;
        Environment = [
          "WAYLAND_DISPLAY=${cfg.Gui.IsolatedWaylandSocketName}"
          "KRDP_LIFECYCLE_HANDLER=${rdpOutputLifecycle}/bin/hypersw-rdp-output-lifecycle"
        ];
        ExecStart = pkgs.writeShellScript "isolated-rdp-wayland-server" ''
          set -euo pipefail
          state="$HOME/.local/state/hypersw/isolated-rdp-wayland"
          mkdir -p "$state"
          umask 077

          certificate=${lib.escapeShellArg (if hasCustomTlsIdentity then cfg.Gui.RdpCertificateFile else "")}
          certificate_key=${lib.escapeShellArg (if hasCustomTlsIdentity then cfg.Gui.RdpCertificateKeyFile else "")}
          if [ -z "$certificate" ]; then
            certificate="$state/tls.crt"
            certificate_key="$state/tls.key"
            if [ ! -s "$certificate" ] || [ ! -s "$certificate_key" ]; then
              ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 -nodes \
                -keyout "$certificate_key" \
                -out "$certificate" \
                -days 3650 \
                -subj ${lib.escapeShellArg "/CN=${cfg.Name}-krdp"}
            fi
          fi

          # TODO: This test password is embedded in the Nix-built script and
          # appears in KRdp's process arguments. Replace RdpNlaPassword with a
          # secret-backed runtime credential before using this beyond testing.
          exec ${pkgs.kdePackages.krdp}/bin/krdpserver \
            --plasma \
            --virtual-monitor ${lib.escapeShellArg cfg.Gui.RdpFallbackVirtualMonitor} \
            --address ${lib.escapeShellArg cfg.Gui.RdpListenAddress} \
            --port ${toString cfg.Gui.RdpPort} \
            --quality ${toString cfg.Gui.RdpQuality} \
            --certificate "$certificate" \
            --certificate-key "$certificate_key" \
            --username ${lib.escapeShellArg cfg.Gui.RdpNlaUsername} \
            --password ${lib.escapeShellArg cfg.Gui.RdpNlaPassword}
        '';
      };
    };
  };
}
