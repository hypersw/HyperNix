# Looking Glass — Setup Guide

The companion NixOS module (`default.nix` in this directory) handles
most of the hypervisor-side configuration declaratively: client
install, machine-wide `.ini`, kvmfr kernel module + udev + kvm-group,
libvirt cgroup ACL extension, and per-profile wrapper scripts. What
the module does NOT handle: the per-VM libvirt XML — that stays
manual (or managed by whatever tooling produces your `domain.xml`s).
This document covers everything outside the module: the per-VM XML
you have to write, the Windows-guest stack, and the loose ends
nobody mentions until you've been stuck on them for an hour.

Terminology note: "host" is overloaded in this space (LG has a
"Host service", VMs have "guest" and "host" sides, hypervisors have
"hosts"). This doc uses **hypervisor** for the Linux machine running
the VMs, **guest** for the Windows VM, **LG client** for the viewer
on the hypervisor, and **LG server** for what upstream LG docs call
the "host service" running inside the guest. The latter is
deliberately not their terminology — sorry for the disagreement, it
removes a real source of confusion.

---

## Strict prerequisites (sequence matters)

These are sequential dependencies. Doing step *n* before step *n−1*
will fail in ways that look like other problems.

### 1. Module activation (declarative; the module does this)

When you set `hypersw.programs.lookingGlassClient.enable = true;`
the module activates:

- `looking-glass-client` package installed.
- `/etc/looking-glass-client.ini` written with the selected feature
  groups (mouseFixes / lowLatencyDefaults / autoCapture).
- kvmfr kernel module added to `boot.kernelModules` and a modprobe
  option file sets `static_size_mb=` from `kvmfrSizesMb` (default
  `[ 64 ]` → one 64 MiB device at `/dev/kvmfr0`).
- udev rule applied: `SUBSYSTEM=="kvmfr", OWNER="root", GROUP="kvm", MODE="0660"`.
- Each entry of `interactiveUsers` added to the `kvm` group.
- libvirt's `qemu.cgroup_device_acl` rewritten to include
  `/dev/kvmfr0` (and any further `kvmfr*` if `kvmfrSizesMb` has
  multiple entries).

After `nixos-rebuild switch`, reboot so kvmfr loads with the
configured size (`static_size_mb` is read at module load; if kvmfr
was loaded before with no size, you need to either reboot or
`rmmod kvmfr && modprobe kvmfr` with no VM holding the device).

Sizing rule of thumb for `kvmfrSizesMb`:
`2 * width * height * 4 + ~10 MiB`, rounded up to a power of two.
64 MiB covers 4K @ 32 bpp double-buffered; bump for 5K, dual-display,
or HDR captures. Each kvmfr device is 1:1 with one VM (`ivshmem-plain`
has one writer per region), so for multiple LG-using VMs you list
multiple sizes: `[ 64 32 32 ]`.

If you'd rather skip kvmfr entirely (no kernel module, no cgroup
ACL extension), use `/dev/shm`-backed shared memory instead — see
"Per-VM XML: shared memory" below. The two cost/benefit profiles:
kvmfr is lower-latency and contiguous-pinned (the right choice for
gaming VMs), `/dev/shm` is zero-setup with marginal latency cost
(fine for the WARP/Mica-testing fleet).

### 2. Per-VM XML — kernel-side (CPU/RAM/IO/passthrough)

Standard libvirt XML for the VM itself. Nothing LG-specific yet.
Things that matter for LG-via-passthrough specifically:

- `<cpu mode='host-model'>` or `host-passthrough` — game performance.
- `<hyperv>` enlightenments — boot Windows faster, but if you pass
  through an NVIDIA card, leave `vendor_id` set to something like
  `KVM Hv` for robustness even though modern NVIDIA no longer
  enforces the Code-43 detection.
- `<features><kvm><hidden state='on'/></kvm>` — historically
  required to hide KVM from guests, no longer needed on R470+
  drivers.

Memory should be allocated as `<memoryBacking><hugepages/></memoryBacking>`
for gaming VMs if your host is configured with huge pages, but
that's a general performance tweak, not LG-specific.

### 3. Per-VM XML — shared memory (the LG-specific part)

Two paths, pick one per VM.

**kvmfr-backed** (lower latency; needs the module's kvmfr setup
above). Use a raw `<qemu:commandline>` block — libvirt's
`<shmem>` element doesn't support pointing at a `/dev/kvmfr*` node:

```xml
<qemu:commandline xmlns:qemu="http://libvirt.org/schemas/domain/qemu/1.0">
  <qemu:arg value='-device'/>
  <qemu:arg value='{"driver":"ivshmem-plain","id":"shmem0","memdev":"looking-glass"}'/>
  <qemu:arg value='-object'/>
  <qemu:arg value='{"qom-type":"memory-backend-file","id":"looking-glass","mem-path":"/dev/kvmfr0","size":67108864,"share":true}'/>
</qemu:commandline>
```

`size` (in bytes) must match what `kvmfrSizesMb` allocated for that
device. Different VMs sharing the same `/dev/kvmfr0` is undefined
behavior — use distinct devices (`kvmfr1`, `kvmfr2`, ...).

**`/dev/shm`-backed** (zero-extra-setup alternative). Use libvirt's
native element:

```xml
<shmem name='lg-warp'>
  <model type='ivshmem-plain'/>
  <size unit='M'>64</size>
</shmem>
```

libvirt creates `/dev/shm/lg-warp` automatically, no cgroup ACL
entry needed (libvirt allows access to files it created in
`/dev/shm`). The `name=` attribute and the shm filename are
identical; mirror it in the matching LG client profile:

```nix
hypersw.programs.lookingGlassClient.profiles.warp = {
  app   = { shmFile = "/dev/shm/lg-warp"; };  # same name as the XML
  spice = { port = 5911; };
  win   = { title = "LG: warp-test"; };
};
```

The kvmfr-backed profile looks the same except `shmFile` points at
`/dev/kvmfr0` (or `kvmfr1` if you're using a second device).
**Always set `app:shmFile` explicitly in a kvmfr profile** — LG's
compiled-in default is `/dev/shm/looking-glass`, so omitting it
makes the wrapper silently target the wrong path:

```nix
hypersw.programs.lookingGlassClient.profiles.stm = {
  app   = { shmFile = "/dev/kvmfr0"; };
  spice = { port = 5910; };
};
```

### 4. Per-VM XML — SPICE for input

LG uses IVSHMEM for video only. Mouse, keyboard, clipboard go over
SPICE. The robust configuration is **fixed listen address + fixed
port** with one port per VM, chosen out of libvirt's autoport range:

```xml
<graphics type='spice' port='5910' autoport='no'>
  <listen type='address' address='127.0.0.1'/>
  <image compression='off'/>
  <gl enable='no'/>
</graphics>
```

Port choice: libvirt's autoport range starts at 5900 and increments
upward, so anything ≥5910 stays out of its way unless you've got a
double-digit number of autoport'd VMs. Pick a fixed port per VM
(`5910`, `5911`, `5912`, ...) and mirror it in the LG client
profile's `spice:port=`. This pairs stably forever — no need to
re-query libvirt after each restart.

Why not `autoport='yes'`? Because LG profiles reference a specific
port number; the assigned port changes every libvirt restart and
your profile's `spice:port=5910` would point at the wrong VM. The
"fixed port per VM" pattern is much less fragile.

Why not `listen='none'` and a unix socket? Theoretically libvirt
exposes a per-domain unix socket at
`/var/lib/libvirt/qemu/domain-N-<name>/spice.sock` when listen is
none, and the LG client can connect to it via `spice:host=/path,
spice:port=0`. In practice that socket doesn't always materialize
(empirically observed: no socket present after VM start despite
the docs claiming it should be there). If you want this path,
research it on your specific libvirt version before relying on it.

### 5. NVIDIA passthrough (only if using a real GPU)

Two ways to take a GPU away from the host and give it to a VM:
**early-bind at boot** (simple, GPU is dedicated to the VM
forever) or **dynamic-bind on VM start** (host can use the GPU
between VM sessions, e.g. for host-side CUDA work).

**Early-bind** — set the `vfio-pci.ids=` kernel parameter:

```nix
boot.kernelParams = [
  "amd_iommu=on"  # or intel_iommu=on on Intel hosts
  "iommu=pt"
  "vfio-pci.ids=10de:21c4,10de:1aeb,10de:1aec,10de:1aed"
];
```

`10de:21c4` is your GPU's vendor:device ID; the rest are its
adjacent functions (HDA audio, USB-C controller, UCSI on Founder's
Edition cards). Find them with `lspci -nn` on the running host —
look for the four-function block under the same bus:device. After
reboot, all four functions are bound to `vfio-pci` and unavailable
to the host. Nothing else to do; libvirt's `<hostdev managed='yes'>`
just attaches them.

This is the right call if the GPU is permanently a VM's GPU and
you never want it on the host (e.g. the host runs on an iGPU and
the dGPU is purely VM-bound).

**Dynamic-bind** — no kernel parameters; the GPU is bound to the
host's normal driver (nvidia / nouveau / amdgpu) at boot, and
something (a libvirt hook, a wrapped `virsh start`, a systemd unit
ordered before the domain) unbinds it on VM start and re-binds it
on VM stop. This is what you want if the host should use the GPU
between VM sessions. The right way to wire this up belongs *in
this module* rather than as ad-hoc drop-in scripts in `/etc/libvirt/hooks/`
— ask for help adding a `hypersw.programs.lookingGlassClient.gpuHandoff`
sub-option (or similar) when you're ready to use this path. It's
not in the module yet because hand-off semantics depend on what's
holding the GPU on the host (X11, Wayland compositor, CUDA process
manager, ZFS ARC) and that's worth designing once with full
context.

**Subtleties either way**:

- Modern NVIDIA driver (R470+) doesn't require `<hyperv>...<vendor_id .../>`
  spoofing anymore — the "Code 43 on consumer cards in VM" detection
  was removed. The setting remains harmless and is worth keeping
  for forward-compat.
- Function-level reset bug ("FLR fails on the second pass-through")
  affects some NVIDIA SKUs, mostly older ones. Ampere+ Founder's
  Edition cards are generally fine. If it bites:
  `echo 1 > /sys/bus/pci/devices/<addr>/reset` between cycles.
- Single-tenant only without `vgpu_unlock-rs` — one VM at a time
  gets the full card. For concurrent shared use of one consumer
  NVIDIA across multiple VMs, `vgpu_unlock-rs` is the only working
  path (gray-legal, but functional on Ampere+).

---

## Independent setup areas

Within each area below, order doesn't matter. Across areas there's
a soft dependency: guest install → guest config → guest registry &
NVCP tuning. Picking up at any of these areas after a fresh module
activation is fine — the module-side setup is unconditional.

### Guest: required components

Three components, all required. Download `looking-glass-host-Setup-B<N>.exe`
from <https://looking-glass.io/downloads>. Recent installers bundle
the IVSHMEM Windows driver — running the host installer also
handles the IVSHMEM device on first install, no separate step.
**Major version must match the client on the hypervisor** (B7 client
↔ B7 server, no cross-version pairing).

- **LG SERVER service** (what upstream calls "Looking Glass Host
  service"). Installer registers a Windows service set to
  auto-start. Config at
  `%ProgramData%\Looking Glass (host)\looking-glass-host.ini`
  does NOT exist by default — you create it. Just copy
  `Template/looking-glass-host.ini` from this directory verbatim
  to the destination (filename matches).

- **NVIDIA driver** (if using a passed-through NVIDIA GPU). Direct
  from <https://www.nvidia.com/Download>, matching your card.
  Custom install: drop GeForce Experience, keep only "Graphics
  Driver" and PhysX. Verify in Device Manager → Display adapters:
  no yellow exclamation, card name matches your physical hardware.

- **Virtual Display Driver (VDD)** — only required if the
  passed-through GPU has **no physical or emulated monitor**
  attached. The role of VDD is to give a "displayless" GPU
  something to render to, so DWM has a real swapchain on the
  passed-through GPU for LG to capture from. If your GPU does
  have a monitor (real or via an EDID emulator dongle), VDD adds
  nothing — skip it. The decision tree:

  - **NVIDIA HDMI/DP plugged into a real monitor** (even if the
    monitor's input is switched to something else; the EDID
    handshake is what matters): VDD not needed.
  - **EDID emulator dongle on the NVIDIA output** (~$5–10
    electronics-shop part): VDD not needed.
  - **Neither**: VDD is the software equivalent of the dongle —
    download from
    <https://github.com/VirtualDrivers/Virtual-Display-Driver/releases>
    and install. Edit `vdd_settings.xml` in the install folder
    (Notepad as Admin) with a single starting resolution; toggle
    the driver via Device Manager (Disable → Enable) after editing.

  QXL alone is NOT enough: even after the qxl-wddm-dod driver is
  installed (it sometimes isn't, since virtio-win drivers need to
  be installed separately), the QXL device reports as
  `Microsoft Basic Render Driver` which LG's capture path
  explicitly refuses. So QXL handles the early boot screen and
  serves as a fallback for SPICE viewer, but it can't be the
  primary capture surface for LG.

### Guest: display configuration

After all components are installed, the **main display** decision
depends on whether NVIDIA has a real or emulated monitor:

- If NVIDIA owns a real or EDID-emulated monitor → set **that
  monitor** as main display. LG captures it directly; nothing
  virtual in the path. This is the cleanest setup.
- If NVIDIA has no monitor and you installed VDD → set the **VDD
  virtual monitor** as main display. NVIDIA renders into VDD's
  virtual swapchain; LG captures that.

In both cases, optionally "Disconnect this display" on the QXL
emulated monitor in Settings → System → Display. DWM stops
compositing for it, slightly reducing compositor work and avoiding
weird "Windows is rendering to QXL by mistake" symptoms.

### Guest: mouse fix (registry)

`Template/MouseFix.reg` in this directory flattens Windows'
`SmoothMouseXCurve` / `SmoothMouseYCurve` to true linear and sets
sensitivity to the middle notch. Required for predictable mouse
behavior inside the LG window — even with the client-side
`rawMouse=yes`, Windows still applies its baseline curve to the
relative-motion input, and that curve is what makes fast moves
over-travel.

The file is shipped in canonical Windows-registry encoding
(UTF-16 LE with BOM, CRLF line endings); just copy it into the
guest and double-click. If you've previously seen "Error opening
the file" from regedit, that meant the file was UTF-8 LF — copy
the current version, that's been fixed.

Apply (in the guest, as the user who'll be using LG, not as System):

1. Open Settings → Devices → Mouse → Additional mouse settings →
   Pointer Options → uncheck "Enhance pointer precision". Apply.
2. Set the "Pointer speed" slider to the middle (6 of 11) — that
   corresponds to `MouseSensitivity=10`, the identity multiplier.
3. Copy `MouseFix.reg` into the guest and double-click. Approve
   the UAC prompt.
4. Sign out and back in (registry values are read at session
   creation). Reboot also works.

Snapshot first if you want easy rollback:
```
reg export "HKCU\Control Panel\Mouse" %USERPROFILE%\Desktop\mouse-original.reg
```

The change is per-user (HKCU), so it scopes to the Windows user
account in the guest, not machine-wide. Other guest users are
unaffected. Reverting: re-merge the snapshotted .reg.

### Guest: NVIDIA Control Panel

NVCP → Manage 3D Settings → Global Settings (or per-game in
Program Settings). Defaults from a vanilla driver install are
wrong for LG-via-passthrough; the three that matter:

- **Power management mode** → **Prefer maximum performance**.
  Without this the driver downclocks when it thinks no monitor is
  scanning out (it can't tell that LG is capturing the swapchain).
  Set globally; the cost on idle is power, which doesn't matter
  for a desktop-tier VM. Likely the single biggest FPS recovery
  on most passthrough setups.

- **Vulkan/OpenGL present method** → **Prefer layered on DXGI
  Swapchain**. Vulkan/OpenGL games using the "native" GDI present
  path are uncapturable by DXGI Output Duplication — LG sees a
  black or stale frame. Layered DXGI routes the presentation
  through DWM where capture can read it. Cost: 5–15% FPS in
  drawcall-heavy OpenGL titles like Minecraft Java, because the
  GL↔DXGI sync overhead is per-draw. Modern AAA Vulkan engines
  are mostly unaffected. Override per-game in Program Settings if
  a specific title's loss bothers you.

- **Low Latency Mode** → **Ultra**. NVIDIA Reflex equivalent for
  titles that don't natively support Reflex. Cheap and consistent
  improvement.

Plus: in NVCP → "Vertical sync" → **Off** for the captured display
(LG handles its own pacing).

### Guest: LG SERVER configuration

Create `C:\ProgramData\Looking Glass (host)\looking-glass-host.ini`
by copying `Template/looking-glass-host.ini` from this directory.
The destination directory exists from the installer; the file
does not. Notepad as Administrator (else you can't save into
`ProgramData`); paste the template; Save As → "All Files" filter
→ filename `looking-glass-host.ini` (else Notepad appends `.txt`).

Restart the service: services.msc → "Looking Glass (host)" →
Restart. Verify in Event Viewer → Application logs (filter by
source "Looking Glass") that capture started and named the right
adapter/output.

Pin the captured display by **adapter description**, not display
index — `\\.\DISPLAY2` shifts when QXL is enabled/disabled or
after driver updates. The adapter description (e.g.
`NVIDIA GeForce GTX 1660 SUPER`) is stable across all of those.
The `adapter=` value is matched as a **case-sensitive substring**
of Windows' WDDM adapter description (LG B7 uses a `wcsstr`
search), so `adapter=NVIDIA` matches `NVIDIA GeForce GTX 1660
SUPER` and any other NVIDIA card. Use a more specific substring
if you have multiple NVIDIA adapters in the same VM.

### Hypervisor: Linux client behaviour notes

The NixOS module handles the persistent config side (the .ini).
Two runtime behaviours worth knowing:

**Wayland / GNOME / KDE input-capture portal**:

- GNOME Wayland prompts on every LG launch for input capture
  permission and does not persist the consent (deliberate design).
- KDE Plasma 6 offers "remember this choice" in the portal prompt
  and persists.
- wlroots compositors (sway, Hyprland) typically skip the portal.
- X11 sessions have no portal in the path — `XGrabKeyboard` just
  works.

If the per-launch prompt is annoying on GNOME Wayland, the path
of least resistance is "log into GNOME on Xorg" at the GDM login
screen. Same desktop, no prompt.

**Breakout-key model**:

LG's escape key (Scroll Lock by default) is a toggle, not a
hold-to-pass-through and not a tmux-style prefix-then-chord. There
is no built-in "Scroll Lock + Alt + Tab → host alt-tab" mode; the
escape key only toggles LG's own grab.

Two practical workarounds:

1. **WM-level interception.** Bind a host shortcut to a key the
   guest won't see, e.g. `Super+Tab` on KDE/kwin's "Walk Through
   Windows" — works above LG's grab because the WM intercepts
   before the grab is delivered. Alt+Tab continues to go to the
   guest.

2. **Auto-capture model.** The module's `enableAutoCapture`
   option turns the toggle into a "click-to-grab, focus-loss-
   releases" flow. Less of a single-keystroke breakout, but
   deterministic and avoids the "is it grabbed or not" ambiguity.

---

## Quick verification checklist

After everything's set up, in order:

1. On hypervisor: `ls -la /dev/kvmfr0` shows `crw-rw---- root kvm`.
2. `virsh start <vm>` succeeds (no `EPERM` from cgroup).
3. SPICE viewer (virt-manager) shows the guest desktop; input works.
4. In guest: Device Manager — IVSHMEM Device present, NVIDIA card
   loaded clean, VDD adapter present *if* needed (see "Guest:
   required components" above), main display set per "Guest:
   display configuration".
5. In guest: `looking-glass-host.txt` log shows
   `capture method D12 started` with the right adapter name.
6. On hypervisor: `looking-glass-client-<profile>` opens, frames
   appear, Scroll Lock grabs input.
7. In guest game: FPS-vs-direct-passthrough delta is 3–7%; mouse
   moves linearly inside LG window.

Anything else, the LG forum / Discord / GitHub issues are the
canonical source.

---

## WARP-only guests (no real or passed-through GPU)

Out of the box, the LG SERVER refuses to capture from
`Microsoft Basic Render Driver` (the WDDM name for WARP, Windows'
software D3D renderer used when no real GPU driver is loaded). The
log line is `Not using unsupported adapter: Microsoft Basic Render
Driver`, and there is no LG config option to disable the check. The
refusal is a UX choice — DXGI Output Duplication does work against
WARP, just at lower throughput because rendering is CPU-bound — and
for a desktop-testing VM (Mica, acrylic, IDE work) the throughput is
fine, comparable to what RDP delivers at AVC444.

The filter is a single `wcscmp`-style guard in the LG host source.
The way to remove it without rebuilding is a one-byte binary patch
on the installed `looking-glass-host.exe`: flip the first byte of
the UTF-16 LE literal `Microsoft Basic Render Driver` (so the
comparison can never match a real adapter description). The
`Template/Patch-LookingGlassServer.ps1` script in this directory
automates that:

1. Copy `Patch-LookingGlassServer.ps1` into the guest.
2. Open an elevated PowerShell (right-click → "Run as administrator").
3. Allow the script for this session:
   ```
   Set-ExecutionPolicy -Scope Process Bypass
   ```
4. Run it:
   ```
   .\Patch-LookingGlassServer.ps1
   ```
5. Verify in Event Viewer → Application logs (source "Looking Glass")
   that capture now starts on the WARP adapter, e.g.
   `capture method D12 started, output: \\.\DISPLAY1`.

The script is **idempotent** (skips if already patched), **safe**
(backs up the original EXE under
`looking-glass-host.exe.unpatched.<timestamp>.bak` before writing),
and **service-aware** (stops the LG service before patching, restarts
it after, if it was running). Re-apply after every LG version
upgrade — the installer overwrites the patched EXE with a fresh
unpatched one. To revert, rename one of the `.bak` files back over
the EXE.

Caveats with the WARP path:

- WARP rendering is on the CPU; expect 30–60 fps for desktop content
  with one core pegged.
- No GPU video acceleration in the guest — YouTube playback is
  choppy and CPU-heavy.
- Acrylic blur can stutter under window movement; static Mica is
  fine. Mostly OK for "I want to see Mica" testing.
- Skip GPU-specific settings entirely: no NVIDIA Control Panel
  step, no VDD needed (the WARP adapter is itself the rendering
  target so there's nothing displayless to compensate for).

Alternative if you find yourself maintaining the patch across many
guests: deploy Sunshine + Moonlight instead of LG for the WARP fleet
— Sunshine doesn't filter MBRD and works out of the box on
WARP-only guests. You lose the IVSHMEM zero-copy path but the
latency floor is already dominated by software rendering on the
WARP side, so it's a wash. LG keeps making sense for the kvmfr+real-
GPU path.

---

## Companion files in this directory

- `default.nix` — the NixOS module that writes
  `/etc/looking-glass-client.ini`, handles kvmfr+udev+group+ACL
  setup, and produces per-profile wrappers.
- `Template/MouseFix.reg` — registry merge for the in-guest mouse
  curve fix described above. Canonical Windows registry encoding
  (UTF-16 LE with BOM, CRLF). Copy to guest, double-click.
- `Template/looking-glass-host.ini` — annotated starting config
  for the in-guest LG SERVER service. Copy to the guest at
  `C:\ProgramData\Looking Glass (host)\looking-glass-host.ini`
  (filename matches; no rename needed) and fill in the `adapter=`
  substring.
- `Template/Patch-LookingGlassServer.ps1` — idempotent binary
  patcher for the LG SERVER EXE that disables its hardcoded
  refusal of the WARP/MBRD adapter. Required only on guests with
  no real or passed-through GPU; see the "WARP-only guests"
  section above for usage.
