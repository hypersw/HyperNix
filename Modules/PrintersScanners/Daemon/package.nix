{ pkgs, sharedPackage }:

let
  # Generate C# source with full nix store paths to native tools.
  # Baked into the DLL at build time — ensures GC roots, no PATH reliance.
  toolPathsCs = pkgs.writeText "ToolPaths.g.cs" ''
    namespace PrintScan.Daemon;

    /// <summary>
    /// Full paths to native tools, injected at nix build time.
    /// These are nix store paths — deterministic and GC-rooted by this derivation.
    /// </summary>
    static class ToolPaths
    {
        public static readonly string LpStat = "${pkgs.cups}/bin/lpstat";
        public static readonly string Lp = "${pkgs.cups}/bin/lp";
        public static readonly string ScanImage = "${pkgs.sane-backends}/bin/scanimage";
    }
  '';
in

pkgs.buildDotnetModule {
  pname = "printscan-daemon";
  version = "0.1.0";
  src = ./src;
  projectFile = "PrintScan.Daemon.csproj";
  dotnet-sdk = pkgs.dotnet-sdk_10;
  dotnet-runtime = pkgs.dotnet-aspnetcore_10;
  nugetDeps = ./deps.json;

  postPatch = ''
    substituteInPlace PrintScan.Daemon.csproj \
      --replace '$(PRINTSCAN_SHARED_DLL)' '${sharedPackage}/lib/printscan-shared'
    cp ${toolPathsCs} ToolPaths.g.cs
  '';

  # Copy shared DLL to output so it's available at runtime
  postInstall = ''
    cp ${sharedPackage}/lib/printscan-shared/PrintScan.Shared.dll $out/lib/printscan-daemon/
  '';
}
