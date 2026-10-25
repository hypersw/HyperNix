# `jetbrains-tarball-ide <folder | ide.tar.gz…> [IDE args…]`: builds the IDE from a tarball given by path and starts it.
#
# The file-reference counterpart of the drop-in flake in `Template/`.
# A folder or a glob lets one fixed command line pick up each new download: the highest version among the tarballs wins.
# It evaluates `package.nix` against this flake's nixpkgs with `--impure`, which is the only way to hand Nix a path that is not part of a flake.
# The build is kept alive by an out-link under ~/.cache, so a garbage collection does not force a rebuild.
{ pkgs, nixpkgs }:
pkgs.writeShellApplication {
  name = "jetbrains-tarball-ide";
  runtimeInputs = [ pkgs.coreutils ];
  text = ''
    candidates=()
    if [[ $# -ge 1 && -d $1 ]]; then
      # One out-link per folder, so a newer tarball there replaces the older build's root.
      root_name=$(basename "$(realpath "$1")")
      shopt -s nullglob
      candidates=("$1"/*.tar.gz)
      shift
    else
      # A glob expands to several leading *.tar.gz arguments; whatever follows goes to the IDE.
      while [[ $# -ge 1 && $1 == *.tar.gz ]]; do
        candidates+=("$1")
        shift
      done
      if [[ ''${#candidates[@]} -gt 1 ]]; then
        root_name=$(basename "$(dirname "$(realpath "''${candidates[0]}")")")
      elif [[ ''${#candidates[@]} -eq 1 ]]; then
        root_name=$(basename "''${candidates[0]}" .tar.gz)
      fi
    fi
    if [[ ''${#candidates[@]} -eq 0 ]]; then
      echo "usage: jetbrains-tarball-ide <folder | ide.tar.gz...> [IDE args...]" >&2
      exit 2
    fi
    tarball=$(printf '%s\n' "''${candidates[@]}" | sort -V | tail -n 1)
    tarball=$(realpath -e "$tarball")
    echo "jetbrains-tarball-ide: $tarball" >&2

    roots="''${XDG_CACHE_HOME:-$HOME/.cache}/jetbrains-tarball-ide"
    mkdir -p "$roots"
    out=$(nix build \
      --impure \
      --print-out-paths \
      --out-link "$roots/$root_name" \
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
