{ pkgs }:
pkgs.writeShellApplication {
  name = "hypersw-rdp-output-lifecycle";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.gawk
    pkgs.jq
    pkgs.kdePackages.kconfig
    pkgs.kdePackages.libkscreen
    pkgs.systemd
  ];
  text = ''
    set -euo pipefail

    action="''${1:?expected lifecycle action}"
    rdp_output="''${2:?expected virtual-output name}"
    stub_output="Virtual-0"
    panel_config="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"

    output_state() {
      kscreen-doctor --json
    }

    wait_for_rdp_output() {
      for ((attempt = 0; attempt < 20; attempt += 1)); do
        if output_state | jq -e --arg name "$rdp_output" '
          any(.outputs[]; .name == $name and .connected and .enabled)
        ' >/dev/null; then
          return 0
        fi
        sleep 0.1
      done

      echo "Timed out waiting for enabled RDP output: $rdp_output" >&2
      return 1
    }

    wait_for_sole_rdp_output() {
      for ((attempt = 0; attempt < 20; attempt += 1)); do
        if output_state | jq -e --arg name "$rdp_output" '
          ([.outputs[] | select(.enabled)] | length == 1)
          and any(.outputs[]; .name == $name and .enabled)
        ' >/dev/null; then
          return 0
        fi
        sleep 0.1
      done

      echo "Timed out waiting for sole RDP output: $rdp_output" >&2
      return 1
    }

    repair_panels() {
      [ -f "$panel_config" ] || return 1

      local repaired=1
      while IFS= read -r containment; do
        [ -n "$containment" ] || continue
        current_screen=$(kreadconfig6 \
          --file "$panel_config" \
          --group Containments \
          --group "$containment" \
          --key lastScreen \
          --default 0)
        if [ "$current_screen" != "0" ]; then
          kwriteconfig6 \
            --file "$panel_config" \
            --group Containments \
            --group "$containment" \
            --key lastScreen \
            0
          repaired=0
        fi
      done < <(
        awk '
          /^\[Containments\]\[[0-9]+\]$/ {
            containment = $0
            sub(/^\[Containments\]\[/, "", containment)
            sub(/\]$/, "", containment)
          }
          /^plugin=org\.kde\.panel$/ && containment != "" {
            print containment
          }
        ' "$panel_config"
      )

      return "$repaired"
    }

    case "$action" in
      up)
        wait_for_rdp_output
        kscreen-doctor "output.$stub_output.disable"
        wait_for_sole_rdp_output
        if repair_panels; then
          systemctl --user restart isolated-rdp-wayland-plasma.service
        fi
        ;;
      down)
        kscreen-doctor "output.$stub_output.enable"
        ;;
      *)
        echo "Unknown KRdp output lifecycle action: $action" >&2
        exit 2
        ;;
    esac
  '';
}
