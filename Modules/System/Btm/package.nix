# Derivation builder for the bottom strict-overcommit fork.
#
# Self-contained: the version, source, dependency hash and build recipe all live in this folder.
# A nixpkgs bump therefore only moves the Rust toolchain and stdenv underneath, never the fork's inputs.
# It deliberately does not override `pkgs.bottom`.
# Such an override inherits nixpkgs' `version` and `cargoHash`, which stop matching the fork whenever nixpkgs moves bottom forward.
# The vendored-crates derivation even keeps its old store path then, so Nix substitutes upstream's crates instead of reporting a hash mismatch.
#
# The recipe mirrors nixpkgs' pkgs/by-name/bo/bottom/package.nix as of 0.14.9.
# Used by both the NixOS module (`default.nix`, with `src = cfg.fork.src`) and the flake's packages output (pinned source).
let
  pin = import ./source.nix;
in
{ pkgs
, src ? pkgs.fetchFromGitHub pin.src
  # Must match `src`'s Cargo.lock.
  # A local `src` whose lock differs from the pin's needs its own hash here.
, cargoHash ? pin.cargoHash
}:
pkgs.rustPlatform.buildRustPackage {
  # A pname of its own keeps the fork and its vendored crates apart from upstream `pkgs.bottom` in the store.
  pname = "bottom-strict-overcommit";
  # `versionCheckHook` greps `btm --version` for this.
  # So it must be the fork's own `CARGO_PKG_VERSION`, with no suffix.
  inherit (pin) version;
  inherit src cargoHash;

  nativeBuildInputs = [
    pkgs.autoAddDriverRunpath # NVML is dlopen'ed for the GPU widgets
    pkgs.installShellFiles
  ];

  # Makes build.rs write the completions and the manpage under target/tmp/bottom.
  env.BTM_GENERATE = true;

  postInstall = ''
    installManPage target/tmp/bottom/manpage/btm.1
    installShellCompletion \
      target/tmp/bottom/completion/btm.{bash,fish} \
      --zsh target/tmp/bottom/completion/_btm

    install -Dm444 desktop/bottom.desktop -t $out/share/applications
    install -Dm644 assets/icons/bottom-system-monitor.svg -t $out/share/icons/hicolor/scalable/apps
  '';

  checkFlags = pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
    # The sandbox hides the process list; this works at runtime.
    "--skip=collection::tests::test_data_collection"
  ];

  doInstallCheck = true;
  nativeInstallCheckInputs = [
    pkgs.versionCheckHook
    pkgs.writableTmpDirAsHomeHook
  ];
  versionCheckProgram = "${placeholder "out"}/bin/btm";

  meta = {
    description = "bottom (btm) with per-process commit and footprint columns for strict-overcommit hosts";
    homepage = "https://github.com/hypersw/bottom";
    license = pkgs.lib.licenses.mit;
    mainProgram = "btm";
  };
}
