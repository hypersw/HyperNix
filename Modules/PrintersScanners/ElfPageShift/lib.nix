{ pkgs, lib ? pkgs.lib }:

# ElfPageShift entry point — exposes both the standalone build-time
# tool and a `pageShiftElfBundle` derivation factory that consumers
# can use to wrap arbitrary file-tree derivations and rewrite every
# .so* file inside them.
#
# Independence-from-the-rest-of-HyperNix is intentional: this
# directory is structured so that extracting it into its own flake
# later is mechanical (lift this dir to a new repo, expose
# `packages.elf-page-shift` and `lib.pageShiftElfBundle` from
# its `flake.nix`).

let
  elf-page-shift = pkgs.callPackage ./package.nix {};
in
rec {
  inherit elf-page-shift;

  # Wrap a derivation `src` and produce a new derivation with the
  # same directory tree, but with every regular .so* file rewritten
  # through `elf-page-shift`. Symlinks (e.g. libfoo.so → libfoo.so.0
  # → libfoo.so.0.0.0 chains common in shared-library bundles) are
  # preserved as symlinks — they re-resolve through the file system
  # to the now-shifted regular file, so the .so / .so.MAJOR / SONAME
  # aliases keep working.
  #
  # Idempotent: if a .so is already 16K-aligned, the tool copies it
  # through unchanged, so this function is safe to apply
  # unconditionally — including on hosts that don't need the shift.
  # The shifted output works on both 4K- and 16K-page kernels, so
  # there is no reason to gate the call on host page size.
  #
  # Build runs on `pkgs.system`. The contents of the output can
  # target any architecture (the tool only reads/writes bytes), so
  # an aarch64 host can shift an x86_64 .so bundle without binfmt /
  # qemu being involved at build time.
  pageShiftElfBundle =
    { src
    , name ? "${src.name or "bundle"}-pageshifted"
    }:
    pkgs.runCommand name {
      nativeBuildInputs = [ elf-page-shift ];
      passthru = (src.passthru or {}) // {
        unshifted = src;
      };
    } ''
      mkdir -p "$out"
      # cp -RL would deref symlinks — we want to preserve them.
      cp -r --no-preserve=mode,ownership "${src}/." "$out/"
      chmod -R u+w "$out"

      # Shift every regular .so* file. -type f excludes symlinks
      # automatically. Use a temp file then mv to keep the
      # in-place-ish workflow simple; elf-page-shift refuses to
      # write to the same path it's reading from (would corrupt
      # mid-write).
      find "$out" -type f \( -name '*.so' -o -name '*.so.*' \) -print0 \
        | while IFS= read -r -d ''' f; do
            tmp="$f.pageshift.tmp"
            elf-page-shift "$f" "$tmp"
            mv "$tmp" "$f"
          done
    '';
}
