{ pkgs, PlasmaShellService }:
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
    plasma_shell_service="${PlasmaShellService}"
    panel_config="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"

    output_state() {
      kscreen-doctor --json
    }

    stub_output_enabled() {
      output_state | jq -e --arg name "$stub_output" '
        any(.outputs[]; .name == $name and .enabled)
      ' >/dev/null
    }

    stub_output_disabled() {
      output_state | jq -e --arg name "$stub_output" '
        any(.outputs[]; .name == $name and (.enabled | not))
      ' >/dev/null
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
        # A direct KWin --virtual session provides Virtual-0. A persistent
        # startplasma-wayland session may not, so never manufacture or assume
        # a stub output merely to run this repair.
        if stub_output_enabled; then
          kscreen-doctor "output.$stub_output.disable"
        fi
        wait_for_sole_rdp_output
        if repair_panels; then
          systemctl --user try-restart "$plasma_shell_service"
        fi
        ;;
      down)
        if stub_output_disabled; then
          kscreen-doctor "output.$stub_output.enable"
        fi
        ;;
      *)
        echo "Unknown KRdp output lifecycle action: $action" >&2
        exit 2
        ;;
    esac
  '';
}
