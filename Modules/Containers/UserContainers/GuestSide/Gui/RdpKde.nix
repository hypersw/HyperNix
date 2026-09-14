{ config, lib, pkgs, ... }:
let
  cfg = config.hypersw.containers.UserContainers.Guest;
  waylandDisplay = "wayland-0";
  plasmaShellService = "hypersw-plasmashell.service";
  # A hung graphical client must not hold user@.service, and therefore the
  # whole guest shutdown, for systemd's default 90 seconds.
  managedSessionStopTimeout = "15s";
  # Include the store hash as well as the package name. KWin's KService cache
  # then changes with each patched KWin closure, including a copied KRdp
  # desktop-entry authorization change.
  kwinCacheTag = builtins.baseNameOf (toString pkgs.kdePackages.kwin);
  kwinCacheDirName = "hypersw-kwin-ksycoca-${kwinCacheTag}";
  kwinCacheHome = "%t/${kwinCacheDirName}";
  kwinConfigHome = "%t/hypersw-kde-rdp-config";
  screenLockerConfig = pkgs.writeText "hypersw-kscreenlockerrc" ''
    [Daemon]
    Autolock=false
    Lock=false
    LockOnResume=false
    LockOnStart=false
    RequirePassword=false
  '';
  # KWin uses KService to decide which clients may use its private fake-input
  # and screencast protocols. Index every immutable application source chosen
  # for this guest, but never a user-writable application directory.
  kServiceApplicationsMenu = pkgs.writeText "hypersw-kde-rdp-applications.menu" ''
    <!DOCTYPE Menu PUBLIC "-//freedesktop//DTD Menu 1.0//EN"
      "http://www.freedesktop.org/standards/menu-spec/1.0/menu.dtd">
    <Menu>
      <Name>Applications</Name>
      <AppDir>${config.system.path}/share/applications</AppDir>
      <AppDir>${pkgs.kdePackages.kwin}/share/applications</AppDir>
      <AppDir>${pkgs.kdePackages.krdp}/share/applications</AppDir>
      <AppDir>${pkgs.kdePackages.plasma-workspace}/share/applications</AppDir>
      <Include>
        <All/>
      </Include>
    </Menu>
  '';
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

  # KWin retains its generated menu in a private runtime config directory.
  # Keep that directory visible as an XDG fallback so Plasma can discover the
  # same immutable application set, while applications keep $HOME/.config as
  # their writable configuration location.
  kdeConfigDirs = "${kwinConfigHome}:${lib.makeSearchPath "etc/xdg" [
    pkgs.kdePackages.plasma-workspace
    config.system.path
  ]}";

  # KWin's virtual backend carries both an EGL and a QPainter renderer, and the
  # screencast patch below supports either, so the GPU crossing decides which one
  # this session uses. With a render node the OpenGL renderer composites on the
  # GPU and hands KPipeWire dmabuf frames, which is also what lets the encoder
  # reach VA-API instead of encoding a software composite on the CPU. Without
  # one, QPainter is the only renderer that can start at all.
  kwinRenderBackend = if cfg.Gui.Gpu then "O2" else "QPainter";

  # The two RdpKde modes share every mechanism here and differ only in what
  # they let across the boundary: RdpKdeIsolated crosses nothing and runs pure
  # Wayland, RdpKdeWithDevices crosses host devices and carries an Xwayland
  # server for clients that have no Wayland path. HostSide seeds the crossing
  # flags from the mode and refuses the ones Isolated must not have, so the
  # guest only has to read the flags.
  isRdpKde = (cfg.Gui.Mode == "RdpKdeIsolated") || (cfg.Gui.Mode == "RdpKdeWithDevices");
  hasXwayland = cfg.Gui.Mode == "RdpKdeWithDevices";

  virtualKwinEnvironment = [
    "XDG_SESSION_TYPE=wayland"
    "XDG_CURRENT_DESKTOP=KDE"
    "DESKTOP_SESSION=plasma"
    "XDG_DATA_DIRS=${kdeDataDirs}"
    "XDG_CONFIG_DIRS=${kdeConfigDirs}"
    "KWIN_COMPOSE=${kwinRenderBackend}"
  ];

  # Toolkit selection. Without Xwayland there is no X server to fall back to,
  # so each variable names Wayland alone and an X11-only client fails loudly
  # rather than hunting for a display that does not exist. With Xwayland the
  # same variables become preference lists: Wayland still wins wherever the
  # toolkit supports it, and only a client with no Wayland path lands on X11.
  toolkitPlatformEnvironment =
    if hasXwayland then [
      "QT_QPA_PLATFORM=wayland;xcb"
      "GDK_BACKEND=wayland,x11"
      "SDL_VIDEODRIVER=wayland,x11"
    ] else [
      "QT_QPA_PLATFORM=wayland"
      "GDK_BACKEND=wayland"
      "SDL_VIDEODRIVER=wayland"
    ];

  waylandClientEnvironment = virtualKwinEnvironment ++ toolkitPlatformEnvironment ++ [
    "WAYLAND_DISPLAY=${waylandDisplay}"
    # Chromium and Electron keep their own selector. The ozone hints put them
    # on Wayland in both variants; they fall back on their own if it is absent.
    "MOZ_ENABLE_WAYLAND=1"
    "NIXOS_OZONE_WL=1"
    "OZONE_PLATFORM=wayland"
    "ELECTRON_OZONE_PLATFORM_HINT=wayland"
  ];

  # KWin publishes its Wayland socket, and with --xwayland an X display too.
  # Both have to reach the systemd user manager, because every other unit in
  # this session is started by it and inherits its environment rather than
  # KWin's. Nothing here crosses the container boundary: the X server is this
  # guest's own, unlike PropagatedX11 where DISPLAY names the host's.
  #
  # Its number is not known in advance, because Xwayland takes the first free
  # one. That is safe to discover by looking: /tmp/.X11-unix belongs to this
  # container alone in an Rdp* mode, no host X socket being mounted, so the
  # socket that appears there is the one KWin just started.
  waitForKwinSocket = pkgs.writeShellScript "hypersw-wait-for-kwin-socket" ''
    set -euo pipefail
    socket="$XDG_RUNTIME_DIR/${waylandDisplay}"
    for ((attempt = 0; attempt < 100; attempt += 1)); do
      if [ -S "$socket" ]; then
        export WAYLAND_DISPLAY=${waylandDisplay}
        ${pkgs.systemd}/bin/systemctl --user import-environment WAYLAND_DISPLAY
        ${lib.optionalString hasXwayland ''
          for ((xattempt = 0; xattempt < 100; xattempt += 1)); do
            for xsocket in /tmp/.X11-unix/X*; do
              [ -S "$xsocket" ] || continue
              DISPLAY=":''${xsocket##*/X}"
              export DISPLAY
              ${pkgs.systemd}/bin/systemctl --user import-environment DISPLAY
              exit 0
            done
            ${pkgs.coreutils}/bin/sleep 0.1
          done
          # Xwayland is an accessory here: Wayland clients are unaffected, so
          # report the loss and leave the session running rather than failing
          # KWin and taking the whole desktop down with it.
          echo "Timed out waiting for an Xwayland display; X11 clients will not start" >&2
        ''}
        exit 0
      fi
      ${pkgs.coreutils}/bin/sleep 0.1
    done

    echo "Timed out waiting for the virtual KWin socket: $socket" >&2
    exit 1
  '';

  prepareKdeSessionConfig = pkgs.writeShellScript "hypersw-prepare-kde-rdp-session-config" ''
    set -euo pipefail
    config_dir="$XDG_RUNTIME_DIR/hypersw-kde-rdp-config"
    cache_dir="$XDG_RUNTIME_DIR/${kwinCacheDirName}"
    ${pkgs.coreutils}/bin/install -d -m 700 "$config_dir/menus"
    ${pkgs.coreutils}/bin/install -m 600 ${screenLockerConfig} "$config_dir/kscreenlockerrc"
    ${pkgs.coreutils}/bin/install -m 600 ${kServiceApplicationsMenu} "$config_dir/menus/applications.menu"
    # This directory is unique to the selected immutable KWin closure. Keep
    # it across ordinary KWin restarts; a changed closure selects a new cache.
    ${pkgs.coreutils}/bin/install -d -m 700 "$cache_dir"
  '';
in {
  # KRdp owns an existing Plasma Wayland session.  Unlike GNOME Remote Desktop,
  # its --address option provides a real loopback-only listener.
  config = lib.mkIf (cfg.Enable && isRdpKde) {
    assertions = [
      {
        assertion = cfg.Gui.RdpPassword != "";
        message = "An RdpKde mode cannot use an explicitly empty Gui.RdpPassword: KRdp rejects an empty password after connection. Use null for generated credentials, or provide a nonempty password / credentials file.";
      }
      {
        assertion = cfg.Gui.RdpPort != null;
        message = "An RdpKde mode needs an explicit Gui.RdpPort. There is no default, because guests sharing a network namespace would otherwise all claim the same one.";
      }
    ];

    # KWin is started with --xwayland in the WithDevices mode and needs the
    # server on PATH to exec it. Forced rather than merely set, because Plasma
    # turns this on by default: the Isolated mode promises pure Wayland, so it
    # must not even carry an X server it could be talked into starting.
    programs.xwayland.enable = lib.mkForce hasXwayland;

    # The persistent Plasma/portal session comes from this profile. The KRdp,
    # KWin, and KPipeWire packages below must be one patched package set so
    # KWin authorizes the exact KRdp executable that captures its output.
    nixpkgs.overlays = [ (import ./KRdpOverlay.nix) ];

    services.desktopManager.plasma6.enable = true;
    environment.systemPackages = [
      # Make Kvantum styles available to the managed Plasma 6 guest and its
      # remaining Qt 5 applications, so user-installed KDE themes can apply
      # consistently without adding a VCS client to every guest.
      pkgs.kdePackages.qtstyleplugin-kvantum
      pkgs.libsForQt5.qtstyleplugin-kvantum
    ];
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

    # Same toolkit policy as the session units above, for login shells and
    # anything else that reads the system environment instead of inheriting
    # the user manager's.
    environment.sessionVariables = {
      XDG_SESSION_TYPE = "wayland";
      XDG_CURRENT_DESKTOP = "KDE";
      DESKTOP_SESSION = "plasma";
      NIXOS_OZONE_WL = "1";
      OZONE_PLATFORM = "wayland";
      ELECTRON_OZONE_PLATFORM_HINT = "wayland";
      GDK_BACKEND = if hasXwayland then "wayland,x11" else "wayland";
      QT_QPA_PLATFORM = if hasXwayland then "wayland;xcb" else "wayland";
      SDL_VIDEODRIVER = if hasXwayland then "wayland,x11" else "wayland";
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
        Environment = virtualKwinEnvironment ++ [
          # KWin alone reads the generated authorization menu and no-lock
          # configuration. Desktop applications retain $HOME/.config.
          "XDG_CONFIG_HOME=${kwinConfigHome}"
          "XDG_CACHE_HOME=${kwinCacheHome}"
        ];
        ExecStartPre = prepareKdeSessionConfig;
        ExecStart = "${pkgs.kdePackages.kwin}/bin/kwin_wayland --virtual${lib.optionalString hasXwayland " --xwayland"} --socket ${waylandDisplay}";
        ExecStartPost = waitForKwinSocket;
        Restart = "on-failure";
        RestartSec = 2;
        TimeoutStopSec = managedSessionStopTimeout;
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
        TimeoutStopSec = managedSessionStopTimeout;
      };
      # Desktop files intentionally use bare Exec/TryExec commands. Give the
      # long-lived shell the immutable system profile, not a host or mutable
      # user-profile PATH, so KService and xdg-open resolve guest packages.
      path = [ config.system.path ];
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
        # A previous RdpGnome generation can have enabled this user unit
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
        [ -n "$password" ] || { echo "KRdp credentials need a nonempty password" >&2; exit 1; }
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
        TimeoutStopSec = managedSessionStopTimeout;
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
