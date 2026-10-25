# Builds a JetBrains IDE from its Linux tarball (.tar.gz) as a proper Nix package, with no nix-ld.
#
# Goes through nixpkgs' own `jetbrains.mkJetBrainsProduct`, the builder behind pkgs.intellij-idea, pkgs.rider and the rest.
# That gives wrapped launchers, a desktop entry, icons, and nixpkgs' fsnotifier and libdbm, all maintained upstream.
# Nothing is configured per IDE: names, launcher, WM class and vmoptions come from the tarball's own product-info.json.
# Reading that file is an import-from-derivation of a tiny extraction step.
#
# Binaries the IDE downloads at run time (language servers, SDKs, toolchains) are out of reach here and still need nix-ld.
# Used by the drop-in flake in `Template/` and by the file-reference runner in `run.nix`.
{ pkgs
, src
  # The JBR inside the tarball, patched for Nix; a dev or EAP build may depend on exactly that runtime.
  # `false` switches to nixpkgs' `jetbrains.jdk`, which usually lags behind.
, useBundledJbr ? true
, extraLdPath ? [ ]
, extraWrapperArgs ? [ ]
, extraBuildInputs ? [ ]
}:
let
  inherit (pkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;
  arch = {
    x86_64-linux = "amd64";
    aarch64-linux = "aarch64";
  }.${system} or (throw "Unsupported system: ${system}");

  info = lib.importJSON (pkgs.runCommand "product-info.json" { } ''
    tar -xzf ${src} -O \
      --wildcards \
      --no-wildcards-match-slash \
      '*/product-info.json' > $out
  '');
  launch = lib.findFirst
    (l: (l.os == "Linux") && (l.arch == arch))
    (throw "product-info.json has no Linux/${arch} launch entry")
    info.launch;

  # The builder derives the launcher name, the vmoptions file and the *_VM_OPTIONS variable from productShort.
  launcherName = baseNameOf launch.launcherPath;
  pname = lib.toLower (lib.replaceStrings [ " " ] [ "-" ] info.name);
  version = "${info.version}${lib.optionalString (info ? versionSuffix) "-${info.versionSuffix}"}-${info.buildNumber}";

  bundledJbr = pkgs.stdenv.mkDerivation (finalAttrs: {
    pname = "${pname}-jbr";
    inherit version src;

    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = with pkgs; [
      alsa-lib
      fontconfig
      freetype
      libx11
      libxext
      libxi
      libxrender
      libxtst
      libxrandr
      libxcb
      libxkbcommon
      wayland
      zlib
      stdenv.cc.cc
    ];
    # AWT and its Wayland toolkit dlopen these rather than link them, so DT_NEEDED never names them.
    runtimeDependencies = with pkgs; [
      fontconfig
      libGL
      vulkan-loader # JBR's Vulkan pipeline (-Dsun.java2d.vulkan=true); the ICDs come from hardware.graphics
      libxkbcommon
      wayland
      libx11
      libxcursor
      libxxf86vm
      libdrm
      libgbm
      cups
      gtk3
      udev
    ];

    unpackPhase = ''
      tar -xzf $src --strip-components=1 --wildcards '*/jbr/*'
    '';
    installPhase = ''
      cp -a jbr $out
    '';

    # mkJetBrainsProduct reads the JDK's root from `home`, as on nixpkgs' JDK packages.
    passthru.home = "${finalAttrs.finalPackage}";
  });
in
assert lib.assertMsg
  (baseNameOf launch.vmOptionsFilePath == "${launcherName}64.vmoptions")
  "Unexpected vmoptions file name ${launch.vmOptionsFilePath} for launcher ${launcherName}";
pkgs.jetbrains.mkJetBrainsProduct {
  inherit pname version src;
  inherit (pkgs) jetbrains-libdbm fsnotifier;
  inherit (info) buildNumber;

  product = info.name;
  productShort = launcherName;
  wmClass = launch.startupWmClass;

  jdk = if useBundledJbr then bundledJbr else pkgs.jetbrains.jdk;

  # Natives the IDE unpacks from its jars at run time stay unpatched; they resolve their deps through this.
  extraLdPath = with pkgs; [
    stdenv.cc.cc
    zlib
    libGL
    fontconfig
    freetype
    libxkbcommon
    wayland
  ] ++ extraLdPath;
  inherit extraWrapperArgs;
  buildInputs = extraBuildInputs;

  meta = {
    description = "${info.name} ${info.version} (${info.buildNumber}) from a JetBrains tarball";
    longDescription = "${info.name} IDE by ${info.productVendor or "JetBrains"}, packaged from its Linux tarball.";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryBytecode ];
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
