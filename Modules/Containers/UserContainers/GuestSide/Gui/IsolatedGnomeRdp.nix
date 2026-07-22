{ config, lib, pkgs, ... }:
let cfg = config.hypersw.containers.UserContainers.Guest;
in {
  # Own an independent GNOME/Mutter Wayland session; no host display or socket is mounted.
  config = lib.mkIf (cfg.Enable && cfg.Gui.Mode == "IsolatedGnomeRdp") {
    services.desktopManager.gnome.enable = true;
    services.pipewire.enable = true;

    # nspawn guests share the host network namespace and have no physical NIC
    # to configure. GNOME pulls in NetworkManager by default; in turn it starts
    # wpa_supplicant and defaults ModemManager on. None is meaningful here.
    networking = {
      networkmanager.enable = lib.mkForce false;
      wireless.enable = lib.mkForce false;
      modemmanager.enable = lib.mkForce false;
      useDHCP = lib.mkForce false;
      dhcpcd.enable = lib.mkForce false;
    };

    # A headless RDP desktop is owned by cfg.User, never by a console login.
    # Linger starts its user manager at boot, which starts the RDP user units.
    users.users = lib.mkIf (cfg.User != null) {
      "${cfg.User}".linger = true;
    };

    # No physical console or local service discovery belongs in this remote-only
    # guest. Avahi is especially harmful here because the guest shares the
    # host's network namespace and would create a second mDNS responder.
    services = {
      avahi.enable = lib.mkForce false;
      nscd.enable = lib.mkForce false;
    };
    systemd.services = {
      AutoLogin.enable = lib.mkForce false;
      console-getty.enable = lib.mkForce false;
    };
    environment.systemPackages = [ pkgs.gnome-remote-desktop pkgs.openssl ];
    environment.sessionVariables = {
      XDG_SESSION_TYPE = "wayland";
      NIXOS_OZONE_WL = "1";
      OZONE_PLATFORM = "wayland";
      ELECTRON_OZONE_PLATFORM_HINT = "wayland";
      GDK_BACKEND = "wayland";
      QT_QPA_PLATFORM = "wayland";
      SDL_VIDEODRIVER = "wayland";
      MOZ_ENABLE_WAYLAND = "1";
    };
    systemd.user.services.hypersw-gnome-rdp-headless-setup = {
      description = "Configure GNOME headless RDP for this managed container";
      wantedBy = [ "default.target" ];
      before = [ "gnome-remote-desktop-headless.service" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        set -euo pipefail
        umask 077
        state="$HOME/.local/state/hypersw/gnome-rdp"
        credentials="$state/credentials"
        certificate="$state/tls.crt"
        key="$state/tls.key"
        mkdir -p "$state"
        if [ -n ${lib.escapeShellArg cfg.Gui.RdpCredentialsFile} ]; then
          install -m 600 ${lib.escapeShellArg cfg.Gui.RdpCredentialsFile} "$credentials"
        elif ${if cfg.Gui.RdpPassword == null then "false" else "true"}; then
          printf '%s\n%s\n' ${lib.escapeShellArg cfg.Gui.RdpUsername} ${lib.escapeShellArg (if cfg.Gui.RdpPassword == null then "" else cfg.Gui.RdpPassword)} > "$credentials"
        elif [ ! -s "$credentials" ]; then
          password="$(${pkgs.openssl}/bin/openssl rand -base64 33 | tr -d '\n')"
          printf '%s\n%s\n' ${lib.escapeShellArg cfg.Gui.RdpUsername} "$password" > "$credentials"
        fi
        username=$(sed -n '1p' "$credentials")
        password=$(sed -n '2p' "$credentials")
        [ -n "$username" ] || { echo "GNOME RDP credentials need a username" >&2; exit 1; }
        if [ ! -s "$key" ] || [ ! -s "$certificate" ]; then
          ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:3072 -nodes -keyout "$key" -out "$certificate" -days 3650 -subj ${lib.escapeShellArg "/CN=${cfg.Name}-gnome-rdp"}
        fi
        grdctl --headless rdp set-port ${toString cfg.Gui.RdpPort}
        grdctl --headless rdp disable-port-negotiation
        grdctl --headless rdp set-auth-methods credentials
        grdctl --headless rdp set-credentials "$username" "$password"
        grdctl --headless rdp set-tls-key "$key"
        grdctl --headless rdp set-tls-cert "$certificate"
        grdctl --headless rdp enable
      '';
    };
    # Upstream starts this from gnome-session.target. Managed containers have no
    # local display manager, so retain it from the long-lived user manager.
    systemd.user.services.gnome-remote-desktop-headless = {
      wantedBy = lib.mkForce [ "default.target" ];
      requires = [ "hypersw-gnome-rdp-headless-setup.service" ];
      after = [ "hypersw-gnome-rdp-headless-setup.service" ];
      # GNOME Remote Desktop has no listen-address setting. cgroup network BPF
      # makes this all-interface listener usable only from the guest loopback;
      # reach it from outside through an SSH tunnel or VPN endpoint on the host.
      serviceConfig = {
        IPAddressDeny = "any";
        IPAddressAllow = [ "127.0.0.0/8" "::1/128" ];
      };
    };
  };
}