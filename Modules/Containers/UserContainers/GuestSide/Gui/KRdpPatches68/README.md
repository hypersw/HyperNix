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

- `0016-client-layout-lifecycle-pointer.patch` — restores the three things 6.8
  dropped: a virtual monitor sized and scaled from the client's negotiated
  desktop, the output-lifecycle hook that disables the bootstrap stub output
  and moves the panel, and the pointer origin offset for an output that is not
  at the virtual-desktop origin. Under test: an earlier build of it crashed as
  a client finalized, with the stack unrecoverable because KCrash faulted
  inside its own handler. `KDE_DEBUG=1` on the service works around that, so
  the next crash produces a readable core.
