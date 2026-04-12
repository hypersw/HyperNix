{ pkgs }:

pkgs.buildDotnetModule {
  pname = "printscan-shared";
  version = "0.1.0";
  src = ./src;
  projectFile = "PrintScan.Shared.csproj";
  dotnet-sdk = pkgs.dotnet-sdk_10;
  dotnet-runtime = pkgs.dotnet-runtime_10;
  nugetDeps = ./deps.json;

  # Class library — no executable, just the DLL
  packNupkg = false;
  executables = [];
}
