# JetBrainsTarballIde

Turns a JetBrains IDE Linux tarball (`*.tar.gz`) into a proper Nix package that runs without nix-ld.

## Use

By path:

```sh
nix run github:hypersw/HyperNix#Modules-Programs-JetBrainsTarballIde -- ~/Downloads/draft-271.1325.tar.gz
```

The build stays rooted under `~/.cache/jetbrains-tarball-ide/<tarball name>` until you delete that link.

Drop-in, in a folder holding exactly one tarball:

```sh
nix flake init -t github:hypersw/HyperNix#Modules-Programs-JetBrainsTarballIde
nix run path:.
```

From another flake: `hypernix.lib."Modules-Programs-JetBrainsTarballIde" { inherit pkgs; src = ./ide.tar.gz; }`, with `allowUnfree` on `pkgs`.

## How

`package.nix` calls nixpkgs' `jetbrains.mkJetBrainsProduct`, the builder of `pkgs.intellij-idea` and its siblings.
The product name, version, launcher, WM class and vmoptions come from the tarball's `product-info.json`.
The bundled JBR is kept and patched with `autoPatchelfHook`; `useBundledJbr = false` takes nixpkgs' `jetbrains.jdk` instead.

## Limits

- Binaries the IDE downloads at run time (language servers, SDKs, toolchains, Marketplace plugins with natives) are not patched and still need nix-ld.
  nixpkgs patches downloads only in tools with one install routine, such as rustup and elan; the IntelliJ platform has many separate downloaders.
- Natives the IDE unpacks from its jars at run time get a basic `LD_LIBRARY_PATH` from the wrapper instead.
- The drop-in mode rebuilds whenever anything in its folder changes, and each tarball takes a few store copies of its size.
