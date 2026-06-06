{ lib, stdenvNoCC, python3, python3Packages, makeWrapper }:

# Standalone, build-time tool — page-shift an ELF64 .so so it loads
# under a kernel with a larger page size than the .so was linked for.
# Usage:  elf-page-shift <input.so> <output.so>
#
# Pure Python (+ pyelftools). Architecture-agnostic build, even though
# the typical input is an x86_64 .so being processed on an aarch64
# host — the tool only reads and rewrites bytes, never executes the
# input.
#
# See ./elf-page-shift.py for the full background, the eight layers
# of ELF state it updates in lockstep, and the lessons learned
# building it. See ../../../ELF-PAGE-SHIFT.md at the flake root for
# the long-form story.
#
# Implementation note: deliberately avoids nixpkgs `writers.write*`
# (which auto-lints) and `buildPythonApplication` (which expects
# setup.py metadata). The script's aligned-column layout is
# intentional for readability and not worth contorting for flake8;
# a plain stdenv wrapper around `makeWrapper` gives us a clean
# PYTHONPATH injection with zero policy decisions.
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "elf-page-shift";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [ python3 python3Packages.pyelftools ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/libexec $out/bin
    install -m 0755 $src/elf-page-shift.py $out/libexec/elf-page-shift
    makeWrapper ${python3}/bin/python3 $out/bin/elf-page-shift \
      --add-flags $out/libexec/elf-page-shift \
      --prefix PYTHONPATH : ${python3Packages.pyelftools}/${python3.sitePackages}
    runHook postInstall
  '';

  meta = {
    description = "Re-align ELF64 PT_LOAD segments to a larger page size by shifting all VAs in lockstep";
    longDescription = ''
      Rewrites a closed-source ELF64 shared object so its PT_LOAD
      segments are file-offset-aligned to 16 KiB, enabling load on
      kernels configured with CONFIG_PAGE_SHIFT=14 (Raspberry Pi 5
      vendor kernel, Asahi Linux on Apple Silicon, etc.).

      Unlike `patchelf --page-size` and Android's 16KB-compat tools
      (which only rewrite the p_align header field), this tool
      actually relocates segment content and updates every absolute
      VA in the binary in lockstep: symbol values, relocation
      r_offsets / r_addends, dynamic-section pointers, the entry
      point, and — crucially — link-time-baked .got.plt entries used
      by lazy PLT binding.

      The output works on both 4K-page and 16K-page kernels (a
      16K-aligned segment is also 4K-aligned), so consumers can
      unconditionally feed all their ELFs through this tool.
    '';
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "elf-page-shift";
  };
})
