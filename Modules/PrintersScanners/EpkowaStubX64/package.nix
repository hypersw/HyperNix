{ lib, rustPlatform }:

# Plain Rust package — architecture-agnostic. Consumers that want the x86_64
# build on an aarch64 host should invoke via `pkgsCross.gnu64.callPackage`;
# rustPlatform handles cross-compilation natively (rustc runs on the host
# arch, emits the target arch). No qemu needed at build time.
rustPlatform.buildRustPackage {
  pname = "epkowa-stub-x64";
  version = "0.1.0";

  src = lib.cleanSource ./.;

  cargoLock.lockFile = ./Cargo.lock;

  # Minimal pure-Rust stub: only libc (FFI) and libloading (dlopen). Neither
  # needs native build-time deps beyond a libc, which rustPlatform provides.

  meta = {
    description = "x86_64 shim that lets aarch64 SANE/epkowa use the proprietary interpreter plugin over Unix-socket IPC";
    license = lib.licenses.gpl2Plus;
    # Runs under qemu-user binfmt — the BINARY is x86_64 but the package can
    # be built for any target rustPlatform supports.
    platforms = lib.platforms.linux;
  };
}
