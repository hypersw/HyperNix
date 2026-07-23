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
        description = "Address where IsolatedRdpWayland exposes its RDP listener.";
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
      FontPackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
      };
    };

    Tpm.Enable = lib.mkEnableOption "TPM support inside this container.";

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
}
