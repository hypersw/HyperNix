# TODO: Extract MicroVM Runner Module

## Goal

Turn the build/run/timer services currently hardcoded in the NixOS host config
(NixConfig/HyperJetHV/HyperJetHV/HyperJetHV.nix, "SSH Front" section) into a
reusable NixOS module exported from this flake.

## Current state

Three systemd units in the host config manage this VM:

- `BuildSshFront` — oneshot that `nix build`s the VM from a GitHub flake ref
  with `--refresh --no-write-lock-file` (always latest nixpkgs)
- `RunSshFront` — simple service that `nix run`s the built VM
- `TriggerBuildSshFront` — daily timer that triggers the build (with random delay)

Plus a QMP graceful shutdown script in `RunSshFront.ExecStop` that sends ACPI
powerdown via the QMP socket and waits up to 30s before SIGKILL.

## Target design

A NixOS module exported as `nixosModules.Machines-MicroVM-VmSshFront` (and
from the root flake) that generates all three services from a simple config:

```nix
services.microvm-runner.VmSshFront = {
  enable = true;
  # flakeRef is pre-filled to self — the module knows its own flake
  autoRefresh = true;          # --refresh --no-write-lock-file
  rebuildInterval = "daily";   # OnCalendar for the timer
  rebuildRandomDelay = "6h";   # RandomizedDelaySec
  gracefulShutdownTimeout = 30;
};
```

The module should:

- Derive service names from `<name>`: `Build<name>`, `Run<name>`, `TriggerBuild<name>`
- Derive QMP socket path from `<name>`: `/run/VmControl.<name>.socket`
- Pre-fill `flakeRef` to the package output from this flake (`self`), so consumers
  don't need to specify a GitHub URL — just `enable = true`
- Still allow `flakeRef` override for testing local builds
- Generate the ExecStop QMP graceful shutdown script with configurable timeout
- Make `autoRefresh` control whether `--refresh --no-write-lock-file` is passed

## Possible generalization

If multiple MicroVMs are added later (e.g., `VmBuildAgent`), each gets its own
subfolder flake under `Machines/MicroVM/`, each exporting its own module with
the same `services.microvm-runner.<name>` interface. The runner logic could be
factored into a shared module that individual VM flakes import, passing only
their specific package output.

## Files to change

- This flake (`flake.nix`): add `nixosModules.default` exporting the module
- Root flake (`../../flake.nix`): re-export as `nixosModules.Machines-MicroVM-VmSshFront`
- Consumer (NixConfig host config): replace the three hardcoded services with
  `imports = [ ... ]; services.microvm-runner.VmSshFront.enable = true;`
