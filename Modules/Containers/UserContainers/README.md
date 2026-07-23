# User Containers

These modules define long-lived NixOS user environments built with
`systemd-nspawn` / NixOS declarative containers.

The primary goal is workspace partitioning, not Flatpak-style single-app
sandboxing. The host should stay mostly free of user-specific state: browser
profiles, mail accounts, development tools, credentials, editor settings,
package profiles, and similar daily-use state live inside the relevant
container instead.

A container such as `work` or `home` is therefore closer to a small personal OS
environment than to an application sandbox. Each container has its own users,
home directory, Nix profiles, services, browser accounts, mail client state,
D-Bus session, keyring, portals, and application settings.

The boundary is intentionally porous where daily ergonomics need it. Host
resources are shared explicitly: display integration, clipboard, selected
folders such as Copybox, audio, GPU devices, TPM devices, or other host devices.
Those crossings are declared on the host side and should be visible in the
container declaration rather than hidden inside guest configuration.

The host and containers do not share a session bus. Container desktop services
use the container's own D-Bus and portal stack, avoiding accidental coupling
with host user services and keeping accounts/settings independent.

## Families

`OldSchool` containers are the existing host-evaluated NixOS containers used by
older machine configs. They should remain untouched until a replacement managed
container has been proven end to end.

`Managed` containers are intended to behave more like small hosts. The host owns
the container boundary: rootfs location, bind mounts, devices, capabilities,
resource limits, and graphical/audio/device crossings. The guest owns its own
NixOS configuration, flake inputs, generations, and in-container rebuilds.

## GUI Modes

`SharedX11` is the current production behavior. The container receives the host
X11 socket and Xauth material. Apps render directly through the host X server.
This mode is convenience-oriented and should retain existing behavior while the
new path is developed.

`SharedWayland` is the planned direct Wayland equivalent. Container apps receive
access to the host Wayland compositor socket, similar in spirit to a Flatpak
with Wayland socket access, but without sharing host settings or session bus.

`IsolatedWayland` is the planned isolated GUI mode. Container apps connect only
to a nested compositor. The nested compositor is the only client of the host
compositor. Optional resources such as GPU, audio, clipboard, and shared folders
should be enabled explicitly.

`IsolatedGnomeRdp` is a remote-only Wayland desktop. GNOME Remote Desktop retains an independent headless GNOME/Mutter session inside the container; it does not mount the host display or Wayland socket. It uses Mutter virtual monitors, PipeWire, libei and FreeRDP, so the RDP client determines virtual display size when connecting. TLS material and credentials persist in the guest home directory. Upstream GNOME RDP has a port setting but no listen-address setting, so this mode cannot provide a self-contained loopback-only bind.

`IsolatedKdeRdp` is a remote-only Plasma Wayland desktop. A lingering user manager starts `startplasma-wayland`, then runs KRdp against that persistent session. KRdp supports `--address`, so the managed server binds `Gui.RdpListenAddress` (localhost by default) directly; it does not mount a host display or Wayland socket. TLS and RDP credentials persist in the guest home directory.

`None` means no GUI integration.

For shared GUI modes, capabilities default toward convenience and can be disabled
when unwanted. For isolated GUI modes, capabilities default to off and must be
enabled deliberately.

## GC Roots

Managed containers share the host Nix store. Host garbage collection must
therefore treat container-native persistent roots as part of the host root set.

The host-side root mirror is the correctness mechanism. Before managed host GC
is allowed to collect, the mirror service scans each managed container's native
GC roots and profiles, translates container-local paths to host-visible paths,
resolves them to `/nix/store/...`, and atomically publishes direct host GC roots.

Host `nix-gc.service` must require and run after this mirror service. If the
mirror fails, GC must not run.

This is not a strong VM security boundary. Containers share the host kernel, and
any bind-mounted socket or device is an explicit trust decision. The design goal
is clean partitioning of user environments with understandable, declarative
host-resource sharing.

## Managed Rebuild Lifecycle

Managed containers have three rebuild modes, mirroring ordinary NixOS language
but adapted to the host/container split:

- `switch`: run `nixos-rebuild switch` inside the container. This changes the
  running guest system immediately, without changing what host path will be used
  next time the container starts.
- `test`: run `nixos-rebuild test` inside the container. This is useful for
  trying service/package changes without installing a new generation as the
  default profile.
- `boot`: build the container's flake, then ask the host to use the resulting
  `/nix/store/...-nixos-system-...` path the next time this container starts.
  The guest writes a request into a bind-mounted host-control inbox. The host
  validates the store path and atomically repoints the container's stable boot
  slot, which is what `containers.<name>.path` references in `FlakePath` mode.

The normal unattended update path should reuse
`hypersw.services.auto-rebuild-on-push`: a push updates the local flake lock via
the existing checker/trigger mechanism, and the activation command runs
`container-rebuild <mode>` instead of ordinary host `nixos-rebuild switch`.
Manual acceleration is the same as on physical hosts: start the rebuild service
directly rather than waiting for the next checker tick.

Future work: managed containers should get the same secrets and monitoring
story as flaked physical hosts. In practice that means SOPS wiring for
container-local secrets and Telegram alert/log forwarding for failed rebuilds
and service failures.
