# space-git-credential

Git credential helper for JetBrains Space via OAuth. Obtains a short-lived
OAuth access token via browser, mints a 1-hour permanent token via the Space
API, and emits credentials to git:

    username=oauth
    password=<permanent token>

## Why This Exists

The Space git server does **not** accept OAuth tokens directly — it requires
"permanent tokens" obtained via a separate API endpoint. So the naive
"get OAuth access token, use it as git password" flow doesn't work; a second
API round-trip is required.

## Auth Chain

Reverse-engineered from the JetBrains IDE Space plugin
(`space.jar`, `space-idea-sdk.jar`) via `javap` bytecode decompilation:

    SpaceGitHttpAuthDataProvider
      → SpaceGitTokenProvider
      → SpaceTokenProviderBase.requestNewToken
      → PersonalPermanentTokens.createPermanentToken

Three steps at runtime:

1. **OAuth authorization_code + PKCE → short-lived access token** (10 min)
   - Client: `space-idea-app` / `space-idea-app-secret` (IntelliJ built-in, `**` scope)
   - Endpoints: `jetbrains.team/oauth/auth`, `jetbrains.team/oauth/token`
   - Redirect: `http://localhost:8080/api/space/oauth/authorization_code`

2. **`POST /api/http/team-directory/profiles/me/permanent-tokens`** → permanent token
   - Scope: `global:VcsRepository.Read global:VcsRepository.Write`
   - Response is a `Pair`: `.first` = metadata, `.second` = token string

3. **Return `username=oauth`, `password=<permanent token>`** via git credential protocol

## Bytecode Trivia

- The literal `"oauth"` username was found as a string constant (`ldc #181`)
  in `SpaceGitHttpAuthDataProvider`.
- The endpoint path was traced through `PersonalPermanentTokensProxy` in
  `space-idea-sdk.jar`. Several wrong paths were tried before the right one:
  `/api/http/personal-tokens`, `/api/http/me/permanent-tokens`,
  `/api/http/profiles/me/permanent-tokens` — the correct path is
  `/api/http/team-directory/profiles/me/permanent-tokens`.

## Integration

In the git config for Space URLs:

    [credential "https://git.jetbrains.team"]
        provider = generic
        helper = cache --timeout=3600
        helper = !nix run github:hypersw/HyperNix#Git-SpaceGitCredential --

The `cache` helper is tried first; this helper is the fallback on cache miss.
On success, git sends `store` to the cache, so subsequent fetches within the
cache timeout hit the cache and avoid the browser round-trip.

## oauth2c Wrapping

`nixpkgs.oauth2c` is missing an `xdg-utils` runtime dep (it needs `xdg-open` to
launch a browser). `package.nix` wraps it via `symlinkJoin` + `makeWrapper`
until the upstream nixpkgs package is patched.
