# KRdp patches for the Plasma 6.8 beta line

Patches for the `Gui.KRdpBeta` path, which builds KRdp and KPipeWire from the
`Plasma/6.8` branch instead of the 6.7.5 release. Only what 6.8 still needs
lives here; the 6.7.5 set stays in `../KRdpPatches` and is unaffected.

Carried over, verified to apply to 6.8:

- `0001-pointer-coordinate-fix.patch`
- `0009-h264-max-level-5.2.patch` — KPipeWire; still needed on the 6.8 branch

Dropped, because 6.8 does the same thing or better:

- `0006-display-control-diagnostics` — 6.8 ships `src/DisplayControl.cpp` itself, and
  unlike this patch it plumbs the resize through: its handler emits
  `requestedScreenSizeChanged`, rather than only advertising the channel.
- `0015-nonblocking-force-terminate` — superseded by upstream `50becf4`, which
  gives the run thread sole ownership of the FreeRDP peer. That is the real fix
  for the teardown deadlock this patch only contained.
- `0008-plasma-clipboard-bridge` — upstream added clipboard sharing in
  `fa1d1b3`, `c6cee09`, `28a362a`, `5a2f069`.
- `0002-initial-client-layout` — its security rationale is upstream as
  `18631ea` (create the backend session only after authentication), and the
  client-sized virtual monitor is what `--mode AdditionalDisplay` now does.

Deliberately not carried over yet, pending what actually breaks without them:

- `0005` layout/pointer diagnostics — diagnostics only.
- `0007` pointer origin and modifier cleanup — the libei port (`28d5ddb`)
  reworked the input path this patched.
- `0010`-`0014` output lifecycle and single-seat takeover — this whole stack
  exists to work around sessions that never close, which `50becf4` fixes at the
  root. Re-add only the parts that prove to be still required; `0010`'s removal
  of the KWin bootstrap output is the most likely to be missed.

`0003-qpainter-virtual-screencast` is not here: it patches KWin, which this
path does not bump, so it keeps applying from `../KRdpPatches`.

## Work in progress

`0016-client-layout-lifecycle-pointer.patch.wip` restores the three behaviours
6.8 lost: a virtual monitor sized and scaled from the client's negotiated
desktop, the output-lifecycle helper that disables the bootstrap stub output
and moves the panel, and the pointer origin offset for an output that is not at
the virtual-desktop origin.

It is **not applied**, and the `.wip` suffix is deliberate: the build runs but
krdpserver crashes as a client finalizes its connection (KCrash during
CONNECTION_STATE_FINALIZATION_FONT_LIST). No core was captured, so the cause is
not yet known. Two candidates, in order of suspicion:

- `fakeInputPosition()` calls `qApp->screens()`. If input events are delivered
  on the connection's own thread rather than the main thread, that touches GUI
  state off-thread. The 6.7.5 original did the same, but 6.8 reworked the input
  path, so the assumption needs rechecking rather than inheriting.
- `runOutputLifecycleHandler()` runs a QProcess with a blocking wait from
  `onSessionStarted` and `onConnectionDestroyed`. The destroy path in
  particular now runs under upstream's reworked teardown.

Next step is a debug build with core dumps enabled, or bisecting by applying
one of the three changes at a time.
