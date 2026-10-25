# JetBrainsTarballIde

Turns a JetBrains IDE Linux tarball (`*.tar.gz`) into a proper Nix package that runs without nix-ld.

## Use

By path, with a folder, a glob or one file:

```sh
nix run github:hypersw/HyperNix#Modules-Programs-JetBrainsTarballIde -- ~/Apps/Draft
nix run github:hypersw/HyperNix#Modules-Programs-JetBrainsTarballIde -- ~/Apps/Draft/*.tar.gz
nix run github:hypersw/HyperNix#Modules-Programs-JetBrainsTarballIde -- ~/Downloads/draft-271.1325.tar.gz
```

Of several tarballs, the one with the highest version in its name wins (`sort -V`), so one command line serves every new download dropped into the folder.
Arguments after the tarballs go to the IDE.
The build stays rooted under `~/.cache/jetbrains-tarball-ide/<folder name>`, or `<tarball name>` for a single file, until you delete that link.
A newer build from the same folder takes over that root.

Drop-in, in a folder holding exactly one tarball:

```sh
nix flake init -t github:hypersw/HyperNix#Modules-Programs-JetBrainsTarballIde
chmod +x run.sh   # nix flake init drops the executable bit
./run.sh   # or: nix run path:.
```

`run.sh` runs the flake of its own folder from any working directory, so `~/Apps/Draft/run.sh` is one fixed command line.
The `path:` it uses keeps Nix from treating the folder as part of a parent git repo, which would hide the untracked tarball.
For a new build, replace the tarball: the folder must hold exactly one.

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
