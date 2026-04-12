{ pkgs, sharedPackage }:

pkgs.buildDotnetModule {
  pname = "printscan-telegram-bot";
  version = "0.1.0";
  src = ./src;
  projectFile = "PrintScan.TelegramBot.csproj";
  dotnet-sdk = pkgs.dotnet-sdk_10;
  dotnet-runtime = pkgs.dotnet-runtime_10;
  nugetDeps = ./deps.json;

  # Inject shared DLL path — csproj reads $(PRINTSCAN_SHARED_DLL)
  postPatch = ''
    substituteInPlace PrintScan.TelegramBot.csproj \
      --replace '$(PRINTSCAN_SHARED_DLL)' '${sharedPackage}/lib/printscan-shared'
  '';

  # Copy shared DLL to output so it's available at runtime
  postInstall = ''
    cp ${sharedPackage}/lib/printscan-shared/PrintScan.Shared.dll $out/lib/printscan-telegram-bot/
  '';
}
