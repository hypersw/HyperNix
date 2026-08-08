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
        [ -n "$username" ] || { echo "GNOME RDP credentials need a username" >&2; exit 1; }
        if [ ! -s "$key" ] || [ ! -s "$certificate" ]; then
          ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:3072 -nodes -keyout "$key" -out "$certificate" -days 3650 -subj ${lib.escapeShellArg "/CN=${cfg.Name}-gnome-rdp"}
        fi
        ${pkgs.gnome-remote-desktop}/bin/grdctl --headless rdp set-port ${toString cfg.Gui.RdpPort}
        ${pkgs.gnome-remote-desktop}/bin/grdctl --headless rdp disable-port-negotiation
        ${pkgs.gnome-remote-desktop}/bin/grdctl --headless rdp set-auth-methods credentials
        ${pkgs.gnome-remote-desktop}/bin/grdctl --headless rdp set-credentials "$username" "$password"
        ${pkgs.gnome-remote-desktop}/bin/grdctl --headless rdp set-tls-key "$key"
        ${pkgs.gnome-remote-desktop}/bin/grdctl --headless rdp set-tls-cert "$certificate"
        ${pkgs.gnome-remote-desktop}/bin/grdctl --headless rdp enable
        # grdctl also imperatively enables the user unit under ~/.config.
        # Remove that user-owned symlink: wantedBy below is the declarative,
        # generation-retractable owner of this unit's lifecycle.
        ${pkgs.systemd}/bin/systemctl --user disable gnome-remote-desktop-headless.service || true
      '';
    };
    # GNOME RDP binds a wildcard socket and offers no listen-address setting.
    # The loopback-only cgroup policy below safely rejects that bind, which means
    # this mode cannot currently expose an RDP port. Keep the explicit warning
    # visible in the lingered user manager instead of failing silently.
    systemd.user.services.hypersw-gnome-rdp-bind-warning = {
      description = "Explain the IsolatedGnomeRdp loopback bind limitation";
      wantedBy = [ "default.target" ];
      after = [ "gnome-remote-desktop-headless.service" ];
      serviceConfig.Type = "oneshot";
      script = ''
        echo "WARNING: IsolatedGnomeRdp is prevented from opening its RDP port by its loopback-only network policy." >&2
        echo "GNOME Remote Desktop binds a wildcard address and has no listen-address setting." >&2
        echo "Use IsolatedKdeRdp for an actual localhost-only listener, or explicitly change this mode's network policy." >&2
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