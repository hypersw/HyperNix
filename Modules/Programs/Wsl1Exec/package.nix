{ lib
, stdenv
, fetchFromGitHub
, gnumake
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "wsl1-nix-exec";
  version = "80fe074c";

  # Pinned to the reviewed source revision. The fixed hash means evaluation
  # and builds never follow the remote repository's branch tip.
  src = fetchFromGitHub {
    owner = "Wenri";
    repo = "wsl1-exec";
    rev = "80fe074c773bd1428e2f09c7eae9e40cf288eec4";
    hash = "sha256-setbYgjOk4d8PArVvyUTrM54LL3gXjfAULHaq2DbrnY=";
  };

  nativeBuildInputs = [ gnumake ];

  buildPhase = ''
    runHook preBuild
    make nix-wsl1-exec.so \
      HAVE_EXEC=1 \
      HAVE_SELFEXE=1 \
      HAVE_MMAP=0 \
      HAVE_BIND_REWRITE=0
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 nix-wsl1-exec.so "$out/lib/nix-wsl1-exec.so"
    runHook postInstall
  '';

  meta = {
    description = "Minimal WSL 1 ENOEXEC rescue preload for Nix-built ELF programs";
    homepage = "https://github.com/Wenri/wsl1-exec";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" ];
  };
})
