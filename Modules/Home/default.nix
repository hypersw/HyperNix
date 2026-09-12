#
# HyperNix home-manager module-list — the home-manager counterpart to
# `Modules/default.nix`, and the single source of truth for which HM modules
# HyperNix ships.
#
# Same discipline as the NixOS bundle: every module path appears here exactly
# once, modules never `imports` a peer, and consumers import the bundle rather
# than enumerating modules. Exposed as `flake.hmModules.default`.
#
# Consumers:
#   * external: `imports = [hypernix.hmModules.default];`, or via the
#     `import-flake` flake-compat helper for channel-based HM configs.
#
# Activation is via option-setting:
#   programs.askpass-safe.enable = true;
#
# Modules live next to their NixOS siblings (`Modules/<Area>/<Name>/home.nix`)
# so a subject's NixOS and HM halves stay in one directory.
{
  imports = [
    ../Git/AskpassSafe/home.nix
  ];
}
