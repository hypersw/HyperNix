#!/usr/bin/env bash
set -euo pipefail

# The Podman store, container state, and build scratch space are all temporary.
output_dir="$PWD/ubuntu-live-output"
resolution="$LIVE_RESOLUTION"
scale="$LIVE_SCALE"
while (( $# )); do
  case "$1" in
    --output) output_dir="${2:?missing output directory}"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
if [[ "$resolution" != auto && ! "$resolution" =~ ^[1-9][0-9]{2,4}x[1-9][0-9]{2,4}$ ]]; then
  echo "Resolution must be auto or WIDTHxHEIGHT (for example 1920x1080)" >&2
  exit 2
fi
if [[ "$scale" != 1 && "$scale" != 2 ]]; then
  echo "Scale must be 1 or 2" >&2; exit 2
fi
if [[ "$scale" != 1 && "$resolution" == auto ]]; then
  echo "A scale other than 1 requires GNOME and an explicit resolution" >&2; exit 2
fi
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/ubuntu-live.XXXXXXXX")"
cleanup() {
  podman --root "$scratch/store" --runroot "$scratch/run" --storage-driver vfs \
    unshare rm -rf "$scratch" || echo "Could not clean temporary directory: $scratch" >&2
}
trap cleanup EXIT
mkdir -p "$scratch/config/containers" "$scratch/output"
cp "$LIVE_SOURCE/policy.json" "$scratch/config/containers/policy.json"
export XDG_CONFIG_HOME="$scratch/config"

podman --root "$scratch/store" --runroot "$scratch/run" --storage-driver vfs \
  run --rm --privileged --network host --pid host \
  -v "$scratch/output:/output" -v "$LIVE_SOURCE:/source:ro" \
  -v "$LIVE_CONFIG:/config.json:ro" -v "$LIVE_EXTRA_FILES:/extra-files:ro" \
  docker.io/library/ubuntu@sha256:262df65c0ec6bf8d9dcc87454f4330a05fae4b97825f45854af3b136666584c2 \
  bash /source/build-inside.sh "$resolution" "$scale"

iso_name="ubuntu-live-gnome-${resolution}.iso"
if [[ "$scale" != 1 ]]; then
  iso_name="ubuntu-live-gnome-${resolution}-scale${scale}.iso"
fi
cp "$scratch/output/ubuntu-live.iso" "$output_dir/$iso_name"
(cd "$output_dir" && sha256sum "$iso_name" > "$iso_name.sha256")
echo "ISO: $output_dir/$iso_name"
