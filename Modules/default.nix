#
# HyperNix module-list — the single source of truth for which
# NixOS modules HyperNix ships.
#
# Mirrors nixpkgs' `nixos/modules/module-list.nix` pattern: every
# module path appears here exactly once, and the bundle is what
# both internal and external consumers import. Individual modules
# never `imports = [otherModule]` to pull in a peer — they just
# reference `config.hypersw.services.X.foo` on the assumption the
# bundle has loaded everything. Profiles only declare options +
# set values; they don't transitively import sub-modules either.
#
# That single-list discipline is what makes the dedup work: no
# module is reachable via two distinct paths in the import graph,
# so the NixOS module system can never see "two declarations of
# option X" from one logical module loaded twice.
#
# Consumers:
#   * external (e.g. NixConfig): `flake.nixosModules.default` is
#     this file. `imports = [hypernix.nixosModules.default];` or
#     via the `import-flake` flake-compat helper.
#   * internal (this flake's own machines under `Machines/`):
#     `imports = [../../../Modules];` from each machine's
#     `configuration.nix`. Same bundle, no enumeration needed.
#
# Activation is via option-setting:
#   hypersw.profiles.anyMachineBase.enable = true;
#   hypersw.profiles.printScanServer.enable = true;
#   hypersw.services.<x>.enable = true;
#   etc.
#
# Modules disabled-by-default just declare their option surface
# and add nothing to the system — cost is essentially zero per
# unused module at runtime, only minor eval-time option-namespace
# bloat. Cheap relative to the simplicity gain.
{
  imports = [
    ./Git/SshAskpassCredentialHelper
    ./PrintersScanners/LaserJetPrinter
    ./PrintersScanners/EpkowaScanner
    ./PrintersScanners/Daemon
    ./PrintersScanners/Renderer
    ./PrintersScanners/TelegramBot
    ./Monitoring/TelegramAlerts
    ./System/AutoRebuildOnPush
    ./System/AvahiPerInterfaceNames
    ./System/BootStabilityProbe
    ./System/Btm
    # `Hardware/RaspberryPi5SdImage` is NOT in the bundle. It sets
    # `sdImage.populateFirmwareCommands` in its `config`, and that
    # option only exists when an sd-image module is loaded. Live
    # machine configs don't load sd-image, so importing it there
    # would fail with "the option `sdImage' does not exist" even
    # though the module is gated by `enable = false`. Add it
    # explicitly to the sd-image build's modules list when needed.
    #
    # `System/BootOnce` — same pattern. Sets
    # `boot.loader.raspberry-pi.configurationLimit` (declared by
    # nvmd's `nixos-raspberrypi.nixosModules.raspberry-pi-5.base`,
    # which is only loaded for Pi-5 hosts via the
    # `nixos-raspberrypi.lib.nixosSystem` call site in flake.nix).
    # Non-Pi machines that import this bundle would otherwise trip
    # "the option `boot.loader.raspberry-pi' does not exist" even
    # with `hypersw.system.bootOnce.enable = false`, because
    # `lib.mkIf false` only suppresses the merged value — it
    # doesn't defer the option-existence check on the definition
    # path. Import explicitly from Pi machines that want the
    # wrapper.
    ./Profiles/AnyMachineBase
    ./Profiles/PrintScanServer
    ./Profiles/MultiHomedNetworking
    ./Profiles/PhysicalServerProvisioning
  ];
}
