# KRdp, KPipeWire and KWin patches

Patches over nixpkgs' own Plasma packages, applied by `../KRdpOverlay.nix` for
both RdpKde modes. The set was developed on the `Plasma/6.8` branch while
nixpkgs still shipped 6.7.5, behind a `Gui.KRdpBeta` switch; since nixpkgs
moved to the 6.8.0 release it is the only set, and the 6.7.5 patches are gone.
Their history explains some of the numbering:

- `0001-pointer-coordinate-fix.patch` — KRdp.
- `0009-h264-max-level-5.2.patch` — KPipeWire.

The rest of the 6.7.5 set was dropped, because 6.8 does the same thing or better:

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
- `0005` layout/pointer diagnostics — diagnostics only.
- `0007` pointer origin and modifier cleanup — the libei port (`28d5ddb`)
  reworked the input path this patched.
- `0010`-`0014` output lifecycle and single-seat takeover — this whole stack
  existed to work around sessions that never close, which `50becf4` fixes at the
  root. `0016` and `0017` below restore the parts still required.

KWin:

- `0003-qpainter-virtual-screencast.patch` and
  `0016-qpainter-persistent-output-screencast.patch` — let KWin screencast from
  its QPainter renderer, the only one a guest without a render node could start.

KRdp, developed on the 6.8 line:

- `0016-client-layout-lifecycle-pointer.patch` — restores the three things 6.8
  dropped: a virtual monitor sized and scaled from the client's negotiated
  desktop, the output-lifecycle hook that disables the bootstrap stub output
  and moves the panel, and the pointer origin offset for an output that is not
  at the virtual-desktop origin. Under test: an earlier build of it crashed as
  a client finalized, with the stack unrecoverable because KCrash faulted
  inside its own handler. `KDE_DEBUG=1` on the service works around that, so
  the next crash produces a readable core.
- `0017-single-remote-seat.patch` — closes the incumbent connection when a new
  one is activated. `AdditionalDisplay` adds a monitor per client by design and
  upstream caps concurrency nowhere, so without this a second seat extends the
  desktop rather than taking it over. This is the small remnant of the old
  `0011`-`0014` takeover stack: the rest of it existed only to work around
  sessions that never closed, which `50becf4` fixed.
- `0018-latency-first-pacing.patch` — retunes the H.264 pacing for interactive
  use: in-flight window sized from the base RTT (the smoothed one includes
  queueing delay and grows under congestion), 0.2s of buffered video instead of
  1s, encoder paused once more than one frame awaits sending, and adaptive
  quality updating every 500ms with a 25-point step down.
- `0019-runtime-h264-toggle.patch` — `KRDP_DISABLE_H264` was read once per
  process. It is now re-evaluated per connection, and a `krdp-disable-h264` file
  disables H.264 for connections made while it exists, so RemoteFX Progressive
  can be chosen from mstsc without a restart. It is looked for in
  `$XDG_RUNTIME_DIR` (gone on restart) and in `${XDG_CONFIG_HOME:-~/.config}`
  (kept).
- `0020-persistent-output.patch` — with `KRDP_PERSISTENT_OUTPUT` set (the module
  sets it to `Virtual-0`), every connection streams that one existing output
  instead of creating a virtual monitor. Its mode and scale follow the client
  through the lifecycle helper's `prepare` action, on connect and on each
  Display Control layout, debounced while a window edge is dragged. Display
  Control also stops rejecting multi-monitor layouts, and the pointer maps
  through the screen the session actually streams. This supersedes the
  virtual-monitor half of `0016` and makes `0017`'s handover race moot; both
  stay applied because their remaining parts still serve this path.
- `0022-auto-reconnect-cookie.patch` — sends the auto-reconnect cookie (Save
  Session Info, extended logon info) once per connection. Without it mstsc never
  retries a dropped connection, whatever its own setting says. Only network
  drops are retried; a session the server ends is not.
- `0023-cheaper-remotefx-and-stats.patch` — hands the RemoteFX encoder frames in
  the byte layout they arrive in instead of converting each whole frame first,
  caps RemoteFX at 30 fps, and logs a `KRDP-STATS:` summary (frame rate, damaged
  share, bandwidth, size) every ten seconds while frames are sent.
- `0024-keep-lost-remotefx-damage.patch` — carries the damage of RemoteFX frames
  dropped after leaving the queue (write-blocked socket, no confirmed GFX channel,
  encoder failure) into the next frame sent, and sends full damage after a
  surface reset. Without it, slow links left stale patches until a repaint.
- `0025-no-gfx-deletes-after-readvertise.patch` — when a client re-advertises its
  GFX caps (mstsc does so when it rebuilds its graphics pipeline), the surface is
  dropped without sending DeleteEncodingContext/DeleteSurface: the client has
  already discarded those, and mstsc answers the deletes with a protocol error.
- `0026-client-driven-key-repeat.patch` — takes key repeat from the RDP client,
  as a Windows server does: each client repeat becomes a release and a press,
  modifier and lock repeats are dropped, and the module turns server-side repeat
  off (`KeyRepeat=nothing`, `RepeatDelay=0`). Stops letters multiplying when a
  key-up is late on a slow link. Scoped to a session without a local keyboard;
  the patch's comment records the device-scoped design an upstream MR would need.
- `0027-delete-only-used-encoding-context.patch` — sends DeleteEncodingContext
  only for a progressive context a frame has actually used; the client creates
  it on that first frame, and mstsc drops the connection over a delete of one it
  never created. Logs each surface replacement with old and new size.
- `0028-serialize-gfx-reset-with-frames.patch` — orders a caps re-advertisement
  against the frame thread: a lock held per frame keeps a surface reset in flight
  from sending CreateSurface before the new CapsConfirm, which the client drops,
  and MapSurfaceToOutput after it, which mstsc rejects with reason 3334. Without
  it, mstsc's recovery from a rejected GFX command failed this way.
