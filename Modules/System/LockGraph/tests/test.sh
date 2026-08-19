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
jq --slurpfile new "$tmp" --arg mode sandbox-promote --argjson inputs "$inputs" -f "$base/lock-graph.jq" "$base/tests/fixture.json" >"$tmp.sandbox"
test "$(jq -r '.nodes.nixpkgs_5.locked.rev' "$tmp.sandbox")" = new
rm -f "$tmp.sandbox"
