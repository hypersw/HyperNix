{ config, lib, pkgs, ... }:
let
  cfg = config.hypersw.containers.UserContainers.Guest;
in {
  # KRdp owns an existing Plasma Wayland session.  Unlike GNOME Remote Desktop,
  # its --address option provides a real loopback-only listener.
  config = lib.mkIf (cfg.Enable && cfg.Gui.Mode == "IsolatedKdeRdp") {
    services.desktopManager.plasma6.enable = true;
    services.pipewire.enable = true;
    xdg.portal = {
      enable = true;
      extraPortals = [ pkgs.kdePackages.xdg-desktop-portal-kde ];
      config.common.default = lib.mkForce [ "kde" ];
    };

    networking = {
      networkmanager.enable = lib.mkForce false;
      wireless.enable = lib.mkForce false;
      modemmanager.enable = lib.mkForce false;
      useDHCP = lib.mkForce false;
      dhcpcd.enable = lib.mkForce false;
    };

    users.users = lib.mkIf (cfg.User != null) {
      "${cfg.User}".linger = true;
    };

    services.avahi.enable = lib.mkForce false;
    systemd.services = {
      AutoLogin.enable = lib.mkForce false;
      console-getty.enable = lib.mkForce false;
    };

    environment.sessionVariables = {
      XDG_SESSION_TYPE = "wayland";
      XDG_CURRENT_DESKTOP = "KDE";
      DESKTOP_SESSION = "plasma";
      NIXOS_OZONE_WL = "1";
      OZONE_PLATFORM = "wayland";
      ELECTRON_OZONE_PLATFORM_HINT = "wayland";
      GDK_BACKEND = "wayland";
      QT_QPA_PLATFORM = "wayland";
      SDL_VIDEODRIVER = "wayland";
      MOZ_ENABLE_WAYLAND = "1";
    };

    # startplasma-wayland creates the compositor/session which KRdp exposes.
    # It is deliberately a user service rather than SDDM autologin: no physical
    # seat or console login is involved, and lingering preserves it on disconnect.
    systemd.user.services.hypersw-plasma-wayland = {
      description = "Persistent Plasma Wayland session for managed KRdp";
      wantedBy = [ "default.target" ];
      after = [ "dbus.service" "pipewire.service" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.kdePackages.plasma-workspace}/bin/startplasma-wayland";
        Restart = "on-failure";
        RestartSec = 2;
      };
    };

    systemd.user.services.hypersw-kde-rdp-setup = {
      description = "Configure KRdp credentials and TLS for this managed container";
      wantedBy = [ "default.target" ];
      before = [ "hypersw-kde-rdp.service" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        set -euo pipefail
        umask 077
        state="$HOME/.local/state/hypersw/kde-rdp"
        credentials="$state/credentials"
        certificate="$state/tls.crt"
        key="$state/tls.key"
        ${pkgs.coreutils}/bin/mkdir -p "$state"
        if [ -n ${lib.escapeShellArg cfg.Gui.RdpCredentialsFile} ]; then
          ${pkgs.coreutils}/bin/install -m 600 ${lib.escapeShellArg cfg.Gui.RdpCredentialsFile} "$credentials"
        elif ${if cfg.Gui.RdpPassword == null then "false" else "true"}; then
          printf '%s\n%s\n' ${lib.escapeShellArg cfg.Gui.RdpUsername} ${lib.escapeShellArg (if cfg.Gui.RdpPassword == null then "" else cfg.Gui.RdpPassword)} > "$credentials"
        elif [ ! -s "$credentials" ]; then
          password="$(${pkgs.openssl}/bin/openssl rand -base64 33 | ${pkgs.coreutils}/bin/tr -d '\n')"
          printf '%s\n%s\n' ${lib.escapeShellArg cfg.Gui.RdpUsername} "$password" > "$credentials"
        fi
        username=$(${pkgs.gnused}/bin/sed -n '1p' "$credentials")
        password=$(${pkgs.gnused}/bin/sed -n '2p' "$credentials")
        [ -n "$username" ] || { echo "KRdp credentials need a username" >&2; exit 1; }
        if [ ! -s "$key" ] || [ ! -s "$certificate" ]; then
          ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:3072 -nodes -keyout "$key" -out "$certificate" -days 3650 -subj ${lib.escapeShellArg "/CN=${cfg.Name}-kde-rdp"}
        fi
      '';
    };

    systemd.user.services.hypersw-kde-rdp = {
      description = "KRdp server for the managed Plasma Wayland session";
      wantedBy = [ "default.target" ];
      requires = [ "hypersw-kde-rdp-setup.service" "hypersw-plasma-wayland.service" ];
      after = [ "hypersw-kde-rdp-setup.service" "hypersw-plasma-wayland.service" ];
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = 2;
      };
      script = ''
        set -euo pipefail
        state="$HOME/.local/state/hypersw/kde-rdp"
        username=$(${pkgs.gnused}/bin/sed -n '1p' "$state/credentials")
        password=$(${pkgs.gnused}/bin/sed -n '2p' "$state/credentials")
        exec ${pkgs.kdePackages.krdp}/bin/krdpserver \
          --plasma \
          --address ${lib.escapeShellArg cfg.Gui.RdpListenAddress} \
          --port ${toString cfg.Gui.RdpPort} \
          --username "$username" \
          --password "$password" \
          --certificate "$state/tls.crt" \
          --certificate-key "$state/tls.key"
      '';
    };
  };
}