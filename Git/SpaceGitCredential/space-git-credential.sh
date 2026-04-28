# Git credential helper for JetBrains Space.
# Obtains an OAuth token via browser, then mints a 1h permanent token
# that git can use for HTTPS authentication.

action="${1:-}"

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
if [[ "${input[host]:-}" != *"jetbrains.team"* ]]; then
  exit 0
fi

# Step 1: Get a Space OAuth access token via browser.
#
# Pick a free localhost port for the OAuth callback — the IntelliJ Space
# plugin uses dynamic ports, and Space accepts any localhost:<port>
# redirect for the space-idea-app client (RFC 8252). A hardcoded 8080
# was prone to collisions with other services on the user's machine.
oauth_port=
for _ in $(seq 1 50); do
  candidate=$((RANDOM % 16384 + 49152))  # IANA ephemeral range
  if ! (echo > /dev/tcp/127.0.0.1/$candidate) 2>/dev/null; then
    oauth_port=$candidate
    break
  fi
done
if [[ -z "$oauth_port" ]]; then
  echo "space-git-credential: failed to find a free localhost port for OAuth callback" >&2
  exit 1
fi

# --silent makes oauth2c emit only the final JSON on stdout (without it,
# stdout is mixed prose + JSON, which breaks jq).
oauth2c_stderr=$(mktemp)
trap 'rm -f "$oauth2c_stderr"' EXIT
oauth_response=$(oauth2c https://jetbrains.team \
  --client-id "space-idea-app" \
  --client-secret "space-idea-app-secret" \
  --grant-type authorization_code \
  --response-types code \
  --response-mode query \
  --scopes "**" \
  --pkce \
  --auth-method client_secret_basic \
  --callback-addr "127.0.0.1:$oauth_port" \
  --redirect-url "http://localhost:$oauth_port/api/space/oauth/authorization_code" \
  --authorization-endpoint "https://jetbrains.team/oauth/auth" \
  --token-endpoint "https://jetbrains.team/oauth/token" \
  --silent \
  --no-prompt 2>"$oauth2c_stderr") || true

access_token=$(printf '%s' "$oauth_response" | jq -r '.access_token // empty' 2>/dev/null || true)

if [[ -z "$access_token" ]]; then
  echo "space-git-credential: failed to obtain OAuth token" >&2
  echo "space-git-credential: oauth2c stdout was:" >&2
  printf '%s\n' "$oauth_response" >&2
  echo "space-git-credential: oauth2c stderr was:" >&2
  cat "$oauth2c_stderr" >&2
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
