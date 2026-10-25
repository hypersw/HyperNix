# Mirror Margin is intentionally a static browser application.  The package
# builds the bundled assets, then exposes a small loopback-only launcher so it
# can be opened with `nix run` without adding a web service to the project.
{ pkgs }:

let
  lib = pkgs.lib;
  # When built under WSL, this package requires WSL 2: WSL 1 rejects this
  # Nix-built Node executable's large-alignment ELF layout with "Exec format error".
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
    npmDepsHash = "sha256-BkD3BYMkhuFVHwAC6pcnsERYS+KPK0u6IoKBZ7JEI5M=";
    npmBuildScript = "build";
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -r dist/. "$out/"
      runHook postInstall
    '';
  };
  portable = pkgs.runCommand "mirror-margin-portable" { } ''
    mkdir -p "$out/site" "$out/skills/dutch-word-explainer"
    cp -r ${staticSite}/. "$out/site/"
    cp ${./scripts/bridge.mjs} "$out/bridge.mjs"
    cp ${./skills/dutch-word-explainer/SKILL.md} "$out/skills/dutch-word-explainer/SKILL.md"
    cat > "$out/README.txt" <<'EOF'
Mirror Margin portable distribution

Requirements: Node.js and Codex CLI, logged in for the current user.

Run from this directory:
  node bridge.mjs --site site --port 8000

The launcher prints a loopback URL and opens it where the platform supports it.
Set NO_BROWSER=1 to print the URL only. The bridge uses the local user's Codex
login and sends only explicitly selected text.
EOF
  '';
  portableZip = pkgs.runCommand "mirror-margin-portable.zip" { nativeBuildInputs = [ pkgs.zip ]; } ''
    mkdir distribution
    cp -r ${portable}/. distribution/
    (cd distribution && zip -qr "$out" .)
  '';
in
pkgs.writeShellApplication {
  name = "mirror-margin";
  runtimeInputs = [ pkgs.codex pkgs.nodejs pkgs.xdg-utils ];
  text = ''
    port="''${PORT:-8000}"
    case "$port" in
      *[!0-9]*) echo "PORT must be a number" >&2; exit 2 ;;
    esac
    SITE_DIR=${staticSite} DUTCH_SKILL_PATH=${./skills/dutch-word-explainer/SKILL.md} node ${./scripts/bridge.mjs} --port "$port" &
    server_pid=$!
    trap 'kill "$server_pid" 2>/dev/null || true' EXIT INT TERM
    sleep 0.2
    if ! kill -0 "$server_pid" 2>/dev/null; then
      echo "Could not start Mirror Margin on 127.0.0.1:$port (is another server already using it?)" >&2
      wait "$server_pid"
      exit 1
    fi
    wait "$server_pid"
  '';
  passthru = { inherit staticSite portable portableZip; };
  meta = {
    description = "Local parallel-text reader with logical-position synchronization";
    mainProgram = "mirror-margin";
  };
}
