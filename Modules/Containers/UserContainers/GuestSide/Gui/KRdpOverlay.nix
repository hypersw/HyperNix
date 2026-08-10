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

    # Keep the upstream public launcher identity. KWin's authorization lookup
    # uses that client identity even though /proc/<pid>/exe later points at
    # Qt's inner wrapper after the launcher has exec'd it.
    postFixup = (old.postFixup or "") + ''
      # This is a KWin-specific desktop-entry field. KRdp 6.7.4's upstream
      # template deliberately uses a comma here, even though standard desktop
      # entry string lists conventionally use semicolons.
      grep -Fqx \
        "X-KDE-Wayland-Interfaces=org_kde_kwin_fake_input,zkde_screencast_unstable_v1" \
        "$out/share/applications/org.kde.krdpserver.desktop"
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

    # KWin authorizes its private screencast and fake-input protocols by the
    # desktop entry's executable. Install the exact entry from patched KRdp,
    # never a similar entry from an unpatched package set.
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
