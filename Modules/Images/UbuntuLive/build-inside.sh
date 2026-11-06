#!/usr/bin/env bash
set -euo pipefail
resolution="${1:?missing resolution}"
scale="${2:?missing scale}"
if [[ "$resolution" != auto && ! "$resolution" =~ ^[1-9][0-9]{2,4}x[1-9][0-9]{2,4}$ ]]; then
  echo "Invalid resolution" >&2; exit 2
fi
[[ "$scale" == 1 || "$scale" == 2 ]] || { echo "Invalid scale" >&2; exit 2; }
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends mmdebstrap ubuntu-keyring ca-certificates \
  squashfs-tools grub-pc-bin grub-efi-amd64-bin xorriso mtools curl gpg python3

packages="$(paste -sd, /source/packages.txt),$(paste -sd, /source/packages-gnome.txt)"
extra_packages="$(python3 -c 'import json; print(",".join(json.load(open("/config.json"))["packages"]))')"
if [[ -n "$extra_packages" ]]; then packages+=",$extra_packages"; fi
cp /source/sources.list /tmp/image-sources.list
setup_hook='true'
if true; then
  curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg -o /usr/share/keyrings/mozilla.asc
  fingerprint="$(gpg --show-keys --with-colons /usr/share/keyrings/mozilla.asc | awk -F: '$1 == "fpr" {print $10; exit}')"
  if [[ "$fingerprint" != 35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3 ]]; then
    echo "Mozilla signing key fingerprint mismatch" >&2; exit 1
  fi
  printf '%s\n' 'deb [signed-by=/usr/share/keyrings/mozilla.asc] https://packages.mozilla.org/apt mozilla main' >> /tmp/image-sources.list
  # The hook's $1 is supplied by mmdebstrap, not this script.
  # shellcheck disable=SC2016
  setup_hook='install -D -m 644 /usr/share/keyrings/mozilla.asc "$1/usr/share/keyrings/mozilla.asc"'
fi
# Hook arguments are expanded later by mmdebstrap's shell, with $1 as the root.
# shellcheck disable=SC2016
mmdebstrap --mode=root --variant=minbase --skip=chroot/mount/proc,chroot/mount/sys \
  --aptopt='APT::Install-Recommends "false"' --include="$packages" \
  --setup-hook="$setup_hook" \
  --essential-hook='chroot "$1" dpkg-divert --local --rename --add /usr/bin/systemd-tmpfiles; install -m 755 /source/tmpfiles-build-wrapper "$1/usr/bin/systemd-tmpfiles"; mkdir -p "$1/usr/share/qt5"' \
  --customize-hook='rm "$1/usr/bin/systemd-tmpfiles"; chroot "$1" dpkg-divert --local --rename --remove /usr/bin/systemd-tmpfiles' \
  stonking /rootfs /tmp/image-sources.list

# Refuse to silently add Ubuntu reporting tools through future dependencies.
for reporting_package in apport apport-gtk whoopsie ubuntu-report ubuntu-insights popularity-contest; do
  if chroot /rootfs dpkg-query -W -f='${db:Status-Status}' "$reporting_package" 2>/dev/null | grep -qx installed; then
    echo "Unexpected reporting package installed: $reporting_package" >&2; exit 1
  fi
done

install -d /rootfs/etc/xdg/autostart /rootfs/var/crash /rootfs/etc/systemd/user
# Shadow the distribution's same-named snippet, which otherwise excludes
# Ethernet. Do not retain mmdebstrap's copy of the build host's resolver.
install -D -m 644 /source/network-manager.conf /rootfs/etc/NetworkManager/conf.d/10-globally-managed-devices.conf
rm -f /rootfs/etc/resolv.conf
printf '%s\n' '# Managed by NetworkManager' > /rootfs/etc/resolv.conf
if true; then
  install -D -m 644 /source/gdm.conf /rootfs/etc/gdm3/custom.conf
  python3 <<'PY'
import json, pathlib, subprocess, zipfile

config = json.loads(pathlib.Path('/config.json').read_text())
policy = pathlib.Path('/rootfs/etc/firefox/policies/policies.json')
policy.parent.mkdir(parents=True, exist_ok=True)
policy.write_text(json.dumps({'policies': config['policies']}, indent=2) + '\n')
directory = pathlib.Path('/rootfs/usr/share/ubuntu-live/firefox-extensions')
directory.mkdir(parents=True, exist_ok=True)
for extension in config['extensions']:
    path = directory / extension['file']
    subprocess.run(['curl', '-fsSL', '--proto', '=https', '--proto-redir', '=https',
                    extension['url'], '-o', str(path)], check=True)
    with zipfile.ZipFile(path) as archive:
        manifest = json.loads(archive.read('manifest.json'))
        gecko = manifest.get('browser_specific_settings', {}).get('gecko', {})
        gecko = gecko or manifest.get('applications', {}).get('gecko', {})
        if gecko.get('id') != extension['id']:
            raise SystemExit(f"Unexpected extension ID: {gecko.get('id')!r}")
        print(f"Bundled {extension['id']} {manifest['version']}", flush=True)
PY
  if [[ "$scale" != 1 && "$resolution" != auto ]]; then
    install -D -m 755 /source/gnome-display.sh /rootfs/usr/local/libexec/ubuntu-live-display
    cat > /rootfs/etc/xdg/autostart/ubuntu-live-display.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Set virtual display resolution
Exec=/usr/local/libexec/ubuntu-live-display $resolution $scale
OnlyShowIn=GNOME;
X-GNOME-Autostart-enabled=true
EOF
  fi
fi
if python3 -c 'import json,sys; sys.exit(not json.load(open("/config.json"))["disableAudio"])'; then
  install -m 644 /source/asound.conf /rootfs/etc/asound.conf
  for unit in pipewire.service pipewire.socket pipewire-pulse.service pipewire-pulse.socket wireplumber.service pulseaudio.service pulseaudio.socket; do
    ln -sf /dev/null "/rootfs/etc/systemd/user/$unit"
  done
fi
cp -a /extra-files/. /rootfs/
install -d /output/stage/casper /output/stage/boot/grub
if [[ "$resolution" == auto ]]; then
  display_config=""; video_args=""
else
  display_config="set gfxmode=${resolution},auto; set gfxpayload=keep"
  video_args="video=Virtual-1:${resolution} video=hyperv_fb:${resolution}"
fi
sed -e "s|@DISPLAY_CONFIG@|$display_config|" -e "s|@VIDEO_ARGS@|$video_args|" /source/grub.cfg > /output/stage/boot/grub/grub.cfg
cp -L /rootfs/boot/vmlinuz /output/stage/casper/vmlinuz
cp -L /rootfs/boot/initrd.img /output/stage/casper/initrd
mksquashfs /rootfs /output/stage/casper/filesystem.squashfs -noappend -processors 2 -no-progress
(
  cd /output/stage
  # The output manifest is explicitly excluded from the list being hashed.
  # shellcheck disable=SC2094
  find . -type f ! -name md5sum.txt -print0 | sort -z | xargs -0 md5sum > md5sum.txt
  md5sum -c md5sum.txt
)
grub-mkrescue -o /output/ubuntu-live.iso /output/stage
