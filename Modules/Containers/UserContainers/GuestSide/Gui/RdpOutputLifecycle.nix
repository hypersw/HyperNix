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
    requested_rdp_output="''${2:?expected virtual-output name}"
    rdp_output=""
    rdp_output_id=""
    rdp_output_scale=""
    stub_output="Virtual-0"
    plasma_shell_service="${PlasmaShellService}"
    panel_config="''${XDG_CONFIG_HOME:?}/plasma-org.kde.plasma.desktop-appletsrc"

    output_state() {
      kscreen-doctor --json
    }

    resolve_rdp_output() {
      # KRdp asks for RDP-*, while KWin exposes that negotiated output as
      # Virtual-RDP-*. Prefer an exact requested name, otherwise accept only
      # its one exact Virtual- prefixed counterpart.
      local output
      output="$(output_state | jq -cer --arg requested "$requested_rdp_output" '
        [.outputs[]] as $outputs
        | [$outputs[] | select(.name == $requested)] as $exact
        | if ($exact | length) == 1 then
            $exact[0]
          elif ($exact | length) == 0 then
            [$outputs[] | select(.name == ("Virtual-" + $requested))] as $virtual
            | if ($virtual | length) == 1 then $virtual[0] else error("ambiguous RDP output") end
          else
            error("ambiguous RDP output")
          end
      ')" || {
        echo "Could not resolve connected RDP output: requested=$requested_rdp_output" >&2
        return 1
      }
      rdp_output="$(jq -r '.name' <<<"$output")"
      rdp_output_id="$(jq -r '.id' <<<"$output")"

      [ -n "$rdp_output" ] && [ "$rdp_output_id" != "null" ] || {
        echo "Resolved RDP output lacks a KScreen ID: requested=$requested_rdp_output" >&2
        return 1
      }
      if [[ "$requested_rdp_output" =~ @([1-5](\.[0-9]+)?)$ ]]; then
        rdp_output_scale="''${BASH_REMATCH[1]}"
      else
        echo "RDP output has no valid negotiated scale suffix: $requested_rdp_output" >&2
        return 1
      fi
      echo "KRDP-LIFECYCLE: requested output=$requested_rdp_output resolved output=$rdp_output id=$rdp_output_id scale=$rdp_output_scale" >&2
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

    apply_rdp_scale() {
      kscreen-doctor "output.$rdp_output_id.scale.$rdp_output_scale"
      for ((attempt = 0; attempt < 20; attempt += 1)); do
        if output_state | jq -e --arg name "$rdp_output" --argjson scale "$rdp_output_scale" '
          any(.outputs[]; .name == $name and .enabled and (.scale == $scale))
        ' >/dev/null; then
          return 0
        fi
        sleep 0.1
      done

      echo "Timed out applying scale $rdp_output_scale to RDP output: $rdp_output" >&2
      return 1
    }

    wait_for_rdp_output_disabled() {
      for ((attempt = 0; attempt < 20; attempt += 1)); do
        if output_state | jq -e --arg name "$rdp_output" '
          any(.outputs[]; .name == $name and (.enabled | not))
        ' >/dev/null; then
          return 0
        fi
        sleep 0.1
      done

      echo "Timed out disabling departing RDP output: $rdp_output" >&2
      return 1
    }

    no_rdp_output_enabled() {
      output_state | jq -e '
        all(.outputs[]; (.name | startswith("Virtual-RDP-") | not) or (.enabled | not))
      ' >/dev/null
    }

    panel_containments() {
      [ -f "$panel_config" ] || return 0
      while IFS= read -r containment; do
        [ -n "$containment" ] || continue
        printf '%s\n' "$containment"
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
    }

    panels_attached_to_rdp_output() {
      # After the stub is disabled, a healthy topology has this exact RDP
      # output as screen zero. Plasma persists that attachment as lastScreen.
      # Do not restart its shell on a same-layout reconnect when it is already
      # correct: the restart itself produces a visible panel gap.
      local containment panel_count=0
      [ -f "$panel_config" ] || return 1

      while IFS= read -r containment; do
        [ -n "$containment" ] || continue
        panel_count=$((panel_count + 1))
        current_screen=$(kreadconfig6 \
          --file "$panel_config" \
          --group Containments \
          --group "$containment" \
          --key lastScreen \
          --default 0)
        if [ "$current_screen" != "0" ]; then
          return 1
        fi
      done < <(panel_containments)

      [ "$panel_count" -gt 0 ]
    }

    repair_panels() {
      local containment
      while IFS= read -r containment; do
        [ -n "$containment" ] || continue
        kwriteconfig6 \
          --file "$panel_config" \
          --group Containments \
          --group "$containment" \
          --key lastScreen \
          0
      done < <(panel_containments)
    }

    case "$action" in
      up)
        resolve_rdp_output
        wait_for_rdp_output
        # KWin does not infer this scale from KRdp's virtual-monitor DPR. Set
        # the negotiated client DPI on the freshly resolved numeric output ID
        # before Plasma is repaired or the bootstrap output is hidden.
        apply_rdp_scale
        # A direct KWin --virtual session provides Virtual-0. A persistent
        # startplasma-wayland session may not, so never manufacture or assume
        # a stub output merely to run this repair.
        if stub_output_enabled; then
          kscreen-doctor "output.$stub_output.disable"
        fi
        wait_for_sole_rdp_output
        if panels_attached_to_rdp_output; then
          echo "KRDP-LIFECYCLE: panel-healthy/no-restart output=$rdp_output" >&2
        else
          repair_panels
          echo "KRDP-LIFECYCLE: panel-repair/restart output=$rdp_output" >&2
          systemctl --user restart "$plasma_shell_service"
        fi
        ;;
      down)
        resolve_rdp_output
        # Tear down precisely the departing output. A later connection may be
        # active, so never restore the bootstrap display merely because this
        # wrapper has ended.
        kscreen-doctor "output.$rdp_output_id.disable"
        wait_for_rdp_output_disabled
        if no_rdp_output_enabled && stub_output_disabled; then
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
