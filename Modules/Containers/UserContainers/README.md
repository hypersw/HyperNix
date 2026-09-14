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

The mode list is a catalogue of configurations that are intended and have been
run, not a grammar to compose new names from. Two containers wanting the same
display architecture with different host access are two entries here, so that
every name in the enum stands for something someone has actually built.

A name reads in two or three parts. The first says how the guest gets a
display: `Propagated*` is the host's own display server reaching into the
container, `Rdp*` is a display server the guest runs itself and exports over
RDP. The middle part, where present, names the stack that server comes from.
A trailing `Isolated` or `WithDevices` appears only where both halves exist and
have been tried, and there it is enforced rather than merely defaulted.

`PropagatedX11` is the long-standing production behaviour. The container
receives the host X11 socket and Xauth material, and apps render directly
through the host X server.

`PropagatedWayland` is the direct Wayland equivalent. Container apps reach the
host compositor socket, similar in spirit to a Flatpak with Wayland socket
access, but without sharing host settings or session bus.

`RdpWeston` is the compact Weston RDP mode: an isolated Wayland compositor and
a loopback RDP listener, mounting no host display, Wayland socket, or device.

`RdpGnome` is a remote-only Wayland desktop. GNOME Remote Desktop keeps an
independent headless GNOME/Mutter session inside the container and mounts no
host display or Wayland socket. It uses Mutter virtual monitors, PipeWire,
libei and FreeRDP, so the RDP client determines virtual display size when
connecting, and TLS material and credentials persist in the guest home
directory. Upstream GNOME RDP has a port setting but no listen-address setting,
so this mode cannot provide a self-contained loopback-only bind. It is also the
only mode here whose server implements RDP audio redirection (`rdpsnd` and
`audin`), which is why it stays in the catalogue despite that bind limitation.

`RdpKdeIsolated` and `RdpKdeWithDevices` are the persistent remote-only Plasma
Wayland desktop, and they share every mechanism below. A lingering user manager
starts `kwin_wayland --virtual` plus `plasmashell` and the KDE portal backend,
then runs KRdp against that session. It deliberately avoids
`startplasma-wayland`, which cannot create the bootstrap virtual output KRdp
needs before it negotiates its own. KRdp binds `Gui.RdpListenAddress` directly
(localhost by default) and persists TLS material and credentials in guest
state. Neither mounts a host display or Wayland socket.

What separates them is host access, and the suffix is a promise rather than a
default. `RdpKdeIsolated` crosses nothing: `Gui.Gpu`, `Gui.Audio` and
`Gui.Clipboard` are refused outright, KWin composites with QPainter, and the
session is pure Wayland with no X server present at all, so an X11-only client
fails loudly instead of finding a display that should not exist. That is the
agent-sandbox shape. `RdpKdeWithDevices` is the workstation shape: the host GPU
and audio bridge cross in, KWin composites on the render node, and the session
carries an Xwayland server for clients that have no Wayland path. Its toolkit
variables become preference lists rather than absolutes, so Wayland still wins
wherever a toolkit supports it and only a client with no Wayland path lands on
X11.

Both KDE modes use one patched KWin/KRdp/KPipeWire package set: QPainter
screencasting support for the no-GPU path, initial RDP-driven monitor size and
scale, H.264 level 5.2, input-coordinate and modifier fixes, and plaintext
clipboard support. The initial `Gui.RdpFallbackVirtualMonitor` is used only when
a client does not report valid dimensions/scale; live Display-Control resize
remains diagnostic-only. KRdp synchronously runs a packaged output lifecycle
helper after `Virtual-RDP-*` creation and before its teardown. When a
`Virtual-0` stub exists, the helper changes it only at those callback points and
repairs an affected Plasma panel with KScreen/KConfig, never a competing
watcher.

Their KWin/Plasma session receives a runtime-only KScreenLocker configuration
which disables locking. KRdp authentication is separate from the local Unix
account, and this remote-only profile deliberately has no local-password
unlock path for a displayless screen-lock greeter.

KWin also uses a private cache below its user runtime directory. The directory
name includes the selected patched-KWin store output, so its KService database
cannot carry stale KRdp private-protocol authorization metadata across a Nix
generation change.

`None` means no GUI integration.

Every `Rdp*` mode must set `Gui.RdpPort` explicitly. The option has no default
on purpose: managed containers share one network namespace, so a default would
hand every guest the same port and let whichever started second lose its bind.
Listen addresses do not separate them either, since GNOME's server ignores
`Gui.RdpListenAddress` and always binds `0.0.0.0`, so ports are asserted unique
across all RDP guests.

For modes without a suffix the crossing defaults follow the first token, and
the two families lean opposite ways: a `Propagated*` mode is already sharing
the host's display, so its crossings default on, while an `Rdp*` mode without a
suffix crosses nothing. Explicit per-container settings override the defaults
everywhere except the `Isolated` modes, which refuse them.

`Gui.Gpu` is orthogonal to the mode rather than a property of one, and the
guest reacts to it: the KDE modes select KWin's OpenGL renderer when a render
node is present and its QPainter renderer when it is not, and every GPU-enabled
mode receives the `HostGpu.MesaDriverName` override so the Mesa loader and
libva resolve the right driver. On the GPU path KWin composites on the render
node and hands KPipeWire dmabuf frames, so H.264 encoding can reach VA-API
instead of encoding a software composite on the CPU.

`Gui.Audio` means the host audio bridge, in every mode including the RDP ones.
It is not audio redirection over RDP: KRdp implements only the RDP Graphics
Pipeline extension and wires up neither `rdpsnd` nor `audin`
(https://bugs.kde.org/show_bug.cgi?id=491295), so an RDP guest with `Gui.Audio`
plays out of the host speakers rather than the client's. `RdpGnome` is the one
mode whose server does redirect audio to the client.

## Machine Registration Recovery

`systemd-machined` identifies an nspawn machine by the guest's PID 1. During a
normal stop, nspawn unregisters that machine when guest PID 1 exits. A rare
failure mode leaves that PID executing `systemd-shutdown` after the host
container unit has stopped. If `systemd-machined` is then restarted, it restores
the still-live leader from `/run/systemd/machines`; a replacement nspawn cannot
register the same machine name, and `machinectl` / `nixos-container` address the
old PID instead.

Each managed container has a pre-start repair unit for this precise condition.
It unregisters the stale name and terminates the old process only when all of
the following are true: the container service has no live supervisor, machined
reports a numeric leader, and that leader is `systemd-shutdown` in the deleted
guest `payload/init.scope` belonging to the same container. Any other mismatch
fails the start rather than risking an unrelated process or an active machine.

Managed container units also have an explicit three-minute host-side stop
deadline. It bounds an ordinary nspawn stop job, but cannot kill a process that
has already escaped into a deleted guest cgroup; that is why the pre-start
registration check remains necessary.

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
