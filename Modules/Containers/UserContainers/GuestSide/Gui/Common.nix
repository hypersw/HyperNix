{ config, lib, pkgs, ... }:
let
  cfg = config.hypersw.containers.UserContainers.Guest;
  hasGui = cfg.Gui.Mode != "None";
  audioBridgeDir = "${cfg.HostBridgeDir}/audio";
  pipeWireSocketName = "pipewire-0";
  pulseBridgeSocketName = "pulse-native";
  pulseRuntimeSocket = "pulse/native";
in
{
  config = lib.mkIf (cfg.Enable && hasGui) {
    environment.systemPackages = [
      pkgs.mesa
      pkgs.libGLU
      pkgs.libGL
      pkgs.mesa-demos
      pkgs.fontconfig
      pkgs.libxcb-cursor
      pkgs.adwaita-icon-theme
      pkgs.hicolor-icon-theme
      pkgs.gnome-themes-extra
      pkgs.gsettings-desktop-schemas
    ] ++ lib.optionals cfg.Gui.Gpu [
      pkgs.libva
      pkgs.libva-utils
    ] ++ lib.optionals cfg.Gui.Audio [
      pkgs.alsa-plugins
      pkgs.pipewire
    ];

    fonts = {
      packages = cfg.Gui.FontPackages;
      enableDefaultPackages = true;
      fontDir.enable = true;
      fontconfig = {
        enable = true;
        # GUI guests are currently tuned for the known RGB Surface display.
        # Keep this in the common GUI layer so every guest uses one font
        # rasterization policy; revisit it before supporting rotated/BGR clients.
        subpixel.rgba = "rgb";
      };
    };

    hardware.graphics.enable = lib.mkIf cfg.Gui.Gpu true;
    programs.dconf.enable = true;
    services.dbus.enable = true;
    services.gnome.gnome-keyring.enable = true;

    xdg.portal = {
      enable = true;
      extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
      config.common.default = [ "gtk" ];
    };

    security.pam.services = {
      kwallet = {
        name = "kwallet";
        enableKwallet = true;
      };
      login.enableGnomeKeyring = true;
    };

    users = lib.mkIf (cfg.User != null) {
      users."${cfg.User}".extraGroups = lib.optionals cfg.Gui.Gpu [ "video" "render" ];
      groups = lib.mkIf cfg.Gui.Gpu {
        video = {};
        render = {};
      };
    };

    systemd.user.services.gnome-keyring-unlock = {
      description = "Start and unlock the empty-password gnome-keyring (secrets)";
      wantedBy = [ "default.target" ];
      after = [ "dbus.socket" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "gnome-keyring-unlock" ''
          set -eu
          /run/wrappers/bin/gnome-keyring-daemon --start --unlock --components=secrets </dev/null || true
        '';
      };
    };

    environment.sessionVariables = lib.mkIf cfg.Gui.Audio {
      # The mounted directory survives host PipeWire socket replacement.
      PULSE_SERVER = "unix:${audioBridgeDir}/${pulseBridgeSocketName}";
    };

    environment.etc = lib.optionalAttrs cfg.Gui.Audio {
      "asound.conf".text = ''
        pcm.default pulse
        ctl.default pulse
      '';
    };

    systemd.user.services.audio-socket-links = lib.mkIf cfg.Gui.Audio {
      description = "Symlink host audio sockets into XDG_RUNTIME_DIR";
      wantedBy = [ "default.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "audio-socket-links" ''
          set -euo pipefail
          RTDIR="/run/user/$(id -u)"
          mkdir -p "$RTDIR/pulse"
          # Host audio sockets are bind-mounted under ${audioBridgeDir} to keep
          # host/container crossings visible. Many clients probe the conventional
          # XDG_RUNTIME_DIR names directly, so create links there as compatibility
          # shims while keeping the host bridge path stable and explicit.
          [ ! -L "$RTDIR/${pipeWireSocketName}" ] && \
            ln -s ${audioBridgeDir}/${pipeWireSocketName} "$RTDIR/${pipeWireSocketName}"
          [ ! -L "$RTDIR/${pulseRuntimeSocket}" ] && \
            ln -s ${audioBridgeDir}/${pulseBridgeSocketName} "$RTDIR/${pulseRuntimeSocket}"
        '';
      };
    };
  };
}
