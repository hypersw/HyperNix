{
  description = "Git credential helper for JetBrains Space via OAuth";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # Wrap oauth2c with xdg-utils so it can open a browser
      # (nixpkgs doesn't include this yet)
      oauth2c-wrapped = pkgs.symlinkJoin {
        name = "oauth2c-wrapped";
        paths = [ pkgs.oauth2c ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postBuild = ''
          wrapProgram $out/bin/oauth2c \
            --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.xdg-utils ]}
        '';
      };
    in
    {
      prompt = ''
        Reverse-engineered from JetBrains IDE Space plugin (space.jar, space-idea-sdk.jar)
        using javap bytecode decompilation. Key finding: Space git server does NOT accept
        OAuth tokens directly — it requires "permanent tokens" obtained via a separate API.

        Auth chain discovered from SpaceGitHttpAuthDataProvider → SpaceGitTokenProvider
        → SpaceTokenProviderBase.requestNewToken → PersonalPermanentTokens.createPermanentToken:
          1. OAuth authorization_code+PKCE flow → short-lived access token (10 min)
             Client: space-idea-app / space-idea-app-secret (IntelliJ built-in, ** scope)
             Endpoints: jetbrains.team/oauth/auth, jetbrains.team/oauth/token
             Redirect: http://localhost:8080/api/space/oauth/authorization_code
          2. POST /api/http/team-directory/profiles/me/permanent-tokens → permanent token
             Scope: global:VcsRepository.Read global:VcsRepository.Write
             Response is a Pair: .first = metadata, .second = token string
          3. Git credentials: username=oauth, password=<permanent token>

        The "oauth" username was found as a string literal (ldc #181) in SpaceGitHttpAuthDataProvider
        bytecode. The endpoint path was traced through PersonalPermanentTokensProxy in
        space-idea-sdk.jar. Multiple wrong paths were tried first (/api/http/personal-tokens,
        /api/http/me/permanent-tokens, /api/http/profiles/me/permanent-tokens) before finding
        the correct /api/http/team-directory/profiles/me/permanent-tokens.

        oauth2c wrapping: nixpkgs oauth2c is missing xdg-utils runtime dep (needs xdg-open
        for browser). Wrapped via symlinkJoin+makeWrapper until nixpkgs is patched.

        Git config integration (in Git.Work.Config):
          [credential "https://git.jetbrains.team"]
              helper = cache --timeout=3600
              helper = !nix run <this flake> --
        Cache helper is tried first; this helper is the fallback on miss. On success,
        git sends "store" to cache, so subsequent fetches within 1h hit cache (no browser).
      '';

      packages.${system}.default = pkgs.writeShellApplication {
        name = "space-git-credential";

        excludeShellChecks = [ "SC1091" ];

        runtimeInputs = [ oauth2c-wrapped pkgs.jq pkgs.curl pkgs.coreutils ];

        text = ''
          # Git credential helper for JetBrains Space.
          # Obtains an OAuth token via browser, then mints a 1h permanent token
          # that git can use for HTTPS authentication.

          action="''${1:-}"

          # Only respond to "get"; no-op store/erase
          if [[ "$action" != "get" ]]; then
            exit 0
          fi

          # Read the credential protocol input from stdin
          declare -A input
          while IFS='=' read -r key value; do
            [[ -z "$key" ]] && break
            input["$key"]="$value"
          done

          # Only handle requests for Space
          if [[ "''${input[host]:-}" != *"jetbrains.team"* ]]; then
            exit 0
          fi

          # Step 1: Get a Space OAuth access token via browser
          oauth_response=$(oauth2c https://jetbrains.team \
            --client-id "space-idea-app" \
            --client-secret "space-idea-app-secret" \
            --grant-type authorization_code \
            --response-types code \
            --response-mode query \
            --scopes "**" \
            --pkce \
            --auth-method client_secret_basic \
            --redirect-url "http://localhost:8080/api/space/oauth/authorization_code" \
            --authorization-endpoint "https://jetbrains.team/oauth/auth" \
            --token-endpoint "https://jetbrains.team/oauth/token" \
            --no-prompt 2>/dev/null) || true

          access_token=$(echo "$oauth_response" | jq -r '.access_token // empty')

          if [[ -z "$access_token" ]]; then
            echo "space-git-credential: failed to obtain OAuth token" >&2
            exit 1
          fi

          # Step 2: Build a descriptive token name
          hostname=$(hostname)
          os_id=$(. /etc/os-release 2>/dev/null && echo "$NAME $VERSION_ID" || echo "Linux")
          kernel=$(uname -r)
          token_name="Git Transient Credential - Host $hostname running $os_id $kernel"

          # Step 3: Mint a 1-hour permanent token via Space API
          expires=$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ')
          response=$(curl -s --fail-with-body "https://jetbrains.team/api/http/team-directory/profiles/me/permanent-tokens" \
            -H "Authorization: Bearer $access_token" \
            -H "Content-Type: application/json" \
            -d "$(jq -n --arg name "$token_name" --arg expires "$expires" '{
              name: $name,
              scope: "global:VcsRepository.Read global:VcsRepository.Write",
              expires: $expires
            }')") || true

          permanent_token=$(echo "$response" | jq -r '.second')

          if [[ -z "$permanent_token" || "$permanent_token" == "null" ]]; then
            echo "space-git-credential: failed to mint permanent token" >&2
            echo "space-git-credential: API response: $response" >&2
            exit 1
          fi

          # Step 4: Output credentials per git protocol
          echo "username=oauth"
          echo "password=$permanent_token"
        '';
      };
    };
}
