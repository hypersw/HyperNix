#!/usr/bin/env bash
set -u
resolution="${1:?missing resolution}"
scale="${2:?missing scale}"

# This configuration is intended for a single Hyper-V virtual display.
[[ "$(systemd-detect-virt 2>/dev/null)" == microsoft ]] || exit 0
for attempt in {1..20}; do
  output="$(gdctl show --modes 2>/dev/null)" || { sleep 1; continue; }
  if [[ "$output" != *Virtual-1* ]]; then sleep 1; continue; fi
  mode="$(printf '%s\n' "$output" | sed -nE "s/.*(${resolution}@[0-9]+([.][0-9]+)?).*/\\1/p" | head -n 1)"
  if [[ -z "$mode" ]]; then sleep 1; continue; fi
  args=(--logical-monitor --primary --scale "$scale" --monitor Virtual-1 --mode "$mode")
  if gdctl set --verify "${args[@]}" && gdctl set "${args[@]}"; then
    exit 0
  fi
  break
done
logger -t ubuntu-live-display "Could not apply ${resolution} at scale ${scale}; leaving the current display configuration"
