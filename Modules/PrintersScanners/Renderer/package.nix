{ pkgs }:

let
  # Generate C# source with the full nix-store path to soffice. Baked
  # into the assembly at build time — same GC-rooted pattern the
  # daemon uses for scanimage and lp.
  toolPathsCs = pkgs.writeText "ToolPaths.g.cs" ''
    namespace PrintScan.Renderer;

    static class ToolPaths
    {
        public static readonly string Soffice =
            "${pkgs.libreoffice}/bin/soffice";
    }
  '';
in

pkgs.buildDotnetModule {
  pname = "printscan-renderer";
  version = "0.1.0";
  src = ./src;
  projectFile = "PrintScan.Renderer.csproj";
  dotnet-sdk = pkgs.dotnet-sdk_10;
  dotnet-runtime = pkgs.dotnet-aspnetcore_10;
  nugetDeps = ./deps.json;

  postPatch = ''
    cp ${toolPathsCs} ToolPaths.g.cs
  '';

  # Pin libreoffice as a runtime dep so it's part of the package
  # closure — the systemd unit doesn't otherwise reference it.
  passthru.libreoffice = pkgs.libreoffice;
}
