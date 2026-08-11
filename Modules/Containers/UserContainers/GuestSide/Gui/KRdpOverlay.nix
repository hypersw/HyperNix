# The displayless KRdp path needs matching patched KPipeWire, KRdp, and KWin
# derivations. Keep the patches with this module so a guest does not depend on
# a mutable Copybox checkout or an LD_PRELOAD workaround.
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
    patches = (old.patches or [ ]) ++ [
      (patch "0001-pointer-coordinate-fix.patch")
      (patch "0002-initial-client-layout.patch")
      (patch "0005-layout-and-pointer-diagnostics.patch")
      # This advertises Display Control and retains diagnostics. It deliberately
      # does not claim to implement live mid-session output resize yet.
      (patch "0006-display-control-diagnostics.patch")
      (patch "0007-global-pointer-origin-and-modifier-cleanup.patch")
      (patch "0008-plasma-clipboard-bridge.patch")
      # Connect the virtual-output lifecycle to the managed KScreen/Plasma
      # helper. The next patch makes that callback asynchronous.
      (patch "0010-krdp-output-lifecycle-handler.patch")
      # One managed Plasma desktop has one active RDP seat. Authenticate and
      # record a new layout first, then asynchronously release the old exact
      # output before the new session creates its virtual monitor.
      (patch "0011-single-seat-takeover.patch")
    ];

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
    '';
  });

  patchedKwin = prev.kdePackages.kwin.overrideAttrs (old: {
    pname = "kwin-qpainter-krdp";
    patches = (old.patches or [ ]) ++ [
      (patch "0003-qpainter-virtual-screencast.patch")
    ];

    # Do not apply 0004-allow-zero-virtual-outputs.patch. KWin's initial
    # Virtual-0 stub is currently needed while KRdp creates the negotiated
    # Virtual-RDP-* output; allowing zero outputs leaves teardown/reconnect
    # ordering unsafe until there is a synchronous lifecycle callback.

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
