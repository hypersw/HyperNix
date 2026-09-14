{ config, lib, pkgs, ... }:
let
  cfg = config.hypersw.containers.UserContainers.Guest;
in
{
  imports = [
    ../../../Git/SshAskpassCredentialHelper
    ./Base.nix
    ./SelfSwitch.nix
    ./Tpm.nix
    ./Konsole.nix
    ./Gui/Common.nix
    ./Gui/SharedX11.nix
    ./Gui/SharedWayland.nix
    ./Gui/IsolatedWayland.nix
    ./Gui/IsolatedRdpWayland.nix
    ./Gui/IsolatedGnomeRdp.nix
    ./Gui/IsolatedKdeRdp.nix
  ];

  options.hypersw.containers.UserContainers.Guest = {
    Enable = lib.mkEnableOption "guest-side HyperNix user-container config.";
    Name = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName or "container";
    };
    User = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    UserUid = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = ''
        Optional numeric UID for the primary guest user. This is kept
        independent from the host graphical user, but HostSide may need
        the host-visible value to grant ACL access to selected sockets.
      '';
    };
    HostBridgeDir = lib.mkOption {
      type = lib.types.str;
      default = "/run/ContainerBindMounts";
      description = ''
        Directory inside the guest where host-side sockets/devices that
        are not meant to look native are mounted. Guest services may
        link selected entries into XDG_RUNTIME_DIR when client
        conventions require that location.
      '';
    };
    StateVersion = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional system.stateVersion for host-evaluated/bootstrap guest configs.";
    };

    Gui = {
      Mode = lib.mkOption {
        type = lib.types.enum [ "None" "SharedX11" "SharedWayland" "IsolatedWayland" "IsolatedRdpWayland" "IsolatedGnomeRdp" "IsolatedKdeRdp" ];
        default = "None";
      };
      Gpu = lib.mkOption { type = lib.types.bool; default = false; };
      Audio = lib.mkOption { type = lib.types.bool; default = false; };
      Clipboard = lib.mkOption { type = lib.types.bool; default = false; };
      MesaDriverName = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          Explicit Mesa/libva driver override. Empty string means do
          not set LIBVA_DRIVER_NAME or MESA_LOADER_DRIVER_OVERRIDE.
        '';
      };
      HostWaylandSocketName = lib.mkOption {
        type = lib.types.str;
        default = "wayland-host";
        description = ''
          Guest-visible socket name for the host compositor under
          XDG_RUNTIME_DIR. The host bind mount provides the same
          basename under /run/ContainerBindMounts; guest services link
          it into XDG_RUNTIME_DIR because Wayland clients look there
          when resolving WAYLAND_DISPLAY.
        '';
      };
      IsolatedWaylandSocketName = lib.mkOption {
        type = lib.types.str;
        default = "wayland-isolated";
        description = ''
          Guest-visible socket name produced by the nested compositor.
          In IsolatedWayland mode, normal apps use this socket while
          only the compositor uses HostWaylandSocketName.
        '';
      };
      RdpListenAddress = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Address where an isolated RDP GUI mode exposes its RDP listener.";
      };
      RdpPort = lib.mkOption {
        type = lib.types.port;
        default = 33398;
        description = "TCP port where an isolated RDP GUI mode exposes its RDP listener.";
      };
      RdpUsername = lib.mkOption {
        type = lib.types.str;
        default = cfg.User or "container";
        description = "RDP username for generated isolated RDP credentials.";
      };
      RdpCredentialsFile = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Optional guest file with RDP username then password, one per line.";
      };
      RdpPassword = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional direct RDP password override; an empty string is intentional.";
      };
      RdpFallbackVirtualMonitor = lib.mkOption {
        type = lib.types.str;
        default = "1920x1080@1";
        description = ''
          Initial IsolatedKdeRdp virtual-monitor geometry used only when an
          RDP client does not report a valid desktop size and scale.
        '';
      };
      RdpQuality = lib.mkOption {
        type = lib.types.ints.between 0 100;
        default = 100;
        description = "KRdp video quality from 0 through 100; defaults to text-oriented maximum quality.";
      };
      FontPackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
      };
    };

    Tpm.Enable = lib.mkEnableOption "TPM support inside this container.";
    Fuse.Enable = lib.mkEnableOption "FUSE support inside this container.";
    NixLd.Enable = lib.mkEnableOption ''
      nix-ld, so unpatched binaries can run in this container. The loader
      only: which libraries a program finds through it belongs to the user,
      not to the container
    '';

    Konsole = {
      Enable = lib.mkEnableOption "auto-start Konsole.";
      WorkspaceId = lib.mkOption {
        type = lib.types.int;
        default = 1;
      };
    };

    SelfSwitch = {
      Enable = lib.mkEnableOption "restricted in-container rebuild handles.";
      Flake = lib.mkOption {
        type = lib.types.str;
        default = "/etc/nixos";
      };
      ConfigName = lib.mkOption {
        type = lib.types.str;
        default = cfg.Name;
      };
      DefaultMode = lib.mkOption {
        type = lib.types.enum [ "switch" "test" "boot" ];
        default = "switch";
      };
      HostBootRequestDir = lib.mkOption {
        type = lib.types.str;
        default = "/run/ContainerHostControl/boot-requests";
        description = ''
          Host-bind-mounted inbox where `container-rebuild boot` writes
          the built system path for the host to stage as the next
          container start path.
        '';
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.Enable && cfg.Fuse.Enable) {
      # HostSide's matching Fuse.Enable exposes /dev/fuse. This guest-side half
      # supplies the setuid fusermount/fusermount3 wrappers.
      programs.fuse.enable = true;
    })

    (lib.mkIf (cfg.Enable && cfg.NixLd.Enable) {
      # Unlike Tpm and Fuse this crosses nothing from the host, so there is no
      # device to bind and the HostSide half is just the declaration flag.
      #
      # It has to be system configuration all the same, because nix-ld works by
      # owning the ELF interpreter path that unpatched binaries have baked in
      # (/lib64/ld-linux-x86-64.so.2, via environment.ldso). Only the system
      # can place a file there, so the mechanism cannot be turned on ad hoc
      # from a shell. What a program then finds through it is a plain
      # environment variable, and that half is free to be per-user or
      # per-shell.
      #
      # TODO: temporary. Once this container evaluates its own configuration,
      # its flake declares nix-ld and this host-side flag goes away.
      programs.nix-ld.enable = true;

      # The loader, and deliberately nothing to load. nix-ld's own module body
      # defines a stock list of common libraries, which is a definition rather
      # than an option default, so emptying it takes mkForce. Left in place it
      # would put those libraries on NIX_LD_LIBRARY_PATH for every process in
      # the container that goes through the loader, which is the leak this
      # split exists to avoid: enabling the mechanism must not also decide what
      # it resolves. The user's home-manager profile supplies the list.
      programs.nix-ld.libraries = lib.mkForce [ ];
    })
  ];
}
