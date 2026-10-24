# Mirror Margin is intentionally a static browser application.  The package
# builds the bundled assets, then exposes a small loopback-only launcher so it
# can be opened with `nix run` without adding a web service to the project.
{ pkgs }:

let
  lib = pkgs.lib;
  source = lib.cleanSourceWith {
    src = ./.;
    filter = path: type:
      let name = baseNameOf (toString path);
      in name != "node_modules" && name != "dist";
  };
  staticSite = pkgs.buildNpmPackage {
    pname = "mirror-margin-static";
    version = "0.1.0";
    src = source;
    npmDepsHash = "sha256-/E5vRul07OWA7bxS/M+OVmcgrCVZ2oGMsvmujiO2Iro=";
    npmBuildScript = "build";
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -r dist/. "$out/"
      runHook postInstall
    '';
  };
  siteVersion = builtins.substring 11 32 (toString staticSite);
in
pkgs.writeShellApplication {
  name = "mirror-margin";
  runtimeInputs = [ pkgs.coreutils pkgs.python3 pkgs.xdg-utils ];
  text = ''
    port="''${PORT:-8000}"
    case "$port" in
      *[!0-9]*) echo "PORT must be a number" >&2; exit 2 ;;
    esac
    run_id="$(date +%s%N)"
    url="http://127.0.0.1:$port/?v=${siteVersion}&run=$run_id"
    python3 -c '
import functools
import http.server
import sys

class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

server = http.server.ThreadingHTTPServer(
    ("127.0.0.1", int(sys.argv[1])),
    functools.partial(Handler, directory=sys.argv[2]),
)
server.serve_forever()
' "$port" ${staticSite} &
    server_pid=$!
    trap 'kill "$server_pid" 2>/dev/null || true' EXIT INT TERM
    sleep 0.2
    if ! kill -0 "$server_pid" 2>/dev/null; then
      echo "Could not start Mirror Margin on 127.0.0.1:$port (is another server already using it?)" >&2
      wait "$server_pid"
      exit 1
    fi
    echo "Mirror Margin is running at $url"
    if [ "''${NO_BROWSER:-0}" != 1 ]; then
      xdg-open "$url" >/dev/null 2>&1 || echo "Could not open a browser automatically; open $url yourself." >&2
    fi
    wait "$server_pid"
  '';
  meta = {
    description = "Local parallel-text reader with logical-position synchronization";
    mainProgram = "mirror-margin";
  };
}
