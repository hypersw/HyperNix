{ pkgs, sharedPackage }:

let
  # Generate C# source with the full nix store path to the overlay font.
  # Baked into the DLL at build time — ensures GC roots, no fontconfig
  # lookup at runtime, no PATH reliance.
  toolPathsCs = pkgs.writeText "ToolPaths.g.cs" ''
    namespace PrintScan.TelegramBot;

    /// <summary>
    /// Full paths to bundled assets, injected at nix build time. These
    /// are nix store paths — deterministic and GC-rooted by this
    /// derivation.
    /// </summary>
    static class ToolPaths
    {
        // TTF used by ImagePipeline to overlay labels on thumbnails.
        // DejaVu Sans is public-domain, ~750 KB on disk, rendered via
        // SixLabors.ImageSharp.Drawing.
        public static readonly string OverlayFont = "${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSans.ttf";
    }
  '';
in

pkgs.buildDotnetModule {
  pname = "printscan-telegram-bot";
  version = "0.1.0";
  src = ./src;
  projectFile = "PrintScan.TelegramBot.csproj";
  dotnet-sdk = pkgs.dotnet-sdk_10;
  dotnet-runtime = pkgs.dotnet-runtime_10;
  nugetDeps = ./deps.json;

  # Inject shared DLL path — csproj reads $(PRINTSCAN_SHARED_DLL).
  postPatch = ''
    substituteInPlace PrintScan.TelegramBot.csproj \
      --replace '$(PRINTSCAN_SHARED_DLL)' '${sharedPackage}/lib/printscan-shared'
    cp ${toolPathsCs} ToolPaths.g.cs
  '';

  # Copy shared DLL to output so it's available at runtime
  postInstall = ''
    cp ${sharedPackage}/lib/printscan-shared/PrintScan.Shared.dll $out/lib/printscan-telegram-bot/
  '';
}
