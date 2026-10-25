# `jetbrains-tarball-ide <ide.tar.gz> [IDE args…]`: builds the IDE from a tarball given by path and starts it.
#
# The file-reference counterpart of the drop-in flake in `Template/`.
# It evaluates `package.nix` against this flake's nixpkgs with `--impure`, which is the only way to hand Nix a path that is not part of a flake.
# The build is kept alive by an out-link per tarball name under ~/.cache, so a garbage collection does not force a rebuild.
{ pkgs, nixpkgs }:
pkgs.writeShellApplication {
  name = "jetbrains-tarball-ide";
  runtimeInputs = [ pkgs.coreutils ];
  text = ''
    if [[ $# -lt 1 ]]; then
      echo "usage: jetbrains-tarball-ide <ide.tar.gz> [IDE args...]" >&2
      exit 2
    fi
    tarball=$(realpath -e "$1")
    shift

    roots="''${XDG_CACHE_HOME:-$HOME/.cache}/jetbrains-tarball-ide"
    mkdir -p "$roots"
    out=$(nix build \
      --impure \
      --print-out-paths \
      --out-link "$roots/$(basename "$tarball" .tar.gz)" \
      --expr "import ${./package.nix} {
        pkgs = import ${nixpkgs} { system = \"${pkgs.stdenv.hostPlatform.system}\"; config.allowUnfree = true; };
        src = /. + \"$tarball\";
      }")

    # The one launcher in bin/, beside the remote-dev-server wrapper.
    for exe in "$out"/bin/*; do
      [[ $exe == *-remote-dev-server ]] || exec "$exe" "$@"
    done
    echo "jetbrains-tarball-ide: no launcher in $out/bin" >&2
    exit 1
  '';
}
