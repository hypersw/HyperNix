{ config, lib, pkgs, ... }:
let
  cfg = config.hypersw.containers.UserContainers.Guest;
  waylandDisplay = "wayland-0";
  plasmaShellService = "hypersw-plasmashell.service";
  rdpOutputLifecycle = import ./RdpOutputLifecycle.nix {
    inherit pkgs;
    PlasmaShellService = plasmaShellService;
  };

  # KWin consults XDG_DATA_DIRS to authorize KRdp's private Wayland protocols.
  # The patched KWin output contains the desktop entry from the exact patched
  # KRdp output, so both locations deliberately appear here.
  kdeDataDirs = lib.makeSearchPath "share" [
    pkgs.kdePackages.kwin
    pkgs.kdePackages.krdp
    pkgs.kdePackages.plasma-workspace
  ] + ":/run/current-system/sw/share";

  virtualKwinEnvironment = [
    "XDG_SESSION_TYPE=wayland"
    "XDG_CURRENT_DESKTOP=KDE"
    "DESKTOP_SESSION=plasma"
    "XDG_DATA_DIRS=${kdeDataDirs}"
    "KWIN_COMPOSE=QPainter"
  ];

  waylandClientEnvironment = virtualKwinEnvironment ++ [
    "WAYLAND_DISPLAY=${waylandDisplay}"
    "QT_QPA_PLATFORM=wayland"
    "GDK_BACKEND=wayland"
    "SDL_VIDEODRIVER=wayland"
    "MOZ_ENABLE_WAYLAND=1"
    "NIXOS_OZONE_WL=1"
    "OZONE_PLATFORM=wayland"
    "ELECTRON_OZONE_PLATFORM_HINT=wayland"
  ];

  waitForKwinSocket = pkgs.writeShellScript "hypersw-wait-for-kwin-socket" ''
    set -euo pipefail
    socket="$XDG_RUNTIME_DIR/${waylandDisplay}"
    for ((attempt = 0; attempt < 100; attempt += 1)); do
      if [ -S "$socket" ]; then
        export WAYLAND_DISPLAY=${waylandDisplay}
        ${pkgs.systemd}/bin/systemctl --user import-environment WAYLAND_DISPLAY
        exit 0
      fi
      ${pkgs.coreutils}/bin/sleep 0.1
    done

    echo "Timed out waiting for the virtual KWin socket: $socket" >&2
    exit 1
  '';
in {
  # KRdp owns an existing Plasma Wayland session.  Unlike GNOME Remote Desktop,
  # its --address option provides a real loopback-only listener.
  config = lib.mkIf (cfg.Enable && cfg.Gui.Mode == "IsolatedKdeRdp") {
    # The persistent Plasma/portal session comes from this profile. The KRdp,
    # KWin, and KPipeWire packages below must be one patched package set so
    # KWin authorizes the exact KRdp executable that captures its output.
    nixpkgs.overlays = [ (import ./KRdpOverlay.nix) ];

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

    # This is deliberately an explicit KWin invocation, rather than
    # startplasma-wayland: the latter starts KWin with --xwayland and cannot
    # create the Virtual-0 bootstrap output needed before KRdp negotiates its
    # first Virtual-RDP-* output.
    systemd.user.services.hypersw-kwin-virtual = {
      description = "Persistent virtual KWin session for managed KRdp";
      wantedBy = [ "default.target" ];
      after = [ "dbus.service" "pipewire.service" ];
      serviceConfig = {
        Type = "simple";
        Environment = virtualKwinEnvironment;
        ExecStart = "${pkgs.kdePackages.kwin}/bin/kwin_wayland --virtual --socket ${waylandDisplay}";
        ExecStartPost = waitForKwinSocket;
        Restart = "on-failure";
        RestartSec = 2;
      };
    };

    # Keep the small desktop shell separate from the compositor. KRdp only
    # needs the virtual KWin session to listen; plasmashell supplies the panel
    # and window-management UI when it becomes available.
    systemd.user.services.hypersw-plasmashell = {
      description = "Plasma shell for the managed virtual KWin session";
      wantedBy = [ "default.target" ];
      requires = [ "hypersw-kwin-virtual.service" ];
      after = [ "hypersw-kwin-virtual.service" ];
      serviceConfig = {
        Type = "simple";
        Environment = waylandClientEnvironment;
        ExecStart = "${pkgs.kdePackages.plasma-workspace}/bin/plasmashell --no-respawn";
        Restart = "on-failure";
        RestartSec = 2;
      };
    };

    systemd.user.services.hypersw-kde-rdp-setup = {
      description = "Configure KRdp credentials and TLS for this managed container";
      wantedBy = [ "default.target" ];
      before = [ "app-org.kde.krdpserver.service" ];
      after = [ "dbus.service" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        set -euo pipefail
        umask 077
        state="$HOME/.local/state/hypersw/kde-rdp"
        credentials="$state/credentials"
        certificate="$state/tls.crt"
        key="$state/tls.key"
        # A previous IsolatedGnomeRdp generation can have enabled this user unit
        # persistently through grdctl. It is invalid in the KRdp mode and must
        # not survive a managed mode switch.
        ${pkgs.systemd}/bin/systemctl --user disable --now gnome-remote-desktop-headless.service || true
        # A remote-only session cannot answer the portal's approval dialog.  KDE
        # identifies a systemd-managed host app from its unit name; authorize that
        # stable app-id before KRdp asks the Remote Desktop portal for the virtual
        # output and input injection.
        ${pkgs.flatpak}/bin/flatpak permission-set kde-authorized remote-desktop org.kde.krdpserver yes
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

    systemd.user.services."app-org.kde.krdpserver" = {
      description = "KRdp server for the managed Plasma Wayland session";
      wantedBy = [ "default.target" ];
      # KRdp's --plasma backend uses the explicit virtual KWin session below.
      # Portal services are deliberately not dependencies: without a physical
      # desktop their settings backend can time out before KRdp opens TCP.
      requires = [
        "hypersw-kde-rdp-setup.service"
        "hypersw-kwin-virtual.service"
      ];
      after = [
        "hypersw-kde-rdp-setup.service"
        "hypersw-kwin-virtual.service"
      ];
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = 2;
        Environment = waylandClientEnvironment ++ [
          "KRDP_LIFECYCLE_HANDLER=${rdpOutputLifecycle}/bin/hypersw-rdp-output-lifecycle"
        ];
      };
      script = ''
        set -euo pipefail
        if [ ! -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; then
          echo "Virtual KWin socket is unavailable: $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" >&2
          exit 1
        fi
        state="$HOME/.local/state/hypersw/kde-rdp"
        username=$(${pkgs.gnused}/bin/sed -n '1p' "$state/credentials")
        password=$(${pkgs.gnused}/bin/sed -n '2p' "$state/credentials")
        # This is a remote-only container: no DRM/physical output exists for
        # KRdp's ordinary Plasma capture mode. Ask KWin to create the first
        # output, then KRdp can capture it and open its TCP listener. This is
        # only the fallback. The patched server replaces it with the first
        # RDP client's reported dimensions and desktop scale when available.
        exec ${pkgs.kdePackages.krdp}/bin/krdpserver \
          --plasma \
          --virtual-monitor ${lib.escapeShellArg cfg.Gui.RdpFallbackVirtualMonitor} \
          --address ${lib.escapeShellArg cfg.Gui.RdpListenAddress} \
          --port ${toString cfg.Gui.RdpPort} \
          --quality ${toString cfg.Gui.RdpQuality} \
          --username "$username" \
          --password "$password" \
          --certificate "$state/tls.crt" \
          --certificate-key "$state/tls.key"
      '';
    };
  };
}
