# The displayless KRdp path needs matching patched KPipeWire, KRdp, and KWin
# derivations. Keep the patches with this module so a guest does not depend on
# a mutable Copybox checkout or an LD_PRELOAD workaround. All three come from
# nixpkgs' own Plasma release; KRdpPatches/README.md lists what each patch does.
final: prev:
let
  inherit (final) lib;
  patch = name: ./KRdpPatches + "/${name}";

  patchedKPipeWire = prev.kdePackages.kpipewire.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      (patch "0009-h264-max-level-5.2.patch")
    ];
  });

  patchedKrdp = prev.kdePackages.krdp.overrideAttrs (old: {
    # nixpkgs' own hardcode-openssl-path patch comes first and is kept.
    patches = (old.patches or [ ]) ++ [
      (patch "0001-pointer-coordinate-fix.patch")
      (patch "0016-client-layout-lifecycle-pointer.patch")
      (patch "0017-single-remote-seat.patch")
      (patch "0018-latency-first-pacing.patch")
      (patch "0019-runtime-h264-toggle.patch")
      (patch "0020-persistent-output.patch")
      (patch "0021-unstall-h264-stream.patch")
      (patch "0022-auto-reconnect-cookie.patch")
      (patch "0023-cheaper-remotefx-and-stats.patch")
      (patch "0024-keep-lost-remotefx-damage.patch")
      (patch "0025-no-gfx-deletes-after-readvertise.patch")
      (patch "0026-client-driven-key-repeat.patch")
      (patch "0027-delete-only-used-encoding-context.patch")
      (patch "0028-serialize-gfx-reset-with-frames.patch")
    ];

    # 6.8 made libei a hard dependency for the portal input path (28d5ddb).
    # Without it cmake fails outright on the pkg-config check for libei-1.0.
    buildInputs = (old.buildInputs or [ ]) ++ [ prev.libei ];

    # KRdp propagates KPipeWire's development output. Replace the original
    # package there as well as in kdePackages, so the wrapped server links and
    # runs against the H.264-level-corrected library without LD_PRELOAD.
    propagatedBuildInputs =
      lib.filter
        (input: !(lib.hasInfix "-kpipewire-" (toString input)))
        (old.propagatedBuildInputs or [ ])
      ++ [ patchedKPipeWire.dev ];

    # KWin resolves KRdp's public launcher identity, rather than the Qt
    # wrapper reported later by /proc/<pid>/exe. Its KConfig string-list
    # conversion for this custom field uses commas, unlike standard desktop
    # entry list fields.
    postFixup = (old.postFixup or "") + ''
      desktop_file="$out/share/applications/org.kde.krdpserver.desktop"
      grep -Fqx "Exec=$out/bin/krdpserver" "$desktop_file"
      grep -Fqx \
        "X-KDE-Wayland-Interfaces=org_kde_kwin_fake_input,zkde_screencast_unstable_v1" \
        "$desktop_file"
      # Diagnostic only: this changes with the built KRdp output, allowing a
      # KService probe to confirm it selected the current desktop entry.
      printf '%s\n' "X-HyperNix-Auth-Generation=$out" >> "$desktop_file"
    '';
  });

  # KWin carries no source patches: a guest without a GPU renders through
  # KWin's own software render device, which screencasts like a GPU one.
  patchedKwin = prev.kdePackages.kwin.overrideAttrs (old: {
    pname = "kwin-krdp";

    # KWin searches its own application directory too. Give that location the
    # same corrected KRdp entry, so KService ordering cannot select a stale
    # authorization record from a different package output.
    postInstall = (old.postInstall or "") + ''
      install -Dm444 ${patchedKrdp}/share/applications/org.kde.krdpserver.desktop \
        "$out/share/applications/org.kde.krdpserver.desktop"
    '';
  });
in
{
  kdePackages = prev.kdePackages // {
    kpipewire = patchedKPipeWire;
    krdp = patchedKrdp;
    kwin = patchedKwin;
  };
}
