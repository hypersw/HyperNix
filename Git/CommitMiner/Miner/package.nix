# git-mine-commit — the nonce miner the patched git (../git.nix) calls.
#
# CPU search always works. The GPU backend reaches Vulkan through wgpu, which
# dlopen()s libvulkan.so.1 at runtime; the loader is put on the binary's
# RUNPATH instead of a wrapper's LD_LIBRARY_PATH, so git's other child
# processes do not inherit it. The ICDs themselves come from the host
# (/run/opengl-driver on NixOS). Without a usable GPU the miner stays on the CPU.
{ lib, rustPlatform, vulkan-loader, patchelf }:

rustPlatform.buildRustPackage {
  pname = "git-mine-commit";
  version = "0.1.0";

  # Only the crate sources; a local target/ must not leak into the store.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [ ./Cargo.toml ./Cargo.lock ./src ];
  };

  cargoLock.lockFile = ./Cargo.lock;

  nativeBuildInputs = [ patchelf ];

  postFixup = ''
    patchelf --add-rpath ${lib.makeLibraryPath [ vulkan-loader ]} $out/bin/git-mine-commit
  '';

  meta = {
    description = "Finds a commit nonce header value that gives the commit object a chosen hash prefix";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "git-mine-commit";
  };
}
