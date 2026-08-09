{
  Enable ? true,
  RootDir ? "/var/lib/nixos-containers",
  HostGraphicalUser ? {},
  HostGpu ? {},
  GcRoots ? {},
  HostControl ? {},
  Instances ? {},
}:
{ lib, pkgs, ... }:
let
  guiModes = [ "None" "SharedX11" "SharedWayland" "IsolatedWayland" "IsolatedRdpWayland" "IsolatedGnomeRdp" "IsolatedKdeRdp" ];
  buildModes = [ "HostEvaluated" "FlakePath" ];
  rebuildModes = [ "switch" "test" "boot" ];

  hostGraphicalUser = {
    Name = null;
    Uid = null;
    RuntimeDir = null;
    WaylandDisplay = null;
    XauthKeysDir = null;
  } // HostGraphicalUser;

  hostGpu = {
    MesaDriverName = null;
    BindMounts = {};
    AllowedDevices = [];
  } // HostGpu;

  gcRoots = {
    Enable = true;
    MirrorDir = "/nix/var/nix/gcroots/hypersw/containers";
  } // GcRoots;

  hostControl = {
    StateDir = "/var/lib/hypersw/managed-containers";
  } // HostControl;

  # Host/guest bridge names. These values are constants of the protocol between
  # HostSide and GuestSide: the host bind-mounts them under HostBridgeDir, and
  # guest modules either consume them there directly or link them into
  # XDG_RUNTIME_DIR where desktop protocols require that location.
  unitName = name: "container@${name}";
  registrationRepairUnitName = name: "hypersw-managed-container-registration-repair-${name}";
  containerBindMountDir = "/run/ContainerBindMounts";
  pipeWireSocketName = "pipewire-0";
  pulseBridgeSocketName = "pulse_native";
  pulseHostSocket = "pulse/native";
  guestBootRequestDir = "/run/ContainerHostControl/boot-requests";
  # This is deliberately larger than GuestSide's two-minute system-manager
  # timeout, so nspawn does not preempt the guest's own orderly shutdown.
  managedContainerStopTimeout = "3min";

  stateDir = name: "${hostControl.StateDir}/${name}";
  bootSlot = name: "${stateDir name}/current-system";
  bootRequestDir = name: "${stateDir name}/boot-requests";

  sharedGuiDefault = mode: mode == "SharedX11" || mode == "SharedWayland";

  instanceDefaults = name: {
    Enable = false;
    User = name;
    UserUid = null;
    HostWaylandSocketAccessUid = null;
    StateVersion = null;
    AutoStart = false;
    BuildMode = "HostEvaluated";
    Path = null;
    Gui = {};
    Tpm = {};
    Fuse = {};
    Copybox = {};
    Konsole = {};
    SelfSwitch = {};
    MemoryMax = null;
    MemoryHigh = null;
    MemorySwapMax = null;
    AllowedCPUs = null;
    TasksMax = null;
    LimitNOFILE = null;
    ExtraBindMounts = {};
    ExtraAllowedDevices = [];
  };

  normalizeGui = name: rawGui:
    let
      gui = {
        Mode = "None";
        Gpu = null;
        Audio = null;
        Clipboard = null;
        FontPackages = [];
        HostWaylandSocketName = "wayland-host";
        IsolatedWaylandSocketName = "wayland-isolated";
        RdpListenAddress = "127.0.0.1";
        RdpPort = 33398;
        RdpFallbackVirtualMonitor = "1920x1080@1";
        # KRdp's default is intentionally biased toward readable desktop text.
        # Clients may lower it explicitly when bandwidth matters more.
        RdpQuality = 100;
        RdpUsername = name;
        RdpCredentialsFile = "";
        RdpPassword = null;
      } // rawGui;
    in
    gui // {
      Gpu = if gui.Gpu == null then sharedGuiDefault gui.Mode else gui.Gpu;
      Audio = if gui.Audio == null then sharedGuiDefault gui.Mode else gui.Audio;
      Clipboard = if gui.Clipboard == null then sharedGuiDefault gui.Mode else gui.Clipboard;
    };

  normalizeInstance = name: raw:
    let
      decl = instanceDefaults name // raw;
    in
    decl // {
      Gui = normalizeGui name decl.Gui;
      Tpm = { Enable = false; } // decl.Tpm;
      Fuse = { Enable = false; } // decl.Fuse;
      Copybox = {
        Enable = false;
        Name = "Copybox";
        HostPath = null;
        HostSubdir = null;
      } // decl.Copybox;
      Konsole = {
        Enable = false;
        WorkspaceId = 1;
      } // decl.Konsole;
      SelfSwitch = {
        Enable = true;
        Flake = "/etc/nixos";
        ConfigName = name;
        DefaultMode = "switch";
      } // decl.SelfSwitch;
    };

  declarations = lib.mapAttrs normalizeInstance Instances;
  enabledDeclarations = lib.filterAttrs (_: decl: Enable && decl.Enable) declarations;

  needsAny = predicate: lib.any predicate (lib.attrValues enabledDeclarations);

  validateEnum = optionName: allowed: value: {
    assertion = lib.elem value allowed;
    message = "${optionName} must be one of: ${lib.concatStringsSep ", " allowed}.";
  };

  instanceAssertions =
    lib.flatten
      (
        lib.mapAttrsToList
          (name: decl: [
            (validateEnum "Managed container ${name} BuildMode" buildModes decl.BuildMode)
            (validateEnum "Managed container ${name} Gui.Mode" guiModes decl.Gui.Mode)
            (validateEnum "Managed container ${name} SelfSwitch.DefaultMode" rebuildModes decl.SelfSwitch.DefaultMode)
            {
              assertion = !(decl.BuildMode == "FlakePath" && decl.Path == null) || decl.SelfSwitch.Enable;
              message = "Managed FlakePath container ${name} needs SelfSwitch.Enable when Path is null, so boot-mode rebuilds can stage the host boot slot.";
            }
            {
              assertion = !(decl.Copybox.Enable) || decl.Copybox.HostPath != null;
              message = "Managed container ${name} has Copybox.Enable, but Copybox.HostPath is not set by the machine config.";
            }
            {
              assertion =
                !(decl.Copybox.Enable && decl.Copybox.HostSubdir != null)
                || (
                  !(lib.hasPrefix "/" decl.Copybox.HostSubdir)
                  && !(lib.hasInfix "/../" "/${decl.Copybox.HostSubdir}/")
                );
              message = "Managed container ${name} Copybox.HostSubdir must be a relative path without '..' components.";
            }
            {
              assertion =
                !(decl.Gui.Mode == "SharedWayland" || decl.Gui.Mode == "IsolatedWayland")
                || decl.HostWaylandSocketAccessUid != null;
              message = "Managed Wayland container ${name} requires HostWaylandSocketAccessUid, the host-visible UID allowed to connect to the host compositor socket.";
            }
          ])
          enabledDeclarations
      );

  hostAssertions = [
    {
      assertion = !needsAny (decl: decl.Gui.Mode == "SharedX11") || hostGraphicalUser.XauthKeysDir != null;
      message = "Managed SharedX11 containers require HostGraphicalUser.XauthKeysDir.";
    }
    {
      assertion =
        !needsAny
          (decl: decl.Gui.Audio || decl.Gui.Mode == "SharedWayland" || decl.Gui.Mode == "IsolatedWayland")
        || hostGraphicalUser.RuntimeDir != null;
      message = "Managed containers using Wayland or host audio require HostGraphicalUser.RuntimeDir.";
    }
    {
      assertion =
        !needsAny (decl: decl.Gui.Mode == "SharedWayland" || decl.Gui.Mode == "IsolatedWayland")
        || hostGraphicalUser.WaylandDisplay != null;
      message = "Managed Wayland containers require HostGraphicalUser.WaylandDisplay.";
    }
    {
      assertion = !needsAny (decl: decl.Gui.Gpu) || (hostGpu.BindMounts != {} && hostGpu.AllowedDevices != []);
      message = "Managed containers with Gui.Gpu require HostGpu.BindMounts and HostGpu.AllowedDevices.";
    }
    {
      assertion = !needsAny (decl: decl.Gui.Mode == "SharedX11") || hostGpu.MesaDriverName != null;
      message = "Managed SharedX11 containers require HostGpu.MesaDriverName; use \"\" to explicitly avoid Mesa driver environment variables.";
    }
  ];

  serviceConfigFor = decl:
    (lib.filterAttrs (_: v: v != null) {
      MemoryMax = decl.MemoryMax;
      MemoryHigh = decl.MemoryHigh;
      MemorySwapMax = decl.MemorySwapMax;
      AllowedCPUs = decl.AllowedCPUs;
      TasksMax = decl.TasksMax;
      LimitNOFILE = decl.LimitNOFILE;
    }) // {
      # Bound a managed guest's orderly shutdown. KillMode=mixed remains the
      # NixOS nspawn default; this is a host-unit deadline, not a replacement
      # for the stale-registration guard below.
      TimeoutStopSec = managedContainerStopTimeout;
    };

  mkContainer = name: decl:
    let
      hasGui = decl.Gui.Mode != "None";
      needsX11 = decl.Gui.Mode == "SharedX11";
      needsHostWayland = decl.Gui.Mode == "SharedWayland" || decl.Gui.Mode == "IsolatedWayland";
      hostWaylandSocket = "${hostGraphicalUser.RuntimeDir}/${hostGraphicalUser.WaylandDisplay}";
      copyboxHostPath =
        if decl.Copybox.HostSubdir == null
        then decl.Copybox.HostPath
        else "${decl.Copybox.HostPath}/${decl.Copybox.HostSubdir}";
      waylandAclUnit = "hypersw-managed-container-wayland-acl-${name}";
      waylandSocketAccessUid =
        if decl.HostWaylandSocketAccessUid != null
        then decl.HostWaylandSocketAccessUid
        else 0;
      containerPath =
        if decl.Path != null
        then decl.Path
        else bootSlot name;
      serviceConfig = serviceConfigFor decl;
    in
    lib.mkMerge [
      # Applies to this one container instance. This section declares the nspawn
      # container and every explicit host/container boundary crossing for it.
      {
        containers.${name} = {
          autoStart = decl.AutoStart;
          ephemeral = false;

          # Guest-side evaluation section. HostEvaluated intentionally keeps the
          # old "host builds the guest from host nixpkgs" shape for disposable
          # parity tests. The managed long-term path is FlakePath below.
          config = lib.mkIf (decl.BuildMode == "HostEvaluated") ({ ... }: {
            imports = [ ./GuestSide ];

            hypersw.containers.UserContainers.Guest = {
              Enable = true;
              Name = name;
              User = decl.User;
              UserUid = decl.UserUid;
              HostBridgeDir = containerBindMountDir;
              StateVersion = decl.StateVersion;
              Gui.Mode = decl.Gui.Mode;
              Gui.Gpu = decl.Gui.Gpu;
              Gui.Audio = decl.Gui.Audio;
              Gui.Clipboard = decl.Gui.Clipboard;
              Gui.MesaDriverName = hostGpu.MesaDriverName;
              Gui.FontPackages = decl.Gui.FontPackages;
              Gui.HostWaylandSocketName = decl.Gui.HostWaylandSocketName;
              Gui.IsolatedWaylandSocketName = decl.Gui.IsolatedWaylandSocketName;
              Gui.RdpListenAddress = decl.Gui.RdpListenAddress;
              Gui.RdpPort = decl.Gui.RdpPort;
              Gui.RdpFallbackVirtualMonitor = decl.Gui.RdpFallbackVirtualMonitor;
              Gui.RdpQuality = decl.Gui.RdpQuality;
              Gui.RdpUsername = decl.Gui.RdpUsername;
              Gui.RdpCredentialsFile = decl.Gui.RdpCredentialsFile;
              Gui.RdpPassword = decl.Gui.RdpPassword;
              Tpm.Enable = decl.Tpm.Enable;
              Fuse.Enable = decl.Fuse.Enable;
              Konsole.Enable = decl.Konsole.Enable;
              Konsole.WorkspaceId = decl.Konsole.WorkspaceId;
              SelfSwitch.Enable = decl.SelfSwitch.Enable;
              SelfSwitch.Flake = decl.SelfSwitch.Flake;
              SelfSwitch.ConfigName = decl.SelfSwitch.ConfigName;
              SelfSwitch.DefaultMode = decl.SelfSwitch.DefaultMode;
              SelfSwitch.HostBootRequestDir = guestBootRequestDir;
            };
          });

          # Prebuilt-system section. In FlakePath mode the host starts an
          # already-built NixOS system closure, so the guest can own its flake
          # inputs and upgrade cadence independently from the host.
          path = lib.mkIf (decl.BuildMode == "FlakePath") containerPath;

          additionalCapabilities = lib.optionals hasGui [ "CAP_IPC_LOCK" ];

          bindMounts =
            lib.optionalAttrs needsX11 {
              "/tmp/.X11-unix" = {
                hostPath = "/tmp/.X11-unix";
                isReadOnly = true;
              };
              "/home/${decl.User}/.Xauth" = {
                hostPath = hostGraphicalUser.XauthKeysDir;
                isReadOnly = false;
              };
            } //
            lib.optionalAttrs needsHostWayland {
              "${containerBindMountDir}/${decl.Gui.HostWaylandSocketName}" = {
                hostPath = "${hostGraphicalUser.RuntimeDir}/${hostGraphicalUser.WaylandDisplay}";
                isReadOnly = false;
              };
            } //
            lib.optionalAttrs decl.Gui.Gpu hostGpu.BindMounts //
            lib.optionalAttrs decl.Gui.Audio {
              "${containerBindMountDir}/${pipeWireSocketName}" = {
                hostPath = "${hostGraphicalUser.RuntimeDir}/${pipeWireSocketName}";
                isReadOnly = false;
              };
              "${containerBindMountDir}/${pulseBridgeSocketName}" = {
                hostPath = "${hostGraphicalUser.RuntimeDir}/${pulseHostSocket}";
                isReadOnly = false;
              };
            } //
            lib.optionalAttrs decl.Tpm.Enable {
              "/dev/tpm0" = {
                hostPath = "/dev/tpm0";
                isReadOnly = false;
              };
              "/dev/tpmrm0" = {
                hostPath = "/dev/tpmrm0";
                isReadOnly = false;
              };
            } //
            lib.optionalAttrs decl.Fuse.Enable {
              "/dev/fuse" = {
                hostPath = "/dev/fuse";
                isReadOnly = false;
              };
            } //
            lib.optionalAttrs decl.Copybox.Enable {
              "/home/${decl.User}/${decl.Copybox.Name}" = {
                hostPath = copyboxHostPath;
                isReadOnly = false;
              };
            } //
            lib.optionalAttrs (decl.BuildMode == "FlakePath" && decl.SelfSwitch.Enable) {
              "${guestBootRequestDir}" = {
                hostPath = bootRequestDir name;
                isReadOnly = false;
              };
            } //
            decl.ExtraBindMounts;

          allowedDevices =
            lib.optionals decl.Gui.Gpu hostGpu.AllowedDevices ++
            lib.optionals decl.Tpm.Enable [
              { modifier = "rw"; node = "/dev/tpm0"; }
              { modifier = "rw"; node = "/dev/tpmrm0"; }
            ] ++
            lib.optionals decl.Fuse.Enable [
              { modifier = "rw"; node = "/dev/fuse"; }
            ] ++
            decl.ExtraAllowedDevices;
        };
      }

      # Applies to this container's host systemd unit only.
      (lib.mkIf (serviceConfig != {}) {
        systemd.services.${unitName name}.serviceConfig = serviceConfig;
      })

      # Applies to this container's host lifecycle only. systemd-machined tracks
      # a container by its guest PID 1. Normally nspawn unregisters it at exit.
      # If guest PID 1 reaches systemd-shutdown but never exits, a later machined
      # restart can restore that stale registration and reject a fresh nspawn
      # registration with the same name. Repair only that exact, known-safe
      # shape before starting this managed container; any broader inconsistency
      # is left untouched and fails loudly for investigation.
      {
        systemd.services.${registrationRepairUnitName name} = {
          description = "Repair stale machine registration for managed container ${name}";
          requiredBy = [ "${unitName name}.service" ];
          before = [ "${unitName name}.service" ];
          after = [ "systemd-machined.service" ];
          requires = [ "systemd-machined.service" ];
          path = [ pkgs.coreutils pkgs.systemd ];
          serviceConfig = {
            Type = "oneshot";
            TimeoutStartSec = "15s";
          };
          script = ''
            set -euo pipefail

            container_name=${lib.escapeShellArg name}
            container_unit=${lib.escapeShellArg "${unitName name}.service"}
            service_leader="$(systemctl show --value --property=MainPID "$container_unit")"
            registered_leader="$(machinectl show --value --property=Leader "$container_name" 2>/dev/null || true)"

            # No existing registration is the normal case.
            case "$registered_leader" in
              ""|"0" ) exit 0 ;;
            esac

            case "$registered_leader" in
              *[!0-9]* )
                echo "Managed container $container_name has an invalid machined leader: $registered_leader" >&2
                exit 1
                ;;
            esac

            # A nonzero supervisor means this is not a stale pre-start state.
            # Do not guess which live process owns a conflicting registration.
            if [ "$service_leader" != "0" ]; then
              if [ "$service_leader" = "$registered_leader" ]; then
                exit 0
              fi

              echo "Managed container $container_name has conflicting live leaders: service=$service_leader machined=$registered_leader" >&2
              exit 1
            fi

            process_comm="$(cat "/proc/$registered_leader/comm" 2>/dev/null || true)"
            process_cgroup="$(cat "/proc/$registered_leader/cgroup" 2>/dev/null || true)"
            expected_cgroup="0::/machine.slice/$container_unit/payload/init.scope (deleted)"

            is_expected_stale_leader() {
              [ "$(cat "/proc/$registered_leader/comm" 2>/dev/null || true)" = "systemd-shutdow" ] \
                && [ "$(cat "/proc/$registered_leader/cgroup" 2>/dev/null || true)" = "$expected_cgroup" ]
            }

            # /proc/<pid>/comm is limited to TASK_COMM_LEN (15 visible bytes),
            # so the 16-byte executable name systemd-shutdown is reported as
            # systemd-shutdow here.
            if [ "$process_comm" != "systemd-shutdow" ] || [ "$process_cgroup" != "$expected_cgroup" ]; then
              echo "Managed container $container_name has an unrecognised stale machine leader $registered_leader; refusing automatic cleanup." >&2
              echo "comm=$process_comm" >&2
              echo "cgroup=$process_cgroup" >&2
              exit 1
            fi

            echo "Removing stale machine registration for $container_name (guest shutdown PID $registered_leader)." >&2
            busctl call org.freedesktop.machine1 \
              /org/freedesktop/machine1 \
              org.freedesktop.machine1.Manager \
              UnregisterMachine s "$container_name"

            # Unregistering can race with the final exit of guest PID 1. Check
            # again before every signal: an ESRCH here is successful cleanup,
            # and a reused PID must never receive a signal from this guard.
            if ! is_expected_stale_leader; then
              exit 0
            fi
            kill -TERM "$registered_leader" 2>/dev/null || true
            for _ in $(seq 1 20); do
              if [ ! -d "/proc/$registered_leader" ]; then
                exit 0
              fi
              sleep 0.1
            done

            if is_expected_stale_leader; then
              echo "Stale guest shutdown PID $registered_leader ignored SIGTERM; sending SIGKILL." >&2
              kill -KILL "$registered_leader" 2>/dev/null || true
            else
              echo "Guest shutdown PID $registered_leader exited after unregistration." >&2
            fi
          '';
        };

        systemd.services.${unitName name} = {
          requires = [ "${registrationRepairUnitName name}.service" ];
          after = [ "${registrationRepairUnitName name}.service" ];
        };
      }

      # Applies to Wayland-backed GUI containers. The host compositor socket is
      # owned by the host graphical user; grant only this container's declared
      # host-visible UID access to that one socket instead of making guest and
      # host user identities identical.
      (lib.mkIf needsHostWayland {
        systemd.services.${waylandAclUnit} = {
          description = "Allow managed container ${name} to connect to the host Wayland socket";
          serviceConfig.Type = "oneshot";
          path = [ pkgs.acl pkgs.coreutils ];
          script = ''
            set -euo pipefail

            socket=${lib.escapeShellArg hostWaylandSocket}
            for attempt in $(seq 1 50); do
              [ -S "$socket" ] && break
              sleep 0.1
            done

            [ -S "$socket" ] || {
              echo "Host Wayland socket for ${name} is not present: $socket" >&2
              exit 1
            }

            setfacl -m u:${toString waylandSocketAccessUid}:rw "$socket"
          '';
        };

        systemd.services.${unitName name} = {
          requires = [ "${waylandAclUnit}.service" ];
          after = [ "${waylandAclUnit}.service" ];
        };
      })

      # Applies to FlakePath managed containers. `container-rebuild boot` in the
      # guest writes the built system path into this inbox; the host validates it
      # and moves the stable boot slot that containers.<name>.path points at.
      (lib.mkIf (decl.BuildMode == "FlakePath" && decl.SelfSwitch.Enable) {
        systemd.tmpfiles.rules = [
          "d ${stateDir name} 0755 root root -"
          "d ${bootRequestDir name} 0775 root root -"
        ];

        systemd.paths."hypersw-managed-container-stage-boot-${name}" = {
          description = "Watch ${name} managed-container boot requests";
          wantedBy = [ "multi-user.target" ];
          pathConfig.DirectoryNotEmpty = bootRequestDir name;
        };

        systemd.services."hypersw-managed-container-stage-boot-${name}" = {
          description = "Stage next boot path for managed container ${name}";
          serviceConfig.Type = "oneshot";
          path = [ pkgs.coreutils pkgs.findutils ];
          script = ''
            set -euo pipefail

            request=${lib.escapeShellArg (bootRequestDir name)}/next-system
            [ -s "$request" ] || exit 0

            system_path=$(head -n 1 "$request")
            case "$system_path" in
              /nix/store/*) ;;
              *)
                echo "Refusing non-store boot path for ${name}: $system_path" >&2
                exit 1
                ;;
            esac

            if [ ! -e "$system_path/init" ] || [ ! -e "$system_path/sw" ]; then
              echo "Refusing path that does not look like a NixOS system: $system_path" >&2
              exit 1
            fi

            mkdir -p ${lib.escapeShellArg (stateDir name)}
            ln -sfn "$system_path" ${lib.escapeShellArg (stateDir name)}/current-system.next
            mv -Tf ${lib.escapeShellArg (stateDir name)}/current-system.next ${lib.escapeShellArg (bootSlot name)}

            ${lib.optionalString gcRoots.Enable ''
              mkdir -p ${lib.escapeShellArg gcRoots.MirrorDir}/${lib.escapeShellArg name}
              ln -sfn "$system_path" ${lib.escapeShellArg gcRoots.MirrorDir}/${lib.escapeShellArg name}/host-boot-current
            ''}

            rm -f "$request"
            find ${lib.escapeShellArg (bootRequestDir name)} -maxdepth 1 -type f -name '*.tmp' -delete
            echo "Managed container ${name} will start next from $system_path"
          '';
        };
      })
    ];

  rootsSyncService = lib.mkIf (Enable && gcRoots.Enable && enabledDeclarations != {}) {
    # Applies to all Managed containers emitted by this factory. This service is
    # the correctness mechanism for a shared host Nix store: host GC may run only
    # after container-native roots are mirrored into host-visible roots.
    systemd.services.hypersw-managed-container-roots-sync = {
      description = "Mirror managed container GC roots into host-visible roots";
      before = [ "nix-gc.service" ];
      requiredBy = [ "nix-gc.service" ];
      serviceConfig.Type = "oneshot";
      path = [ pkgs.coreutils pkgs.findutils ];
      script = ''
        set -euo pipefail

        mirror_base=${lib.escapeShellArg gcRoots.MirrorDir}
        root_base=${lib.escapeShellArg RootDir}
        mkdir -p "$mirror_base"

        sync_container() {
          name="$1"
          container_root="$root_base/$name"
          out="$mirror_base/$name"
          next="$out.next"
          current="$out/current"

          [ -d "$container_root" ] || return 0

          rm -rf "$next"
          mkdir -p "$next"

          roots_file="$next/.roots"
          : > "$roots_file"

          add_root() {
            candidate="$1"
            [ -e "$candidate" ] || return 0
            resolved=$(readlink -f "$candidate" 2>/dev/null || true)
            case "$resolved" in
              /nix/store/*)
                printf '%s\n' "$resolved" >> "$roots_file"
                ;;
              "")
                ;;
              *)
                echo "Ignoring non-store root target for $name: $candidate -> $resolved" >&2
                ;;
            esac
          }

          translate_container_path() {
            p="$1"
            case "$p" in
              /nix/store/*) printf '%s\n' "$p" ;;
              /*) printf '%s\n' "$container_root$p" ;;
              *) printf '%s\n' "$p" ;;
            esac
          }

          scan_link_dir() {
            dir="$1"
            [ -d "$dir" ] || return 0
            while IFS= read -r link; do
              target=$(readlink "$link" || true)
              [ -n "$target" ] || continue
              translated=$(translate_container_path "$target")
              case "$translated" in
                /*) add_root "$translated" ;;
                *) add_root "$(dirname "$link")/$translated" ;;
              esac
            done < <(find "$dir" -type l -print)
          }

          scan_link_dir "$container_root/nix/var/nix/gcroots"
          scan_link_dir "$container_root/nix/var/nix/profiles"

          if [ -d "$container_root/home" ]; then
            while IFS= read -r profile_dir; do
              scan_link_dir "$profile_dir"
            done < <(find "$container_root/home" -path '*/.local/state/nix/profiles' -type d -print)
          fi

          sort -u "$roots_file" > "$roots_file.sorted"
          idx=0
          while IFS= read -r resolved; do
            [ -n "$resolved" ] || continue
            idx=$((idx + 1))
            ln -s "$resolved" "$next/root-$idx"
          done < "$roots_file.sorted"
          rm -f "$roots_file" "$roots_file.sorted"

          mkdir -p "$out"
          old="$out/previous"
          rm -rf "$old"
          [ ! -e "$current" ] || mv "$current" "$old"
          mv "$next" "$current"
          rm -rf "$old"
        }

        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: _: "sync_container ${lib.escapeShellArg name}") enabledDeclarations)}
      '';
    };

    systemd.services.nix-gc = {
      requires = [ "hypersw-managed-container-roots-sync.service" ];
      after = [ "hypersw-managed-container-roots-sync.service" ];
    };
  };
in
lib.mkMerge [
  {
    assertions = hostAssertions ++ instanceAssertions;
  }

  (lib.mkIf Enable (lib.mkMerge (lib.mapAttrsToList mkContainer enabledDeclarations)))

  rootsSyncService
]
