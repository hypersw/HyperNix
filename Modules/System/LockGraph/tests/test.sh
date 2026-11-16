#!/usr/bin/env bash
set -euo pipefail
base=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
inputs='["nixpkgs","nixos-hardware","nixos-raspberrypi","upstream"]'
jq --argjson new '[]' --arg mode candidate-promote --argjson inputs "$inputs" -f "$base/lock-graph.jq" "$base/tests/fixture.json" >"$tmp"
test "$(jq -r '.nodes.nixpkgs_5.locked.rev' "$tmp")" = new
test "$(jq -r '.nodes["nixos-raspberrypi"].inputs.nixpkgs' "$tmp")" = promoted-rpi-new-pkgs
test "$(jq -r '.nodes["promoted-rpi-new-pkgs"].locked.rev' "$tmp")" = new
test "$(jq -r '.nodes.upstream.inputs.nixpkgs[0]' "$tmp")" = nixpkgs
test "$(jq -r '.nodes["nixos-raspberrypi-candidate"].inputs.nixpkgs' "$tmp")" = rpi-new-pkgs
candidates='["nixpkgs-candidate","nixos-hardware-candidate","nixos-raspberrypi-candidate","upstream-candidate"]'
jq --slurpfile new "$tmp" --arg mode sandbox-promote --argjson inputs "$inputs" --argjson candidates "$candidates" -f "$base/lock-graph.jq" "$base/tests/fixture.json" >"$tmp.sandbox"
test "$(jq -r '.nodes.nixpkgs_5.locked.rev' "$tmp.sandbox")" = new

# A changed candidate closure must refuse the promotion.
jq '.nodes["rpi-new-pkgs"].locked.rev = "moved"' "$tmp" >"$tmp.moved"
if jq --slurpfile new "$tmp.moved" --arg mode sandbox-promote --argjson inputs "$inputs" --argjson candidates "$candidates" -f "$base/lock-graph.jq" "$base/tests/fixture.json" >/dev/null 2>&1; then
  echo "sandbox-promote accepted a changed candidate closure" >&2; exit 1
fi

# A lock without candidate inputs promotes when no candidates are named.
no_candidates='.nodes.root.inputs |= with_entries(select(.key | endswith("-candidate") | not))'
jq "$no_candidates" "$base/tests/fixture.json" >"$tmp.live"
jq "$no_candidates" "$tmp" >"$tmp.new"
jq --slurpfile new "$tmp.new" --arg mode sandbox-promote --argjson inputs "$inputs" -f "$base/lock-graph.jq" "$tmp.live" >"$tmp.sandbox"
test "$(jq -r '.nodes.nixpkgs_5.locked.rev' "$tmp.sandbox")" = new
# A baked first-boot lock lacks the Pi input and the candidates; the sandbox
# has locked them. The promotion adopts the Pi input and skips the
# candidates the live lock does not have.
baked='.nodes.root.inputs |= with_entries(select(.key == "nixpkgs" or .key == "nixos-hardware" or .key == "upstream"))'
jq "$baked" "$base/tests/fixture.json" >"$tmp.live"
jq --slurpfile new "$tmp" --arg mode sandbox-promote --argjson inputs "$inputs" --argjson candidates "$candidates" -f "$base/lock-graph.jq" "$tmp.live" >"$tmp.sandbox"
test "$(jq -r '.nodes.root.inputs["nixos-raspberrypi"]' "$tmp.sandbox")" = "$(jq -r '.nodes.root.inputs["nixos-raspberrypi"]' "$tmp")"
test "$(jq -r '.nodes.root.inputs["nixpkgs-candidate"] // "absent"' "$tmp.sandbox")" = absent
test "$(jq -r '.nodes.nixpkgs_5.locked.rev' "$tmp.sandbox")" = new
rm -f "$tmp.sandbox" "$tmp.moved" "$tmp.live" "$tmp.new"
echo "lock-graph tests passed"
