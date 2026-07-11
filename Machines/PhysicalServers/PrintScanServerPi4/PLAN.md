# Print/Scan Server on Raspberry Pi 4

## Hardware

- **Host**: Raspberry Pi 4 (aarch64)
- **Network**: WiFi connection to LAN
- **Printer**: HP LaserJet P2015n — USB data-only cable (has Ethernet but raw network
  printing is painful to configure per-client, so fronted via this host instead)
- **Scanner**: Epson Perfection V33 (USB ID 04b8:0142) — USB data-only cable,
  mains-powered. See HyperJetHV scanner config for known driver/udev issues.
- **Future**: Zigbee relay to power-cycle the whole contraption on demand (not in scope yet)

## Software Stack

NixOS on the RPi4. Hardware drivers on the host, internet-facing services (bots) in
containers if warranted (to be decided during architecture).

### Printing

The print path should be as simple as possible from the user's perspective:

- User sends a picture or PDF to an IM bot
- The server renders/converts the document to printer-ready raster (the printer
  should receive pre-rendered data, not interpret PDFs itself)
- Printed automatically, no further interaction needed

Controls (via bot UI):
- Page range selection (e.g., "1-3", "odd", "even")
- For images: respect resolution, scaling/stretch options
- Duplex if the printer supports it (P2015n has optional duplex unit — check if present)

### Scanning

The scan path should support both bot-initiated and physical-button-initiated scans:

- **Bot-initiated**: user sends a command (or taps a button in bot UI), selecting:
  - **Resolution**: offer scanner-native DPIs only — 100, 200 (default-marked),
    300, 600, 1200. These are the values the V33 plugin accepts without
    rounding (verified empirically — 75 silently rounded to 100).
  - **Format**: JPEG 90% quality (default), PNG or TIFF as lossless alternatives.
  - **Color mode**: not offered — always scan color. For JPEG output the visual
    difference is negligible; PNG/TIFF are intermediate formats where the user
    can post-process if needed. One less decision for the user to make.
  - Scan result is sent as a **document** (not photo) to preserve quality —
    Telegram compresses anything sent via the photo path. Enforced with
    `bot.SendDocument(InputFileStream)` never `SendPhoto`.

- **Physical button**: pressing the scanner's hardware button triggers a scan
  automatically, but only if a bot session is active. A session is a
  sliding 10-minute window (each button press / scan / explicit activity
  refreshes it). Uses the session's settings. Result goes to the session
  owner's chat. See the Session Model section below for details.

### IM Bot Interface

Primary channels: **Telegram** and **WhatsApp** (whichever is simpler to set up first,
ideally both).

Research needed:
- Bot framework/library for each platform
- Can bots have interactive buttons (inline keyboards)?
- Access control: how to restrict who can use the bot (whitelist by user ID?)
- Hosting model: does the bot need a cloud server (webhook endpoint), or can it
  run on the RPi directly via long-polling? Consider:
  - The RPi is behind NAT with no public IP
  - Azure free tier is available if a cloud relay/webhook endpoint is needed
  - Long-polling (bot pulls updates) works from behind NAT without a public endpoint
- What other useful functionality do bot APIs offer that we should consider?
  (e.g., file size limits, inline mode, command menus)

### Local Network Exposure

Not a primary goal, but explore if there are versatile options for exposing the
printer/scanner to local clients (Windows, Linux, Android, iOS). The IM bot may
be the killer feature that makes this unnecessary, but worth knowing the options.

## System Architecture

### NixOS Configuration

- Flake-based configuration
- Machine flake at `HyperNix/Machines/RPi4/PrintScanServer/` — assembles hardware
  config and imports per-task module flakes
- Per-task module flakes under `HyperNix/Modules/`:
  - Printer handling (CUPS/driver config, PDF rendering pipeline)
  - Scanner handling (SANE config, button listener, image conversion)
  - Bot framework (Telegram/WhatsApp integration, command routing)
- Categories and exact module structure TBD after research

### Build and Deployment

- **Initial**: cross-build the SD card image on the x86_64 Linux host (this container),
  flash to SD card, boot the RPi
- **Ongoing**: the RPi self-updates by pulling from the public GitHub repo
  (readonly access, no deploy key needed for public repos)
- Consider: `nixos-rebuild switch --flake github:hypersw/HyperNix#PrintScanServer`
  on a timer, similar to how the MicroVM bastion updates

### Isolation

- Hardware drivers (USB, WiFi, SANE, CUPS) on the host — they need device access
- Internet-facing services (bot) potentially in a container — to be decided.
  Trade-off: container adds complexity but isolates the bot (which handles untrusted
  input from IM) from the hardware stack. Or run everything on the host if the
  attack surface is small enough (bot only talks to Telegram/WhatsApp API, no
  inbound connections if using long-polling).

## Research Findings

### Epson Perfection V33 Scanner on Linux

- Only `epkowa` backend works (proprietary, from Epson's iscan/Image Scan! for Linux)
- Requires binary interpreter plugin `esci-interpreter-perfection-v330` with firmware `esfwad.bin`
- Open-source backends (`epson2`, `epsonds`) do NOT support this scanner
- USB ID: `04b8:0142` covers both V33 and V330 (same hardware)
- Optical resolution: 4800 x 9600 dpi, CCD sensor, 48-bit color, A4 max area, LED (no warm-up)
- Hardware button: epkowa does NOT expose button sensors via SANE, AND the button is
  NOT on a USB HID endpoint. It's polled over vendor-specific bulk (ESC/I) commands —
  see the "Scanner Button Detection (Epson V33)" section below for the correct approach.
- iscan package is in nixpkgs as `epkowa`, V330 plugin as `epkowa.plugins.v330` (unfree)
- Epson's udev rules are broken on NixOS — manual `services.udev.extraRules` needed
- Custom `SANE_CONFIG_DIR` with only `epkowa` in `dll.conf` recommended for fast enumeration
- The `gcc14Stdenv` overlay in existing HyperJetHV config may be removable if nixpkgs has
  the upstream `CFLAGS=-std=gnu17` fix
- Epson Scan 2 (`epsonscan2`) does NOT support V33/V330

### HP LaserJet P2015n on Linux

- Driver: `foo2zjs` (ZjStream protocol). NOT PostScript, NOT standard PCL in practice
- Marketed as PCL 5e but on Linux the foo2zjs raster path is the reliable one
- **No duplex** on the P2015n model (P2015dn has it). No add-on duplex available.
- Resolution: 600x600 dpi native, 1200 dpi effective (firmware REt enhancement)
- USB 2.0 Hi-Speed, also has Ethernet (JetDirect port 9100, IPP)
- Host does all rendering: Ghostscript rasterizes → foo2zjs wraps in ZjStream → printer
- Known issue: `usblp` kernel module may conflict with CUPS USB backend — blacklist it
- NixOS: `foo2zjs` packaged in nixpkgs, use `services.printing.drivers = [ pkgs.foo2zjs ]`
- P2015n (network model) stores firmware in flash, no per-boot firmware upload needed

### Telegram Bot API

- Create via @BotFather, get HTTP API token, 2 minutes
- **Long-polling works behind NAT** — bot initiates all connections outbound, no public IP needed
- File limits: receive 20 MB, send 50 MB (plenty for scans/PDFs)
- Inline keyboards with callback_data for interactive buttons (unlimited buttons)
- Access control: user ID whitelist in code (no built-in private bot setting)
- Command menus: `setMyCommands` registers slash commands with descriptions in UI
- Lightweight frameworks for RPi: Go (`telebot`), Rust (`teloxide`), Python (`pyTelegramBotAPI`)
- Rate limits: ~30 msg/sec global, ~1/sec per chat — irrelevant for single-user bot
- Send scanned files back via `sendDocument` (preserves quality, up to 50 MB)

### WhatsApp Bot API

- **Official Cloud API**: webhook-only (needs public HTTPS endpoint), requires Meta Business
  verification, 1000 free service conversations/month, then paid
- **Baileys** (unofficial, Node.js): outbound WebSocket, works behind NAT, free,
  ~50 lines of JS, scan QR to link. ToS-grey but low practical ban risk for personal use
- File limits: ~16 MB documents, supports PDFs and images
- Interactive buttons: official API has up to 3 per message; unofficial unreliable on
  non-business numbers
- Access control: phone number whitelist in code
- **Telegram is dramatically simpler** on every technical dimension. WhatsApp's advantage
  is ubiquity (2.7B vs 900M MAU). Recommend: Telegram first, WhatsApp via Baileys later if needed

### Local Network Printing/Scanning (IPP, AirPrint, etc.)

**Printing — CUPS + Avahi:**
- CUPS shares USB printer over network via IPP. Avahi advertises AirPrint automatically
- Auto-discovery: macOS, iOS, Android (Mopria), Linux, ChromeOS — all native
- Windows: needs manual IPP URL or Bonjour Print Services installed for mDNS discovery

**Scanning — AirSane + saned + scanservjs:**
- **AirSane** (`SimulPiscator/AirSane`): bridges SANE → eSCL protocol. Advertises via
  Avahi as `_uscan._tcp`. Makes scanner visible to iOS, macOS, Android (Mopria Scan) natively
- **saned**: SANE network daemon for Linux-to-Linux scanning (port 6566)
- **scanservjs** (`sbs20/scanservjs`): web UI for SANE, covers Windows and any browser client
- No WSD Scan implementation exists for Linux (Windows native Scan app unsupported)

**Optimal stack**: CUPS + Avahi (printing, all platforms) + AirSane (scanning, Apple/Android)
+ scanservjs (scanning, browser fallback for Windows)

### NixOS on Raspberry Pi 4

- Officially supported. Pre-built SD images available from Hydra
- Boot: U-Boot standard, requires proprietary GPU firmware blobs
  (`hardware.enableRedistributableFirmware = true`)
- WiFi BCM43455: works with `brcmfmac` + firmware blobs, out of box once enabled
- USB: dedicated VL805 controller, works fine. Update EEPROM firmware from Raspberry Pi OS first
- RAM: 4 GB+ recommended. Headless NixOS ~150-300 MB. Nix evaluation/building is memory-intensive
- **Cross-build initial image** from x86_64 via `boot.binfmt.emulatedSystems = [ "aarch64-linux" ]`
  on the build host. Slow (5-10x) but simple. Binary cache has good aarch64 coverage
- **Self-update**: `system.autoUpgrade.flake = "github:user/repo#rpi4"` on a daily timer.
  Binary cache hits mean most updates are downloads, not builds
- **SD card wear**: prefer USB SSD boot (EEPROM supports it). If SD card: mount /tmp as tmpfs,
  volatile journal, noatime, high-endurance card
- `nix-community/nixos-hardware` has `raspberry-pi-4` module with hardware-specific settings

### C# (.NET 10 AOT) vs Rust for the Daemon

| Dimension | C# (.NET 10 AOT) | Rust |
|---|---|---|
| Binary size | 15-25 MB | 5-10 MB |
| Idle RAM | 20-40 MB | 2-8 MB |
| Startup | 10-50 ms | <5 ms |
| Cross-compile aarch64 | Supported, needs cross toolchain | Easy, `cross` crate or manual |
| Telegram library | Telegram.Bot (mature, 50M NuGet downloads) | teloxide (mature, strongly typed, async) |
| SANE | Shell out to scanimage | Shell out to scanimage |
| CUPS | SharpIpp (pure C# IPP) or shell out | ipp crate (less mature) or shell out |
| NixOS packaging | Possible (`buildDotnetModule`), less common | Excellent (crane/buildRustPackage, best story) |
| REST server | ASP.NET Minimal APIs (~15-25 MB) | axum (~2-4 MB stripped) |

Both shell out to `scanimage` for SANE and `lp` for CUPS (or use IPP libraries).
Rust wins on footprint and NixOS packaging. C# wins on familiarity and SharpIpp.

### Epson V33 on aarch64 — Driver Saga

The single hardest part of the project so far. Recording the story so
future-us doesn't re-try the dead ends.

**The problem.** `epkowa` needs `libesci-interpreter-perfection-v330.so`
(plus firmware `esfwad.bin`) to drive this scanner. Epson ships the plugin
**x86_64 only**. No aarch64 build exists and it's proprietary — we can't
rebuild it.

**Dead ends — emulating the whole stack:**

- **qemu-user** of the entire SANE stack: scanner enumerates, then bulk
  transfers hang. qemu-user's syscall translator doesn't implement
  libusb's async `USBDEVFS_SUBMITURB` / `REAPURB` ioctls, and those are
  the plugin's USB path.
- **box64**: gets further — the plugin loads — but crashes in variadic
  libc wrappers during init (vfprintf-family argument handling under
  translation). Never reaches the USB path.
- **FEX-Emu**: same class of issue, different break point. Plus rootfs
  juggling.
- **Open-source SANE backends** (`epson2`, `epsonds`): explicitly don't
  support V33/V330. `epsonscan2` (proprietary, newer) same story.

**The architecture that works — proxy / stub split.** Keep USB +
`libsane-epkowa.so` **native aarch64**; isolate *only* the proprietary
plugin in a short-lived **x86_64 Rust stub** process spawned per scan via
`socketpair + fork + exec`. The stub inherits an IPC socket on fd 3,
`dlopen`s the plugin, and serves wire-format requests for every plugin
entry point. USB callbacks forward back over the same socket to the
aarch64 side so libusb stays native. qemu-user only ever sees the
plugin's pure CPU work (ESC/I byte munging) which it handles fine — no
USB ioctls ever reach it.

The stub is cross-compiled natively on aarch64 via `rustPlatform`'s cross
support — no qemu at build time.

Code lives under:
- `Modules/PrintersScanners/EpkowaStubX64/` — Rust stub + `PROTOCOL.md`
  wire format + cross-build derivation
- `Modules/PrintersScanners/EpkowaStubX64/iscan-ipc-proxy.patch` — iscan
  patch on top of nixpkgs' stock epkowa, adding `--enable-ipc-proxy` and
  a new `backend/epkowa_ipc.c` that routes through the stub
- `Modules/PrintersScanners/EpkowaScanner/default.nix` — glue + udev
  rules + SANE config

**The one thing we don't understand well.** `int_init(fd, …)` takes the
USB file descriptor. File descriptors are process-local, so iscan's fd
is meaningless in the stub process. Empirically:
- Passing `-1` sends the plugin down its `fd < 0` sentinel branches and
  it corrupts its own heap a few commands later.
- Passing `INT32_MAX` keeps the plugin on its normal "non-negative fd"
  path and scans work end-to-end.

Any syscall the plugin might issue on either value fails `EBADF` anyway
— `INT32_MAX` can't be a real open fd in the stub. We don't know which
internal plugin paths these steer it down. If the plugin ever uses the
fd for something load-bearing (e.g. buffer-size math — improbable but
not ruled out), the `INT32_MAX` happy path could break in interesting
ways. If we see flakiness, this is the first thing to re-examine.

**Small technical details** (mostly routine, here for search):

- iscan's `bool` is `typedef enum { false, true }` — int-sized on amd64,
  not `_Bool`. Our Rust-side FFI slots using `bool` (1 byte) leaked
  garbage into the plugin; need an explicit `IscanBool = c_int` alias.
- iscan's `_recv` treats `int_read`'s return as a boolean success flag
  and reads the whole `size`-byte buffer regardless. The stub must ship
  `buf[..size]` back over IPC, not a subset based on the return value.
- `function_s_1` has no byte-length parameter — the caller passes width
  (pixels) + color (bool) and the plugin infers `bytes_per_line`. We
  extend the `_s_1` slot signature with an ifdef'd `size_t line_bytes`
  under `USE_IPC_PROXY` so `_ftor0` hands over the authoritative
  `params->bytes_per_line` directly.
- Some plugin commands overrun the caller's buffer (decode the scanner
  response in place). Native iscan absorbed this into stack neighbours
  it never re-read; our heap buffers get `PLUGIN_OVERRUN_PAD = 64` so
  the overrun stays inside our own `Vec<u8>`.

**What's still fragile:**

- **Scanner stays powered on after a scan.** The Windows Epson Scan 2
  app idles it, so there's presumably a USB command sequence; we'd have
  to capture it with Wireshark + `usbmon`. Parked.
- **USB cable sensitivity.** Rare chirp-handshake downgrades to USB 1.1
  during enumeration, cable-dependent. The original Epson cable (ferrite
  coils on both ends) is clearly serious about interference; generic
  replacements are less happy. The scanner *is* slightly pickier than it
  used to be years ago even on the original cable, so the USB-B jack
  might have degraded some, but not enough to justify opening the unit
  in a dusty home. Workaround: use the original cable.
- **Multi-scan within one stub process** not yet exercised. The stub has
  only been tested with a single scan followed by `fini` + exit. The
  session model we're about to build will push this path and may surface
  new behaviour (plugin state carry-over between scans, etc.).

### Scanner Button Detection (Epson V33)

- V33 buttons use **vendor-specific bulk commands** (ESC/I protocol), NOT USB HID
- No `/dev/input/` or `/dev/hidraw/` events — the host must **poll** the scanner
- **scanbuttond** `backends/epson.c` is the best reference for the ESC/I button query
  command format (sends `ESC !`, reads response byte with button state)
- **scanbd** and **insaned** use SANE polling but epkowa doesn't expose buttons — won't work
- The scanner has 4 buttons (Scan / Copy / PDF / Send) — all should generate distinct
  response patterns. We only care about the Scan button for now.

**Reverse-engineering status (pending hardware):** scaffold code and probe script are in
place; actual protocol bits need a short session with the scanner attached.

Probe script: `Modules/PrintersScanners/EpkowaScanner/probe-button.py` (pyusb).
Prompts the operator to press each button in turn and diffs the 4-byte `ESC !`
replies against a baseline. Run it as:

```
# on the Pi, with the scanner attached and no scanimage running
nix-shell -p python3 python3Packages.pyusb --run 'python3 probe-button.py'
```

Scaffold: `Modules/PrintersScanners/Daemon/src/ButtonPoller.cs` — `BackgroundService`
hosted in the daemon, subscribes to `ScannerMonitor.IsOnline()` and
`SessionService.Current.InFlightScan`, polls on a 1s tick when idle, emits
`SessionEventType.ScannerButton` on rising edges. The `DoUsbPollAsync` method is
currently a no-op TODO — once the probe tells us the byte/bit, we fill it in.

**Test path without hardware:** `POST /debug/button` on the daemon calls
`ButtonPoller.SimulatePress()` which emits the event immediately. Lets us exercise
the whole bot-side reaction (session → auto-scan) end-to-end via a shell poke.

Integration once hardware protocol is known:
  1. Pick a libusb binding — leaning toward a small Rust sidecar the daemon
     exec's, since we already have Rust infra for the IPC stub and keeping the
     C# daemon free of native deps is nice.
  2. Coordinate with SANE's USB claim: only poll when the active session's
     `InFlightScan` is false. Even then, SANE may briefly hold the device on
     scan edges — retry on `USBDEVFS_CLAIMINTERFACE EBUSY`.
  3. Debounce rising-edge transitions (one emit per physical press, not per
     100ms of held-down state).

### Monitoring (Non-Printer-Specific)

- **systemd OnFailure=** template service + `curl` to Telegram API — zero overhead,
  fires only on failure. Apply to critical services including `nixos-upgrade.service`
- **Periodic health timer** (every 15 min): check for failed units, disk usage, RAM,
  CPU temperature (`/sys/class/thermal/thermal_zone0/temp`), report to Telegram
- **Boot confirmation**: oneshot service sends Telegram message on successful boot.
  Optionally combine with healthchecks.io dead-man-switch for missed-boot detection
- **Journal alerting**: `journalwatch` or custom `journalctl --since` in the timer
- **monit** (~2 MB RAM) available if richer process monitoring needed beyond systemd
- Token storage: `sops-nix` or `agenix` for the Telegram bot token (not plaintext in config)

## Architecture (Revised)

### Flake Structure in HyperNix

```
HyperNix/
  Machines/RPi4/PrintScanServer/
    flake.nix                — machine config, assembles modules, builds SD image
    PLAN.md                  — this file
  Modules/
    PrintersScanners/
      TelegramBot/
        flake.nix            — Telegram bot, talks to the daemon REST API
      WhatsAppBot/
        flake.nix            — Baileys-based WhatsApp bot (later), same REST API
      EpkowaScanner/
        flake.nix            — SANE + epkowa + button poller + AirSane
      LaserJetPrinter/
        flake.nix            — CUPS + foo2zjs + Avahi advertising
    Monitoring/
      TelegramAlerts/
        flake.nix            — OnFailure template, health timer, boot confirmation
```

### Service Architecture (on the RPi4, no containers)

No containers — the bot uses long-polling (outbound only, no inbound attack surface),
all services need USB device access, and the RPi has limited RAM.

```
┌──────────────────────────────────────────────────────────────┐
│                      RPi4 Host (NixOS)                       │
│                                                              │
│  ┌──────────────┐  unix   ┌──────────────────────────────┐  │
│  │ Telegram Bot  │◄──────►│                              │  │
│  │ (C#/.NET)     │ socket │    Print/Scan Daemon         │  │
│  └──────────────┘         │    (C#/.NET, long-running)   │  │
│  ┌──────────────┐  unix   │                              │  │
│  │ WhatsApp Bot  │◄──────►│  - Print jobs (→ lp/CUPS)   │  │
│  │ (Node.js)     │ socket │  - Scan jobs (→ scanimage)   │  │
│  └──────────────┘         │  - Scanner button poller     │  │
│  ┌──────────────┐  TCP    │  - Job queue / state         │  │
│  │ Web UI        │◄──────►│                              │  │
│  │ (later,       │ +token │  Listens on:                 │  │
│  │  oauth2-proxy)│         │  - /run/printscan/api.sock  │  │
│  └──────────────┘         │  - 127.0.0.1:PORT (web, +key)│  │
│                            └──────────┬──────────────────┘  │
│                                       │                      │
│  ┌───────────┐  ┌──────────┐    ┌────┴─────┐               │
│  │ CUPS      │  │ AirSane  │    │ SANE     │               │
│  │ (foo2zjs) │  │ (eSCL)   │    │ (epkowa) │               │
│  └─────┬─────┘  └────┬─────┘    └────┬─────┘               │
│        │USB           │SANE           │USB                   │
│  ┌─────┴──────────────┴───────────────┴─────┐               │
│  │              USB Hub / Ports              │               │
│  │    HP P2015n          Epson V33           │               │
│  └──────────────────────────────────────────┘               │
│                                                              │
│  ┌──────────────┐  ┌────────────────────────┐               │
│  │ Monitoring    │  │ system.autoUpgrade     │               │
│  │ Timer+OnFail  │  │ (daily, --refresh)     │               │
│  └──────────────┘  └────────────────────────┘               │
└──────────────────────────────────────────────────────────────┘
```

### The Print/Scan Daemon

Central service that owns all hardware interaction. Long-running .NET process.
Exposes a local API consumed by bots, web UI, or any future client.

**Transport:**
- **Primary**: Unix domain socket at `/run/printscan/api.sock` (mode 0660, group `printscan`).
  Bots run as users in the `printscan` group. No tokens, no TLS — OS file permissions
  control access. `SO_PEERCRED` available for caller identification if needed.
  systemd socket activation with `SocketMode=0660` and `SocketGroup=printscan`.
- **Secondary** (for web UI, later): TCP `127.0.0.1:PORT` with auto-generated API key
  stored in a restricted config file. Web UI (SPA) served behind oauth2-proxy
  (Google/Microsoft account gating) which forwards authenticated requests with
  the API key. Same pattern as Syncthing.

**Endpoints (revised):**
- `POST /print` — accept file (PDF/image), options (page range, copies)
- `POST /sessions` — open a scan session with DPI/format/chatId; returns session ID, or 409 if one is already open (takeover via `?takeover=true`)
- `DELETE /sessions/{id}` — close a session explicitly
- `GET /sessions/{id}` — inspect session state (params, scans-so-far, expires-at)
- `PUT /sessions/{id}/owner-status-message` — move the bot-owned live status
  message to a new Telegram message id. Used by the Telegram bot as a
  self-conflict recovery/handoff path when the user runs `/scanner` while their
  own session is already active.
- `POST /sessions/{id}/scan` — ask for one scan now (not waiting for the button)
- `GET /sessions/{id}/image/{seq}` — return an already-captured TIFF image.
  The daemon writes a point-in-time byte snapshot to the response so later
  daemon-side deletion/disposal of the retained scan cannot race the HTTP body
  writer.
- `GET /status` — printer/scanner instantaneous status
- `GET /events` — SSE stream: `scanner.online`, `scanner.offline`, `scanner.button`, `session.opened`, `session.scanning`, `session.image-ready { sessionId, seq, bytes, contentType }`, `session.terminated { reason: timeout|takeover|closed, newOwner? }`, `session.extended`
- `GET /jobs` — list recent print jobs (scan jobs are session-scoped now)

**Scanner button integration.** The daemon's button poller thread monitors the
scanner via ESC/I bulk commands (polling period TBD during reverse-engineering,
500ms is the starting estimate). Button presses go out as `scanner.button` SSE
events. The daemon itself does **not** auto-scan on button press — the bot
(which knows the session state and user context) calls `POST /sessions/{id}/scan`
in response. This keeps scan-on-button policy in the bot so different media
(TG/WhatsApp/web) can customize behavior without daemon changes.

### Session Model

The daemon holds the session as durable state (single source of truth for
multi-bot support). Bots are stateless — they reconstruct their view from
daemon events on startup.

**Record** (persisted to `/var/lib/printscan/sessions.json` on every mutation):
```
{
  "id": "abc123",
  "ownerBot": "telegram",
  "ownerChatId": 12345,
  "ownerStatusMessageId": 67890,   // for the bot to edit on events
  "ownerDisplayName": "@alice",     // for takeover messages
  "params": { "dpi": 200, "format": "jpg" },
  "opened": "2026-04-20T01:23:45Z",
  "expiresAt": "2026-04-20T01:33:45Z",  // sliding 10-min window
  "scanCount": 3,
  "inFlightScan": false  // only true during scanimage + delivery
}
```

**Lifecycle:**
- **Open** — bot `POST /sessions` with `params + chatId + statusMessageId`.
  Returns `409 Conflict` with the current session summary if one exists. Bot
  shows user a confirmation for someone else's session; on confirm, bot retries
  with `?takeover=true`. If the conflict is the same chat/user's own session,
  the bot treats the newly posted "Opening session..." placeholder as a fresh
  live head: it calls `PUT /sessions/{id}/owner-status-message`, renders the
  full session controls there, and edits the old head into a keyboard-less
  "session continued below" stub. This is the recovery path for Telegram edit
  loss on the original session-opening message.
- **Takeover** — daemon waits for any `inFlightScan` on the existing session
  to complete delivery first (hard-cut is bad UX), then emits
  `session.terminated { reason: takeover, newOwner: … }`, creates the new
  session. Previous bot sees the event and edits its status message to
  "🚪 Session ended — taken over by @bob".
- **Sliding window** — each button press / scan / explicit poke refreshes
  `expiresAt` to `now + 10min`. A background task in the daemon closes
  expired sessions and emits `session.terminated { reason: timeout }`.
- **Close** — explicit `DELETE /sessions/{id}` from any bot action.
- **Persistence across daemon restart** — on boot daemon reads
  `sessions.json`, re-emits current `session.opened` state on first SSE
  subscription, bot-side status messages still work because `chatId +
  messageId` live in Telegram forever.

**In-flight scans do not survive daemon restart** — they're active process
state, not persisted. If the daemon is SIGTERMed mid-scan the shutdown
handler lets the current scan+delivery complete (see "Graceful Shutdown").
Hard-kill/power-loss loses the in-flight scan; bot shows
"🔁 Service restarted, press the button to rescan", session stays open.

### Bot-Side Materialization & Delivery Pipeline

**Dataflow (happy path):**
```
scanimage stdout → daemon RecyclableMemoryStream
   → session.image-ready SSE
   → bot GET /sessions/<id>/image/<seq> into MemoryStream
   → bot decodes once, encodes selected variants in memory
   → bot.SendDocument / SendMediaGroup → Telegram
   → on 200 OK: bot DELETEs the daemon's retained TIFF
```

The daemon end uses `Microsoft.IO.RecyclableMemoryStream` — chunked pool-backed,
no LOH pressure, swap-friendly. The daemon retains the raw TIFF until the bot
explicitly deletes it after successful Telegram delivery, or until session
termination reaps leftovers. `GET /image` snapshots the retained stream to a
byte array before writing the HTTP response; the response writer never borrows
the retained stream object.

The bot keeps encoded variants in memory. Telegram upload calls receive fresh
`MemoryStream` clones for each album item, fallback send, and retry attempt.
This is intentional: Telegram.Bot may dispose streams passed into multipart
requests, and June 23 production logs showed Tier A album failure followed by
Tier B fallback failing with `ObjectDisposedException` on the reused
`scan-encoded` stream. The clone-per-attempt rule keeps the canonical encoded
variant streams alive until the delivery pipeline's final cleanup.

**Media group delivery.** Telegram's `sendMediaGroup` is atomic — up to 10
items per call, cannot edit to add more. Default UX: each scan streamed to
the user as an individual document during the session (immediate feedback);
on session close, all staged files gathered into one or more media-groups
of 10 as a "📚 Session summary". Toggle available per-session.

**Hi-resolution over the 50MB TG limit.** Multi-page high-res sessions can
exceed the single-file limit; plan is ZIP-first, shell out to `7z -v50m` for
multi-volume output only when the ZIP would exceed 50MB. Materialization
means no data is lost while we decide what to do.

### Graceful Shutdown

Both `printscan-daemon.service` and `printscan-bot.service` participate in
generous, bounded shutdown:

- `TimeoutStopSec=5min` on the daemon (cover worst-case scan+upload; picked
  down from an earlier 20min after observing that most real scans finish
  well under a minute — 5min is plenty for the legitimate in-flight case,
  and short enough that a hung shutdown is visibly recoverable).
- Services trap SIGTERM via `IHostApplicationLifetime`, refuse to exit while
  any `inFlightScan` or upload is active. A simple gauge; tasks increment/
  decrement and the handler `await`s it to drain before calling `StopAsync`.
- nixos-rebuild swaps happen cleanly: in-flight work completes, service
  restarts, session reloaded from disk.
- Hard kill (OOM, panic, power): in-flight scan lost (see session lifecycle
  above); persisted session + staged files recover everything else.

**Observed shutdown hang (2026-04-23).** After `ApplicationStopping` +
`ApplicationStopped` callbacks fire, `ShutdownGate.StopAsync` returns
with zero in-flight ops, `SessionService.DisposeAsync` completes — the
CLR process nonetheless refuses to exit. systemd waits the full
`TimeoutStopSec = 5min` and sends SIGKILL.

**Diagnosis**: blocking shutdown sequence is async internally
(`IHostedService.StopAsync` awaited; `IAsyncDisposable.DisposeAsync`
awaited; each hosted service's cancellation token threaded through),
with an outer sync boundary at `app.Run()` which is
`host.WaitForShutdownAsync().GetAwaiter().GetResult()`. No
`SynchronizationContext` in the console host = sync-over-async here
doesn't deadlock — just blocks on what the async side is waiting on.
Every piece of the async side we control completes cleanly (per the
log markers), so the hang is in **framework-internal thread teardown**.

Live kernel-stack capture during a hang (via `sudo` — the daemon user
lacked `CAP_SYS_PTRACE` at the time) pinned the culprit: the CLR's
`.NET DebugPipe` thread stuck in `wait_for_partner` → `fifo_open` →
`__arm64_sys_openat`. That thread manages the managed-debugger IPC
channel at `/tmp/clr-debug-pipe-<pid>-<ts>-{in,out}`. Linux `open()`
on a named pipe blocks until both ends are opened; nothing ever
connects in prod, so the thread is permanently parked in `openat()`.
It's a raw pthread (not a managed thread, so `Thread.IsBackground`
doesn't apply) and not `pthread_detach`'d, so CoreCLR shutdown waits
for it. All 26 other threads parked in benign `futex_wait`/`poll`/
`epoll_wait`, waiting for this one thread to unstick.

**Why only on .NET 10**: earlier runtimes installed a default SIGTERM
handler that eventually `_exit()`ed, steamrolling any stuck native
thread. .NET 10 removed that handler ([breaking change](https://learn.microsoft.com/en-us/dotnet/core/compatibility/core-libraries/10.0/sigterm-signal-handler)),
so SIGTERM now runs a cooperative shutdown via `ConsoleLifetime`/
`UseSystemd`: `Main` returns, CLR then sits waiting for DebugPipe
which never wakes. Upstream bug known since 2017 — [coreclr#8844](https://github.com/dotnet/coreclr/issues/8844).

**Fix**: set `DOTNET_EnableDiagnostics_Debugger=0` in the daemon
service environment. Prevents the DebugPipe thread from being created
at CLR init. (`DOTNET_EnableDiagnostics_IPC` — a first guess of ours
— is a different channel: the `dotnet-diagnostic-<pid>-<ts>-socket`
UDS for `dotnet-trace`/`dotnet-counters`/`dotnet-dump attach`. We
keep that one on.) Trade-off: we lose IDE Attach-to-Process for live
managed debugging (VS/VS Code/Rider over the FIFO transport). We
keep: `createdump` core dumps, `dotnet-dump collect` (UDS), trace/
counters, and native `lldb` + SOS (uses `ptrace` + DAC, no CLR IPC).

**Standing diagnostic**: a two-part capture inside
`ApplicationStopped`, scheduled 10 seconds after the event fires.
Retained even with the DebugPipe fix in place, so future shutdown
hangs of a different flavor produce automatic evidence rather than
requiring ad-hoc `sudo` on the device. Requires `CAP_SYS_PTRACE`
(granted as an ambient cap in the service unit) to read the stacks
of sibling threads and to exec `createdump`.

  1. Per-thread kernel stack dump via `/proc/<pid>/task/<tid>/stack`,
     with `comm` and `state` (R/S/D/...). Cheap, always works — tells
     us *which syscall* each thread is blocked in (typically
     `futex_wait_queue_me` or `ep_poll`).

  2. Managed-aware full core dump via `createdump -f <path> --normal
     <pid>`. createdump is shipped as a sibling of
     `System.Private.CoreLib.dll` in every .NET runtime — we locate it
     via `typeof(object).Assembly.Location`, no extra packaging
     needed. The resulting .core file is analyzable offline with
     `dotnet-dump analyze <file>`, which exposes the SOS/WinDbg
     equivalents on Linux: `clrstack -all`, `threads`, `dumpheap`,
     etc. — the managed-side view that corresponds to the kernel
     stacks from (1).

Kernel stacks alone aren't useful for a .NET hang because every
managed thread parks in a futex or epoll call when it's waiting; the
syscall doesn't tell you *what managed task* is behind the wait.
createdump gives the full picture. We store the dump under the
service's state dir (`STATE_DIRECTORY`, i.e. `/var/lib/printscan/`)
so it survives a reboot and can be `scp`'d off for workstation
analysis.

Then systemd SIGKILLs at the 5-minute mark. The 5-min timeout stays
intentional (gives in-flight scans + uploads time to finish when the
system decides to switch mid-scan); preserving the evidence for
post-mortem beats forcing a clean exit.

### Relationship with AirSane/CUPS

AirSane and CUPS are **independent network services** — they talk directly to
SANE/printer hardware. They don't go through the daemon. The daemon is a parallel
client of the same hardware, coordinated by:
- SANE device locking (only one client can use the scanner at a time)
- CUPS queue (print jobs are serialized by CUPS regardless of source)

No shared state between the daemon and AirSane/CUPS. A LAN user scanning via
AirSane and a Telegram user scanning via the daemon compete for the SANE device
lock — acceptable for a home setup with low concurrency.

### Language Decisions

On 4-8 GB RPi4, memory differences between languages are negligible.
Each component can use the best-fit stack since REST/socket boundaries decouple them.

| Component | Language | Why |
|---|---|---|
| Print/Scan daemon | C# (.NET 10, JIT) | SharpIpp for CUPS, familiar, long-running (startup irrelevant), ASP.NET Minimal APIs for REST, platform-independent DLLs |
| Telegram bot | C# (.NET 10, JIT) | Telegram.Bot is excellent (50M NuGet downloads), same ecosystem as daemon, separate process |
| WhatsApp bot | Node.js | Baileys is JS-only, no choice |
| Scanner button poller | Python (prototyping) → C# (production) | pyusb for reverse-engineering, then libusb P/Invoke or stays Python |
| Web UI (later) | SPA (any) + oauth2-proxy | Behind Google/MSFT account gating |

.NET JIT advantages over AOT/native for this use case:
- Platform-independent DLLs — just need `dotnet-runtime` package
- No cross-compilation toolchain hassle
- Full reflection/dynamic loading works
- Faster dev cycle
- Long-running daemons — startup time irrelevant

### WiFi Configuration

**Per-device authentication** — not shared WPA-PSK.

**Recommended: EAP-PEAP with Unifi built-in RADIUS** (simplest start):
- Unifi supports WPA2/WPA3-Enterprise on WiFi SSIDs
- Unifi has a built-in RADIUS server (Settings > Profiles > RADIUS) — supports
  PEAP/MSCHAPv2 (username/password per device). Does NOT support EAP-TLS (certs).
- Create a separate SSID (e.g., "IoT-Secure") with WPA2-Enterprise, keep existing
  WPA-PSK SSID for human devices unchanged. Different VLANs if desired.
- Revoke a device: delete its RADIUS user in Unifi
- NixOS: `networking.wireless.networks."IoT-Secure".auth` with PEAP config,
  password via sops-nix (not plaintext in Nix store)
- Multiple SSIDs: Unifi supports 4-5 per radio, each independent security mode

**Upgrade path: EAP-TLS with FreeRADIUS** (strongest, for later):
- Private CA, client cert per device, revoke via CRL
- Requires running FreeRADIUS (on this RPi or elsewhere)
- NixOS `networking.wireless` supports EAP-TLS natively in wpa_supplicant

**Alternative: PPSK via RADIUS** (unique PSK per device MAC):
- Needs FreeRADIUS, returns per-MAC PSK in `Tunnel-Password`
- Device side is just WPA2-PSK (simplest client config)
- Unifi PPSK support via RADIUS not fully reliable on all firmware versions

**Initial deployment**: Ethernet (no WiFi config needed). WiFi added later.

### Local API Auth (Research Summary)

**Unix socket** (chosen for bot→daemon):
- OS file permissions are the access control — no tokens, no TLS needed
- `SO_PEERCRED` gives caller UID/GID/PID — unforgeable, kernel-provided
- Cannot be accidentally network-exposed (not TCP)
- Industry standard: Docker, containerd, D-Bus, PulseAudio, systemd

**TCP localhost** (for web UI later):
- No OS-level access control on TCP ports — any local user can connect
- Requires application-level auth (API key / bearer token)
- Auto-generated key in restricted config file, same pattern as Syncthing
- Web UI behind oauth2-proxy for Google/MSFT SSO before reaching the API

**Industry patterns observed:**
- Docker: Unix socket + file permissions, no auth on socket
- CUPS: TCP + PAM basic auth for admin ops
- Syncthing: TCP 127.0.0.1 + auto-generated API key in config.xml
- Home Assistant: TCP + JWT bearer tokens + trusted-network bypass
- Prometheus: TCP, no auth by default (network isolation assumed)

### SD Card Longevity

Using a camcorder-grade high-endurance SD card. Measures in the config:
- `boot.tmp.useTmpfs = true` — /tmp in RAM
- `fileSystems."/".options = [ "noatime" ]` — no access time writes
- `nix.settings.auto-optimise-store = true` — dedup hard links in store
- `nix.gc`: monthly on the 2nd at 04:00 + 6h randomized, 30-day retention,
  `persistent = true`. Coupled with `system.autoUpgrade` on the 1st so gc
  runs after the upgrade has settled. On-push rebuilds don't trigger gc —
  between monthly upgrades the store barely changes and that window also
  happens to be when rollback is most likely needed.
- `nix.settings.keep-outputs = true` + `keep-derivations = true` — build
  closures (rustc, cross toolchain, autoreconfHook) stay alive as long as
  the generation that used them is still in gc retention. Without these,
  every iteration rebuild re-fetches the toolchain the moment the previous
  one gets pruned, which defeats the point of iterating on the Pi.
- `boot.growPartition = true` — auto-expand root on first boot
- Persistent journal left on; earlier `Storage=volatile` was commented out
  during the scanner-driver investigation to keep diagnostic history.

### Memory Management

- **zram swap** (50% of RAM, zstd compression) — ~2 GB compressed swap in RAM,
  handles normal memory pressure without disk writes
- **Disk swap** (2 GB `/var/swapfile`) — last resort before OOM killer, rarely touched
- `vm.swappiness = 1` — almost never use disk swap

### Kernel

Generic aarch64 kernel (`pkgs.linuxPackages`) instead of RPi-specific (`linuxPackages_rpi4`).
The RPi kernel is NOT in cache.nixos.org — every update would be a 4-8 hour compile.
Generic kernel is always cached. Trade-off: no RPi-specific GPU/camera/HAT patches,
irrelevant for a headless print/scan server.

### Duplex Printing

Deferred. P2015n has no duplex unit. Manual even/odd via print-to-file for now.
Could add bot UI for this later (print odd → prompt user to flip → print even).

### User and Access

- User `administrator` with wheel + scanner + lp groups, passwordless sudo
- Root has no password, SSH root login disabled
- SSH key-only authentication (ECDSA P-256, TPM-importable)

### Build & Deploy

1. **Initial**: SD image built by GitHub Actions (aarch64 via QEMU binfmt on x86_64
   runners, ~20 min). Flash with `flash-sd.sh` script. Boot on Ethernet.
2. **Self-update**: local `/etc/nixos/flake.nix` (generated on first boot) wraps
   the upstream `github:hypersw/HyperNix#PrintScanServer` config. The local flake
   owns the lock file and controls nixpkgs version.
   - `system.autoUpgrade` runs monthly (1st of month, 2-8 AM), with `--refresh`
   - `preStart` runs `nix flake update /etc/nixos` to pull fresh nixpkgs + upstream
   - Reboot allowed (unattended machine)
3. **Manual rebuild**: `sudo nixos-rebuild switch --flake /etc/nixos`
   Or trigger the upgrade service: `sudo systemctl start nixos-upgrade.service`
4. **WiFi**: added later, EAP-PEAP with Unifi built-in RADIUS, password via sops-nix
5. **Public repo**: readonly GitHub access, no deploy key needed

### Push-triggered rebuild — DONE

Implemented as `services.auto-rebuild-on-push` in
`Modules/System/AutoRebuildOnPush/`. 5-minute systemd timer runs a shell
script that compares upstream `github:hypersw/HyperNix` against the locked
rev, and on change runs `nix flake update --flake /etc/nixos` + full
`nixos-rebuild switch`. Monthly full autoUpgrade continues to cover
nixpkgs refreshes.

(Telegram-push alternative parked — polling cost is trivial and the
GitHub webhook setup would need a public endpoint we don't have.)

### Recent Improvements and Discoveries (late April 2026)

Concentrated hardening pass on network plumbing, boot observability,
and alerting — documented here because several choices are non-obvious
and easy to re-break.

**Network stack: legacy → networkd + resolved + avahi (hybrid mDNS).**
Migrated off `dhcpcd` + Avahi-only. Now systemd-networkd owns L3 and
DHCP, systemd-resolved owns the DNS stub (`/etc/resolv.conf` →
127.0.0.53). Per-link `MulticastDNS=no` on resolved so it doesn't
contend with Avahi for `:5353`. Wi-Fi auth stays with `wpa_supplicant`
(networkd doesn't do 802.11).

**Dynamic Avahi primary-interface tracker.** Avahi (and resolved's
mDNS) both hit self-conflict on multi-interface hosts whose
interfaces share an L2 segment — the AP bridges multicast between
wlan0 and end0, each interface sees its sibling's announcement as
"another device claiming my name," runs RFC 6762 conflict resolution,
and renames the host to `printscan7.local`, `printscan190.local`, etc.
Observed in practice. `/etc/avahi/hosts` per-interface-names approach
doesn't fix it (static-hosts are published with `AVAHI_IF_UNSPEC`,
same bridging, same conflict). Fix: a watcher
(`avahi-primary-interface-watcher`) writes
`allow-interfaces=<primary>` into a runtime-generated
`avahi-daemon.conf` that avahi is pointed at via `-f`. Subscribes to
`ip monitor route`; when the default route's preferred interface
changes (end0 carrier drop → wlan0 promoted), rewrites the conf and
restarts avahi. ~1-2 sec mDNS blackout on interface transitions;
acceptable given transitions are rare. Placeholder
`allow-interfaces=lo` gets written if no default route exists yet
(early boot before DHCP), so avahi-daemon starts cleanly and we
regenerate on the first real route event. `Restart=always` on the
watcher so any exit (including clean exit when `ip monitor` pipe
closes) respawns.

**Source-routing for symmetric replies.** Both interfaces on the same
`/24` means a reply to incoming traffic on wlan0 can leave via end0
(kernel's route lookup picks by metric), producing a frame whose
src-IP (wlan0's) doesn't match its src-MAC (end0's) — UniFi APs drop
that on per-client MAC-IP binding. The fix is a **connmark-based
policy-routing chain**:

  PREROUTING (iptables mangle):
    -i end0  -j MARK --set-mark 100   # set packet nfmark
    -i wlan0 -j MARK --set-mark 200
    -j CONNMARK --save-mark           # persist nfmark → ctmark
    -j nixos-fw-rpfilter              # NixOS's own rpfilter check
  OUTPUT (iptables mangle):
    -j CONNMARK --restore-mark        # ctmark → nfmark for replies

Paired with networkd config:
  - `dhcpV4Config.RouteMetric = 1002` on end0 / `3003` on wlan0
    (replaces dhcpcd's automatic interface-type-based metrics that
    networkd doesn't do).
  - Per-interface tables 100/200 with `Route = Destination=0.0.0.0/0,
    Gateway=_dhcp4` (uses the DHCP-learned gateway without hardcoding
    an IP).
  - `routingPolicyRules` with `FirewallMark=100 → Table=100` etc.

Pi-originated connections have nfmark=0, fall through to main table,
end0 metric wins = Ethernet preferred for egress. Replies to incoming
traffic inherit the mark from conntrack and route out the arrival
interface = symmetric.

**Traps learned:**
  1. `MARK --set-mark` sets packet nfmark; `CONNMARK --set-mark` sets
     conntrack's ctmark. Rpfilter's `--validmark` reads nfmark. If you
     use CONNMARK, mark stays 0 for rpfilter and rpfilter drops
     wlan0 arrivals as reverse-path mismatch against the main table.
  2. CONNMARK rules must be inserted at position 1 (`iptables -I`),
     not appended — NixOS's rpfilter chain is appended as the first
     PREROUTING rule, so our mark must set before it runs.
  3. `net.ipv4.conf.all.arp_ignore = 1` + `arp_announce = 2` required:
     without them both end0 and wlan0 answer ARP for either IP, and
     whichever is faster wins — usually Ethernet, so the laptop caches
     end0's MAC for .130 and all the above source-routing is useless
     because packets arrive on the wrong physical interface.
  4. `_dhcp4` / `_dhcp6` / `_ipv6ra` as `Gateway=` values in
     `[Route]` sections of `.network` files: networkd substitutes the
     DHCP-learned next-hop at runtime — no hardcoded IPs needed.

**Alert outbox** (async, offline-resilient notifications). Previously,
each notify script synchronously `curl`'d Telegram. Unreliable when
network is flapping; silent loss on shutdown/brownout. Now every
notify script enqueues a message file into
`/var/spool/alert-telegram-outbox/` (atomic mktemp + rename). A
drainer service + path-unit + timer consume the spool, send to
Telegram, delete on success, retry on failure. Clock-skew-proof:
enqueue records the host's `boot_id` alongside the wall-clock
timestamp; drainer caps the computed "queued ago" age at
`/proc/uptime` when the boot_ids match, so messages enqueued pre-NTP-
sync don't read as "queued 35m ago" when the Pi has only been up for
90s.

**Boot telemetry.** Two separate notifications bracket the boot
window:
  - `boot-started-notify` fires very early (`DefaultDependencies=no`,
    `Before=sysinit.target`, `After=local-fs.target`), enqueues a ⚪
    message with persistent sequence number, dedupes per boot_id.
    Sequence counter owned here (not boot-notify) because this fires
    on EVERY boot, including ones that fail before multi-user — a
    bootloop is visible as a gap between started-count and booted
    occurrences.
  - `boot-notify` fires after multi-user.target is reached (🟢). No
    sequence number.
Plus `shutdown-notify` (🔴) with a forced synchronous drain on its
ExecStop so the shutdown telegram lands before the machine actually
powers off.

**SD health (MMC/eMMC) monitoring.** The installed Samsung ED2S8
card doesn't expose `life_time` / `pre_eol_info` sysfs attributes
(consumer cards rarely do — industrial/endurance cards typically do).
Fallback: `sd-health-monitor` follows the kernel journal
(`journalctl -kf`) and enqueues a 💾 alert on matching patterns —
`mmc0/mmcblk0/sdhci error`, `EXT4-fs error/warning`, `Buffer I/O
error`, `blk_update_request`, `CRC failure`. High signal-to-noise;
any occurrence is a "replace the card" signal.

**BootStabilityProbe staged peripheral bring-up.** Module already in
tree (Modules/System/BootStabilityProbe), enabled on
PrintScanServer after the silent-reset loop on 2026-04-21. Blacklists
xhci_hcd_pci / xhci_pci / brcmfmac / brcmfmac_wcc / brcmutil at
kernel cmdline, then modprobes them serially after a 20-sec settle,
with aggressive journald sync between stages. Helps split peripheral
init transients in time and makes the journal pinpoint which stage
triggers a reset if one recurs.

**Throttle / undervoltage persistent log.** `/var/log/throttle.log`
sampled every 5 min via `vcgencmd get_throttled` + volt/temp. The
register reads "events since last boot" — a full brownout wipes it,
so only sub-brownout sags accumulate. Still useful: pre-brownout
0x50000 in the log before a silent reset = definitive PSU evidence.

**Pstore/ramoops best-effort.** Kernel cmdline sets
`ramoops.mem_address=0x08000000 ramoops.mem_size=0x100000 ecc=1`
etc. No DT `reserved-memory` node on Pi 4 without a custom overlay,
so the region isn't formally reserved — kernel may use it for other
purposes, ramoops headers get trashed, no data preserved. Left in
because a future hardware / DT update might start honoring it; costs
nothing on the failure path.

**Bot UX polish** (end-user facing):
  - Tap-to-edit Format/DPI buttons on session status message (no
    modal wizard).
  - Format/DPI picker submenus with 🔘/⚪ radio-button emoji for the
    current selection (empty circle unselected as placeholder; user
    may pick a different pair — several candidates discussed).
  - "end session" is a Telegram hyperlink in the message body
    (`https://t.me/<bot>?start=end_<sid>`), not a keyboard button.
    Tap triggers `/start end_<sid>` to the bot, which closes the
    session and deletes the user's `/start` message. Keeps Scan
    prominent as the only button in the last row.
  - Queued-ago decoration on delayed messages: `<i>⏱ queued Nm ago</i>`
    on a separate italicised line at the END of the message (not the
    start) so real-time siblings in the chat stay column-aligned.
  - Running `/scanner` while your own scanner session is active now performs a
    live-message handoff: a new session head is posted at the bottom of the
    chat, the daemon's stored `OwnerStatusMessageId` moves to it, and the old
    head is edited into a dummy "continued below" message. This makes the
    command a failsafe when Telegram loses the initial edit from "Opening
    session..." to the full control message.

### Implementation Order

1. ~~Machine flake (NixOS config, SD image, boot on RPi4 via Ethernet)~~ DONE
2. ~~EpkowaScanner module: SANE + epkowa + aarch64/x86_64 IPC proxy/stub.
   End-to-end Color A4 scan working end-to-end (see "Driver Saga" above)~~ DONE
3. ~~Push-triggered rebuild (auto-rebuild-on-push service polling GitHub)~~ DONE
4. ~~Monitoring module (OnFailure + Telegram alerts + boot confirmation)~~ DONE
5. ~~LaserJetPrinter module (CUPS + foo2zjs)~~ DONE (printing untested end-to-end)
6. ~~**Daemon redesign** — session model + streaming pipeline + SSE events.~~ DONE
7. ~~**Bot redesign** — status-message UX + materialized staging + takeover flow.~~ DONE
8. ~~**Graceful-shutdown plumbing** on both services — SIGTERM drain,
   `TimeoutStopSec=20min`.~~ DONE
9. **Scanner button — probe + integration.** Scaffold is committed
   (`ButtonPoller.cs` in the daemon, `probe-button.py` under EpkowaScanner/).
   When the rig is up: run the probe, fill in `DoUsbPollAsync` with the
   decoded ESC/I bits, pick a libusb binding (Rust sidecar preferred).
10. **End-to-end dry-run** on hardware with the `POST /debug/button` path
    exercising the session → bot-reactive-scan flow before the real button
    poll is wired, to isolate surprises.
11. **AirSane** (LAN scanning for iOS/macOS/Android) — independent of the bot path.
12. **Scanner power-off-via-USB** — capture Windows Epson app idle sequence
    with Wireshark + `usbmon`, replay on session close.
13. **Zigbee relay** to power-cycle scanner + RPi on session open. Hardware
    not yet available — parked, not in any phase.
14. **WiFi** (EAP-PEAP, separate SSID, sops-nix for creds).
15. **WhatsApp bot** (Node.js/Baileys, same daemon API).
16. **Web UI** (SPA + oauth2-proxy → daemon API).

Current focus when the rig comes back up: **9 → 10**, everything before is
complete and building clean.

## Print Flow — 2026-04-25

The print path was redesigned in line with the scanner's separation
of concerns: daemon stays content-dumb, all imagery / format /
preview decisions live in the bot, untrusted file conversion runs
in a separately-hardened sidecar.

### Components

  - **PrintScan.Daemon** — owns the HTTP/Unix-socket interface and
    drives `lp` (when a real printer is wired) or the stub. Reports
    paper geometry and non-printable margins via `/status`. Never
    inspects file contents.
  - **PrintScan.Renderer** — hardened sidecar at
    `Modules/PrintersScanners/Renderer`. Drops privileges to
    DynamicUser, runs in `PrivateNetwork` namespace with
    `RestrictAddressFamilies=AF_UNIX`, `IPAddressDeny=any`, full
    `Protect*` bundle, empty `CapabilityBoundingSet`,
    `NoNewPrivileges`. Spawns one fresh subprocess per render
    request — soffice / pandoc / xpstopdf / pdfinfo — so a parser
    crash takes the child down, not the daemon. Endpoints:
      - `POST /render` — `multipart file` → `application/pdf`.
        Routes by extension: XPS/OXPS via libgxps's xpstopdf,
        Markdown via pandoc → docx → soffice, everything else
        via soffice (DOC/DOCX/ODT/RTF/HTML/TXT/XLS/PPT/…).
        Math in Markdown survives the round-trip via OMML in
        the docx intermediate.
      - `POST /pdf-info` — `multipart file` → JSON
        `{pageCount, raw}`. Used by the bot for the per-page
        checkbox UI.
    Failure responses are RFC 7807 ProblemDetails — `title` is
    the human summary, `detail` is the raw stderr (truncated).
  - **PrintScan.TelegramBot** — owns all UX. Per-chat
    `BotPrintSession` with a single `PendingPrint` awaiting
    confirmation. Image analysis (dimensions / dpi / aspect /
    fit verdict) via SixLabors.ImageSharp on the bot side.
    Routes Office uploads through the renderer transparently.

### UX shape

  - Reply keyboard is `📷 Scanner…` `🖨 Printer…` `📊 Status`. Both
    `/scanner` and `/scan`, both `/printer` and `/print`, and
    `/status` are accepted. Old labels without the ellipsis are
    matched too so stale persistent keyboards keep working.
  - Confirm-before-print is invariant. Files from the chat are
    staged into `BotPrintSession.Pending`; nothing prints unless
    the user taps ✅.
  - Pickers, all inline keyboards on the same status message:
      - **Scale** (images only): 1:1 / Fit / Fill. 1:1 is always
        offered and gets a badge — `1:1 ⚠ margins` when the image
        fits the paper but extends into the non-printable strip,
        `1:1 ⚠ won't fit` when it exceeds the paper. Default is
        1:1 only when `OneToOneFit.Printable` (fits printable
        rectangle within a 1 mm slop tolerance for rounding-error
        overflows).
      - **Orientation** (images only): Auto / Portrait / Landscape.
        Auto picks based on aspect.
      - **Pages**: All / Odd / Even radio. When the document is a
        Pageable with ≤ 10 pages (page count from renderer's
        `/pdf-info`), each page also gets a checkbox row (5 per
        row). A custom-range button opens a small inline-keyboard
        digit pad for entering the classical CUPS expression
        (`1-3,5,7-9`) without needing a chat-text-input flow.
      - The 1:1 caveat is also rendered into the pending block's
        text so users who don't open the picker still see it.
  - **History**: per-chat in-memory list of last 5 print jobs,
    top 3 surfaced as `📑 Recent: ✅ a.pdf · ❌ b.png · …`.
    Cleared on bot restart (no persistence).

### Hardware-specific defaults (HP LaserJet P2015n)

  - Paper: A4. `services.printscan-daemon.mediaSize = "A4"`.
  - Non-printable margins: 4.23 mm all sides per HP's plain-A4
    spec. `services.printscan-daemon.nonPrintableMarginsMm = {
      top = 4.23; bottom = 4.23; left = 4.23; right = 4.23;
    }`.
  - **No hardware duplex** on this model (P2015dn would have it).
    Manual duplex is a planned UX layer (Pages=Odd → flip → Pages=Even)
    that's deferred until a real printer is wired and we can
    test the actual stack-flip ordering.

### Wire format

`POST /print` accepts these form fields:
  - `file` — required, the document
  - `copies` (int, default 1)
  - `pageRange` — CUPS expression like `1-3,5,7-9`. When non-empty,
    overrides `pageSelection`.
  - `pageSelection` — `All` / `Odd` / `Even`. Used only when
    `pageRange` is empty.
  - `scale` — `OneToOne` / `Fit` / `Fill`
  - `orientation` — `Auto` / `Portrait` / `Landscape`

The renderer is invoked transparently: bot classifies the file,
sends Office-family inputs through `POST /render` first, takes
the resulting PDF as the new pending document. Direct PDF / PS /
image uploads skip the renderer. PDF page count is then queried
via `POST /pdf-info` and fed into the picker UI.

### Done

  - Confirm-before-print across all formats.
  - Format-toggle scanner picker glitch fixed (view persistence
    on `BotSession`; `Format` is bot-only-source-of-truth).
  - Three-button reply keyboard with disambig ellipsis.
  - Daemon paper-size + non-printable margins config.
  - Bot polls `/status` every 30 s to refresh printer state in
    open print sessions (`PrinterOnline`, `MediaSize`, `Margins`).
  - Pages: All / Odd / Even / per-page checkbox (≤ 10 pages) /
    digit-keyboard custom range.
  - Renderer: DOCX / ODT / RTF / TXT / HTML / Markdown (with
    LaTeX math) / XPS / OXPS / spreadsheets / presentations
    via soffice + pandoc + xpstopdf.
  - PDF page-count query via renderer's pdfinfo wrapper.
  - Friendly failure surfacing — bot shows the renderer's
    ProblemDetails `title` as a one-liner banner and tucks the
    raw stderr into a `<pre><code>` block (truncated to 1 KB)
    so investigation is straightforward.

### Deferred / open

  1. **Print preview as an image.** User asked for a render of how
     the page will look (image placement, margins shown), updated
     as toggles change. The Telegram side is non-trivial because
     converting a text status message into a media one needs
     delete + resend (no `editMessageMedia` from text), and we'd
     have to track multiple message ids on the bot side. Per the
     last round, the chosen approach is to abandon the previous
     status message (replace its text with `→ Continued ↓` and
     drop its keyboard) and continue the session in a new media
     message. Not yet implemented. Doc preview (first page of
     the rendered PDF via `pdftoppm`) lands in the same flight.
  2. **Manual duplex sequence.** Two-step flow:
     "Print Odd → flip pages → Print Even", with per-printer
     stacking-order hint. Deferred until a real P2015n is on the
     wire so we can verify the page ordering empirically.
  3. **Real printer.** Currently a stub — `PrintService.PrintAsync`
     just logs and sleeps. The wire format and bot UX are in
     final-ish shape; swapping in a CUPS-driven implementation is
     a single class-body change.
  4. **Doc-renderer test coverage.** Renderer is integration-tested
     by hand only. A test corpus of small DOCX / MD / XPS /
     malformed inputs against `/render` would catch regressions.
  5. **Format coverage gaps.** Renderer doesn't currently accept:
     EPUB (would need pandoc with EPUB→docx → soffice; trivial to
     add), HEIC images (libheif → soffice/imagemagick; bot side),
     CSV (soffice handles via its calc importer but we don't list
     it). Add as needed; broad-by-default to avoid the "send a
     PDF instead" hint where avoidable.
  6. **Scanner reply-keyboard icon.** Currently `📷` (camera) which
     is what's at hand but visually ambiguous. No native
     "scanner" emoji; alternatives discussed but no change yet
     (📠 fax, 🔍 magnifier, 📑 bookmark tabs, 🖼 framed picture).

## Print Flow — Update 2026-04-26

Significant tightening of the print pipeline plus several new
formats / UX bits since the 04-25 snapshot.

### What changed

  * **Pixel-perfect image print path.** Image uploads now flow
    through PrintPreprocess.ProcessForPrintAsync which Lanczos3-
    upscales to 600 dpi at A4 (matching the HP P2015n's 600 dpi
    mechanical engine), grayscales, and wraps into a hand-rolled
    single-page PDF via PrintPdfWrap. The image XObject carries
    `/Interpolate false`, so Ghostscript inside CUPS does an
    identity nearest-neighbor map at the rasterizer — pixels land
    on the engine grid 1:1 with no double-resample, no CUPS
    bilinear softening. The PDF's MediaBox stays A4 portrait;
    for landscape orientation we rotate the image content via the
    cm matrix rather than swapping the page dims, keeping CUPS'
    page-fitting logic out of the way. PDF wrap is a hand-rolled
    minimal PDF (single page, one image XObject, one content
    stream) — ~250 lines of explicit byte-offset bookkeeping for
    the xref table, no QuestPDF/iText/PdfSharp dependency.
  * **Live preview.** BotPrintSession now keeps its live message
    handle mutable; every new file upload abandons the previous
    message ("→ session continued below ↓") and sends a fresh
    one immediately under the user's upload, so the active session
    UI stays in view through a sequence of files. Toggles use
    editMessageMedia to swap the preview in place — the user sees
    Scale / Orientation / Pages choices reshape the rendered page
    as they pick.
    Preview compositor (PrintPreview) draws the paper canvas with
    faint-gray non-printable margin bands and a hairline around
    the safe printable rect; the source is grayscaled before
    placement so the preview matches what'll actually print.
    Output is grayscale lossy WebP Q=80 — small enough to re-send
    on every toggle. Caption surfaces "fills NN% of page" so the
    user can tell at a glance whether 1:1 would land postmark-
    sized.
    For Pageables, the renderer's new POST /pdf-preview rasterises
    the first 3 pages into one stacked grayscale WebP via
    ImageMagick (Ghostscript-backed). Bot ships it as a Document
    so Telegram preserves the bytes byte-for-byte.
  * **1:1 fits indicator.** The 1:1 button always renders now
    with an explicit badge — `1:1 ✓` when it fits the printable
    rect (1 mm slop), `1:1 ⚠ margins` when it'd land in the
    non-printable strip, `1:1 ⚠ won't fit` when it exceeds the
    paper. Default Scale is 1:1 only when ✓.
  * **Pages picker hides for single-page content** (images
    always; one-page Pageables once /pdf-info reports the count).
  * **Per-page checkboxes for Pageables ≤ 10 pages** (5 per row,
    backed by CUPS page-range string), plus a 3×5 inline-keyboard
    digit-pad for arbitrary range entry — no chat-text-input
    state machine needed.
  * **HEIC / AVIF accepted.** New /image-convert renderer endpoint
    bounces through libheif's heif-convert (libavif's avifdec as
    AVIF fallback) to produce a PNG, which the bot then handles
    via the normal Image staging path. Both decoders run in
    their own subprocesses inside the renderer's existing systemd
    jail.
  * **EPUB accepted** via pandoc (EPUB → docx) → soffice (docx →
    PDF). Same shape as the Markdown path; PandocToPdfAsync
    parameterised on source format.
  * **CSV explicitly refused** with a "convert to ODS/XLSX first"
    hint. soffice's CSV importer needs the column-separator /
    quote-char wizard which doesn't fire in headless mode.
  * **Compressed-photo consent gate (P2).** When the user uploads
    via Telegram's Photo path (TG-recompresses in transit), the
    inline keyboard collapses to "[☐ I accept compressed quality]"
    + "[❌ Cancel]" — Print stays disabled until the user ticks
    through. Caption surfaces a "⚠ Sent as Telegram media
    (compressed). Resend as a file for full quality." line.
  * **System fonts.** PrintScanServer now installs DejaVu /
    Liberation / MS-corefonts / Noto Latin + CJK / Source family
    / Cantarell / FreeFont. Ghostscript / soffice / pandoc all
    consult fontconfig and pick up everything in
    /run/current-system/sw/share/fonts; the renderer service
    inherits read access through its existing system-paths
    bindings. Means PDFs with un-embedded fonts get a plausible
    substitute rather than the Type 3 fallback rectangles.
  * **Stub-write end-to-end test path.** Daemon stub now writes
    received bytes to /var/lib/printscan-daemon/printed/<ts>-<n>
    as well as logging. Lets us inspect what would have hit CUPS
    without burning paper. The lp-driven implementation will
    "tee + lp" — file output stays as the audit trail.
  * **Renderer toolchain expansion.** Added imagemagick (`magick`)
    for /pdf-preview; libheif (`heif-convert`) and libavif
    (`avifdec`) for /image-convert; poppler-utils (`pdfinfo`,
    `pdftoppm`) for /pdf-info.

### Hardware-specific notes (HP P2015n)

  * **No hardware duplex.** The P2015dn variant has it; this one
    doesn't. Manual duplex has its own UX flow (planned, deferred).
  * **600 dpi mechanical engine + RET.** ProRes 1200 marketing is
    actually 600 × 600 dpi raster + analog-laser-dwell edge
    enhancement at the engine, not 1200 dpi rendering.
    Bot's 600 dpi target lines up with the mechanical resolution
    so /Interpolate false is identity, not nearest-neighbor with
    1-pixel jaggies.
  * **Host-based driver.** P2015n is a "host-based" laser — it
    receives ZJStream from foo2zjs (decoded by the host CPU),
    not PCL/PostScript. So host-side rasterization is the
    architecture, regardless of OS. CUPS via foo2zjs does the
    same thing on Linux that the Windows driver does on Windows.
  * **Both trays pull from the top of their stack.** Tray 2
    cassette is face-down, manual feed (Tray 1) is face-up.
    Output bin is face-down, last-printed-on-top. Manual duplex
    needs `outputorder=reverse` on the second pass plus the user
    flipping the stack and reinserting Tray-1 face-up,
    top-edge-first.

### Deferred / open

  1. **Manual-duplex sequence.** Two-step flow with paper-flip
     hint between Pages=Odd and Pages=Even passes. Wants
     real-printer testing — page ordering empirics depend on the
     specific printer's stacking order.
  2. **Real `lp` integration.** Currently the daemon writes the
     bytes to a folder; swapping in `lp -d <queue>` is a
     few-line change once a queue exists. Wire-format and UX
     are stable — when this lands, the bot's pre-processed PDF
     payload goes straight to lp without further options because
     scale/orient/pages are already baked in (for image inputs)
     or carried as form fields (for Pageables).
  3. **Per-content-type upscaler variants.** v1 is Lanczos3 only;
     line-art-aware (xBRZ / hqx) and neural (Real-ESRGAN /
     waifu2x-ncnn-vulkan) are research-once-we-have-samples.
  4. **cups-pdf as a real CUPS queue.** Sits next to the eventual
     real printer queue; an env-var flips the daemon between
     "stub-write" / "cups-pdf" / "real-lp".
  5. **Doc-renderer test corpus.** Integration-tested by hand
     only.
  6. **Scanner reply-keyboard icon.** Sticking with 📷 per
     2026-04-26 review.

## Status snapshot — 2026-05-09

### Hardware

* **Pi 4 board**: not currently running (5 V damage 2026-04-21
  retired the original board). Config + provisioning image
  actively maintained — flashing
  `PrintScanServerPi4-provisioning-sdImage` to a fresh Pi 4
  brings the role back via the same self-flip pattern GhostHome
  uses; `printscan-ready-<shortRev>` is the readiness ref.
* **Pi 5 (`GhostHome`)**: planned next deployment. Will host a
  home-automation stack as the headline workload; print/scan is
  a guest service on it. New machine config at
  `Machines/PhysicalServers/GhostHome/`. Hostname / mDNS /
  branding all use "GhostHome" regardless of which guest
  workloads it carries.

### Folder layout

```
HyperNix/
├── Machines/
│   ├── MicroVM/VmSshFront/                     unchanged
│   └── PhysicalServers/                        renamed from RPi4/
│       ├── PrintScanServerPi4/                 (not currently flashed)
│       │   ├── configuration.nix
│       │   ├── secrets/secrets.yaml
│       │   └── PLAN.md (this file)
│       └── GhostHome/                          (Pi 5 incoming)
│           ├── configuration.nix
│           └── secrets/secrets.yaml
├── Modules/
│   ├── Profiles/                               new umbrella
│   │   ├── AnyMachineBase/                     base "any host" profile
│   │   ├── MultiHomedNetworking/               dual-NIC source-routing
│   │   ├── PhysicalServerProvisioning/         first-boot self-flip image
│   │   └── PrintScanServer/                    full print/scan stack
│   ├── PrintersScanners/...                    sub-modules unchanged
│   ├── Monitoring/TelegramAlerts/              unchanged
│   └── System/{AutoRebuildOnPush,
│              AvahiPerInterfaceNames,
│              BootStabilityProbe}              unchanged
└── flake.nix                                   nixosConfigurations:
                                                PrintScanServerPi4,
                                                GhostHome
                                                (each + -sdImage variant
                                                 + -provisioning-sdImage variant)
```

### Profile design (updated 2026-05-09)

Four meta-modules under `Modules/Profiles/`. Each is a NixOS
module declaring its caller-facing contract under the
`hypersw.*` option namespace (migrated 2026-05-09 from bare
`profiles.*` / `services.*` — see "Namespace migration" below).
Secrets / per-machine details live as required typed options
that nix eval rejects when unset (visible "what you must
supply" surface). Path-typed (not sops-secret-typed) to keep the
secret-delivery story decoupled.

* **AnyMachineBase** (hardware-agnostic, applies to any NixOS
  host we run except microVMs). Two-tier `lib.mkMerge` config:

  *Always-applies tier:*
  - administrator user (option-typed name + authorizedKeys +
    extraGroups; other modules append via NixOS list-merge)
  - openssh, sudo, root locked
  - nix gc + experimental + keep-outputs + monthly auto-upgrade
    with `cadence = enum [ "daily" "weekly" "monthly" ]`
  - localFlake activation script (configurationName +
    upstreamUrl options)
  - telegram-alerts wired with required token + chat-id paths
  - auto-rebuild-on-push enable
  - htop in systemPackages
  - allowUnfree

  *Non-container tier (`!config.boot.isContainer`):*
  - hardware.enableRedistributableFirmware (default true,
    overridable via `redistributableFirmware` option)
  - swap + zramSwap + vm.swappiness=1
  - /tmp on tmpfs
  - noatime on /

  This subsumes the old PhysicalServerBase profile (deleted
  2026-05-09) — the `!isContainer` guard cleanly excludes
  nspawn/declarative containers (which inherit the host
  kernel/swap), while VMs and bare metal both get the full
  bundle. usbutils dropped — `nix run nixpkgs#usbutils` covers
  the once-a-year ad-hoc need without baking into closures.

* **PhysicalServerProvisioning** — minimalist first-boot image
  profile. Boots, generates ssh host keys, runs a systemd timer
  that retries `nixos-rebuild boot --refresh --flake
  <targetFlakeUri>#<name>` every minute until the `?ref=…`
  exists upstream, then `systemctl reboot`s into the full
  configuration. Doesn't import AnyMachineBase (don't want
  auto-rebuild / alerts / sops on the provisioning side — they'd
  fail noisily without secrets). targetFlakeUri /
  targetConfigName are required options. Two flake.nix entries
  consume this profile, one per host:
  * `PrintScanServerPi4-provisioning-sdImage` →
    `?ref=printscan-ready-<shortRev>` → flips into
    `PrintScanServerPi4`
  * `GhostHome-provisioning-sdImage` →
    `?ref=ghosthome-ready-<shortRev>` → flips into `GhostHome`

  Both bake the per-image readiness ref into the filename via
  `image.baseName = "<host>-provisioning__ref=…__"` so the
  operator greps the filename to know which branch/tag to push
  (`grep -oP '(?<=__ref=)[^_]+'`). Brackets are double underscore
  rather than parens because parens leak into stdenv build hooks
  that `eval` filenames unquoted and crash the build with
  "syntax error near unexpected token `('".

* **MultiHomedNetworking** (dual-NIC bundle):
  - `interfaces` is a list-of-records (name / fwmark /
    routingTable / routeMetric / requiredForOnline). Default
    matches Pi 4/5 naming (`end0` + `wlan0`).
  - ARP-strict sysctls
  - iptables CONNMARK + per-interface fwmark + per-interface
    routing tables and policy rules
  - mDNS via Avahi + per-interface-names module + resolved
    with MulticastDNS=no
  - x86 boxes override `interfaces` with their predictable names

* **PrintScanServer** (print/scan stack):
  - Imports LaserJetPrinter / EpkowaScanner / Daemon / Renderer /
    TelegramBot, enables them.
  - Required option: `bot.tokenFile`. Other options for paper
    size, allowed users, opt-out toggles per leg.
  - Adds x86_64 binfmt for the EpkowaScanner stub when
    `epkowaScanner.enable`.
  - Installs broad font set for the renderer's PDF font fallback.
  - Appends `scanner` and `lp` to the administrator's groups via
    list-merge on AnyMachineBase's `administrator.name`.

### Namespace migration (2026-05-09)

All custom profiles + services moved from bare `profiles.*` /
`services.*` to `hypersw.profiles.*` / `hypersw.services.*` so
they don't collide with upstream NixOS namespaces (and so a
codebase reader can immediately tell what's ours vs nixpkgs').
Renamed:

| Old | New |
|---|---|
| `profiles.anyMachineBase.*` | `hypersw.profiles.anyMachineBase.*` |
| `profiles.physicalServerBase.*` | (deleted; folded into anyMachineBase) |
| `profiles.printScanServer.*` | `hypersw.profiles.printScanServer.*` |
| `profiles.multiHomedNetworking.*` | `hypersw.profiles.multiHomedNetworking.*` |
| `profiles.physicalServerProvisioning.*` | `hypersw.profiles.physicalServerProvisioning.*` |
| `services.printscan-daemon.*` | `hypersw.services.printscan-daemon.*` |
| `services.printscan-renderer.*` | `hypersw.services.printscan-renderer.*` |
| `services.printscan-telegram-bot.*` | `hypersw.services.printscan-telegram-bot.*` |
| `services.telegram-alerts.*` | `hypersw.services.telegram-alerts.*` |
| `services.epkowa-scanner.*` | `hypersw.services.epkowa-scanner.*` |
| `services.laserjet-printer.*` | `hypersw.services.laserjet-printer.*` |
| `services.auto-rebuild-on-push.*` | `hypersw.services.auto-rebuild-on-push.*` |
| `services.avahi-per-interface-names.*` | `hypersw.services.avahi-per-interface-names.*` |
| `services.boot-stability-probe.*` | `hypersw.services.boot-stability-probe.*` |

Systemd unit names (`systemd.services.printscan-daemon` etc.)
are unchanged — those are ours-but-they're-systemd-unit-names,
and reading `journalctl -u printscan-daemon` should keep working
without a prefix.

### Sops naming convention (post 2026-05-09 rename)

UpperCamelCase, `<Owner><LocalName>`. Owner is the top-level
concern (Monitoring / PrintScan / Machine). Pure UpperCamelCase
keeps Nix attribute access clean — no quoting, no hyphen/dot
ambiguity, room to grow with `MonitoringSlackBotToken`,
`PrintScanWhatsAppBotToken`, etc.

| New name | Old name |
|---|---|
| `MonitoringTelegramBotToken` | `telegram-monitoring-bot-token` |
| `MonitoringTelegramAlertsChatId` | `telegram-alerts-chat-id` |
| `MonitoringTelegramLogChatId` | `telegram-log-chat-id` |
| `PrintScanTelegramBotToken` | `printscan-bot-token` |
| `MachineWifiPsk` | `wifi-iot-psk` |

Telegram chat-id normalization: alerts and log channels are
always-channel (never DM, never group). C# side should accept
bare-positive id (what you copy from Telegram client tools) and
prepend `-100` if missing. Bot's `allowedUsers` are user IDs
(always positive); no normalization needed. Implementation
deferred — see "Deferred items" below.

### Print/scan feature status (current)

Live in production code, working unless flagged otherwise:

* **Image preprocess pipeline**: source → Lanczos3 upscale to
  600 dpi at A4 → grayscale → wrap in single-page PDF with
  `/Interpolate false` on the image XObject (so Ghostscript /
  CUPS does identity nearest-neighbour at the printer engine).
  dpi metadata stays in lockstep with pixel count so 1:1 mode
  preserves physical inches.
* **Content classifier** (combined heuristic):
  - quantised-colour count (4-bit/channel; threshold 512)
  - adjacent-pixel edge density (max-channel delta ≥64; threshold 5%)
  - few colours AND sharp edges → Graphics
  - many colours OR smooth edges → Photo
  - ambiguous → Photo (safe default)
  - returns ClassifierStats(UniqueQuantisedColours, EdgeDensity)
    so caption can show numbers
* **Real-ESRGAN routing** for Graphics-class images:
  - bot routes via renderer's `POST /image-upscale` with
    `realesr-animevideov3` model
  - GPU-first (Vulkan via mesa V3DV on Pi 4/5) → CPU fallback
    inside renderer
  - bot-level fallback: any failure → Lanczos3 with a Result
    flag (`NeuralFailedFellBackToLanczos`) and Error log
  - user override: 🧠 Upscaler picker (Auto / Photo / Graphics)
  - caption surfaces classifier verdict + stats so user sees
    routing choice before tapping Print
* **Multi-page PDF preview**: renderer's `POST /pdf-preview`
  rasterises first 3 pages via ImageMagick (Ghostscript-backed)
  to one stacked grayscale WebP. Bot ships as Document so
  Telegram doesn't recompress.
* **HEIC/AVIF**: bot routes via `POST /image-convert` →
  libheif heif-convert / libavif avifdec → PNG → normal Image
  staging path.
* **EPUB**: pandoc → docx → soffice via `/render`.
* **CSV**: explicitly refused.
* **Manual duplex wizard**: 🔄 Duplex button on multi-page
  Pageables (only when no other page constraint active).
  Two-pass with stack-flip instructions in caption between
  passes. Hardcoded direction; needs hands-on validation when
  a real printer arrives.
* **P2 compressed-photo consent**: Telegram-Photo uploads gated
  behind explicit `[☐ I accept compressed quality]` tap.
* **Pages picker**: All / Odd / Even radio. Per-page
  checkbox row when pageCount ≤ 10. Custom-range digit-keyboard
  (3×5 inline keyboard for arbitrary CUPS expressions, no
  text-input state machine).
* **Daemon stub**: writes received bytes to
  `/var/lib/printscan-daemon/printed/<ts>-<filename>` for
  end-to-end inspection without paper.
* **Scanner session handoff**: `/scanner` during your own active session moves
  the live control message to the new placeholder and demotes the previous
  head. This mirrors the print-session live-preview handoff pattern and gives
  users a recovery route if a Telegram edit is dropped.
* **Scan delivery stream ownership**: daemon image GETs write byte snapshots;
  bot upload tiers clone encoded streams for each Telegram request. This fixes
  the June 23 `ObjectDisposedException` path where album failure disposed a
  `scan-encoded` stream before per-variant fallback reused it.

### Renderer toolchain (binaries it spawns)

* **soffice** (LibreOffice) — Office formats → PDF
* **pandoc** — Markdown / EPUB → docx (then soffice)
* **xpstopdf** (libgxps) — XPS / OXPS → PDF
* **magick** (ImageMagick) — `/pdf-preview` rasterisation +
  stack + WebP encode (Ghostscript-backed)
* **pdfinfo** (poppler-utils) — `/pdf-info` page count
* **heif-convert** (libheif) + **avifdec** (libavif) — HEIC/AVIF
  → PNG
* **realesrgan-ncnn-vulkan** + animevideov3 model — neural
  upscaler for Graphics-class images

### Renderer hardening

`Modules/PrintersScanners/Renderer/default.nix`: PrivateNetwork,
IPAddressDeny=any, RestrictAddressFamilies=[AF_UNIX],
ProtectSystem=strict, ProtectHome, NoNewPrivileges, dropped
CapabilityBoundingSet+AmbientCapabilities, Protect{KernelTunables,
KernelModules,KernelLogs,ControlGroups,Clock,Hostname,Personality},
Restrict{SUIDSGID,Realtime,Namespaces}. PrivateDevices left off
(GPU access for Vulkan path); explicit
`DeviceAllow="char-drm rw"` narrows the cgroup device-allowlist
to just DRM. Per-job isolation via fresh subprocess per request.

### Pinned facts (survive compaction)

* HP LaserJet **P2015n** — host-based laser, no hardware duplex
  (P2015dn has it). 600 dpi mechanical engine, RET edge
  enhancement (the claimed 1200 dpi is engine 600 + analog
  dwell-time modulation, not 1200 dpi raster). 32 MB stock
  memory fits a 600 dpi A4 grayscale page (~17 MB raw). Driven
  via foo2zjs which decodes the host bitmap to ZJStream for the
  printer engine.
* **Epson Perfection V33** scanner. USB ID 04b8:0142.
  aarch64-on-aarch64 doesn't run the proprietary epkowa driver
  natively; we run an x86_64 stub helper via qemu-user binfmt
  (registered system-wide by the PrintScanServer profile when
  `epkowaScanner.enable`).
* **Pi 4 dual-NIC topology**: end0 + wlan0 bridged on the AP at
  L2. Without strict ARP + CONNMARK source-routing, asymmetric
  replies get dropped on MAC-IP-mismatch by the AP filter.
* **Pi 5 onboard radio**: BCM43455. Same WPA2-PPSK / hidden-SSID
  network as Pi 4 (`HyperAir.IotPsk`). No P2P (extraConfig
  `p2p_disabled=1`).
* **Generic mainline kernel** chosen for both Pi 4 and Pi 5
  rather than `linuxPackages_rpiX`. cache.nixos.org has mainline
  prebuilt; the Foundation patchset rebuilds from source on
  every nixpkgs bump (hours on the Pi). The patchset's GPU /
  camera / HAT-specific bits don't matter on a headless server.
  Vulkan via realesrgan-ncnn-vulkan reaches V3D through mesa
  userspace + mainline DRM either way.
* **Sops decryption**: per-machine age key derived from the
  host's `/etc/ssh/ssh_host_ed25519_key` (sops-nix's
  `age.sshKeyPaths`). Burnt Pi 4's key is unrecoverable; new
  GhostHome will have its own key after first boot, secrets
  must be re-encrypted to it manually before the bot / alerts
  services can decrypt successfully.

### Deferred items (no eta — these are the "after compaction,
remember these are open" notes)

1. **Manual duplex page-pairing direction** — needs hands-on
   testing on real printer. Wizard's flip text is best-guess for
   the P2015n's face-down output + Tray 1 face-up-top-leading
   feed. May need pass-2 → `outputorder=reverse`.
2. **Real CUPS / `lp` invocation** to replace daemon stub.
   Shape stable; one method-body change in PrintService.cs.
3. **cups-pdf as a CUPS queue** alongside the eventual real
   printer queue, gated by an env var.
4. **Doc-renderer test corpus** — integration-tested by hand
   only.
5. ~~**Telegram chat ID normalisation**~~ — DONE 2026-05-09 in
   `Modules/Monitoring/TelegramAlerts/default.nix`'s
   `telegramEnqueue` script. Bare-positive ids get `-100`
   prepended (channel namespace); already-negative pass
   through; non-numeric is rejected at enqueue. RendererClient
   HTTP timeout bumped 3 min → 6 min so /image-upscale's 5-min
   cap can return cleanly. Option-side descriptions on
   PhysicalServerBase + TelegramAlerts updated to document the
   accepted forms.
6. ~~**Pi minimalist first-boot image**~~ — DONE 2026-05-09.
   `Modules/Profiles/PhysicalServerProvisioning/` profile +
   `nixosConfigurations.GhostHome-provisioning-sdImage` flake
   entry. Operator workflow: build & flash; boot; pull host age
   key via `ssh-keyscan`; encrypt secrets to it; push as a
   branch/tag matching the image's `?ref=…` (default
   `ghosthome-ready`); image's first-boot timer self-flips on
   the next minute's retry. After reboot, the now-running
   GhostHome config has its own auto-rebuild-on-push tracking
   master (no ref filter), so the readiness ref is one-shot.
   Cross-compile from x86_64 should be cache-hits-only on the
   minimal closure (Linux+systemd+sshd, ~all in cache.nixos.org
   for aarch64); the SD image build doesn't fall back to
   qemu-user for anything substantive.
7. **Per-content-type upscaler variants** beyond animevideov3
   — line-art-aware (xBRZ / hqx) and photo-tuned neural
   (realesr-x4plus). Awaiting visual evaluation of the current
   baseline.
8. **Pi 5 brownout-mitigation** decisions — current GhostHome
   config doesn't include the boot-stability-probe nor the
   throttle-history sampler that Pi 4 needed. Re-add if Pi 5
   exhibits similar symptoms.
9. **Q3 follow-up**: move the print-scan profile's "add
   scanner/lp to administrator" to the profile itself rather
   than each machine config. The profile becomes mildly aware
   of the base profile's `administrator.name` option and uses
   list-merge on `users.users.${that}.extraGroups`. User
   approved this direction. NOT YET IMPLEMENTED — sitting
   one round behind the rename.

### Numbering convention for follow-up questions

User explicitly noted: "Q3 (btw pls use the same number set
for followup question numbers so that they didn't overlap with
prev round)". When user references "Q3" in a later round, they
mean the same topic carried over from the previous round.
Don't renumber. Group multi-round questions under their
original number with sub-numbering when needed (Q3.1, Q3.2,
…).

## Print Flow — Update 2026-05-17 (pixel-grid lockstep redesign)

### Symptoms that prompted this round

First production print of a 647×500 PNG at 96 dpi (Windows
screenshot of a colouring book page) surfaced two compounding
defects:

  * The auto-classifier correctly routed Graphics →
    Real-ESRGAN ×4 (output 2588×2000). But realesrgan-ncnn-vulkan
    emits the upscaled PNG WITHOUT a pHYs chunk, so the bot's
    downstream pipeline read the working PNG's DPI as ImageSharp's
    default 96 — the upscale factor was effectively erased from
    the metadata. PrintPreprocess then Lanczos3'd to 6421×4962 at
    a declared 238 dpi (= 96 × 2.481 — the additional Lanczos
    factor needed to reach the 600-dpi paper target). The PDF
    wrap dutifully drew that 238-dpi image at its declared
    physical size: ~27 × 21 inches. Way bigger than A4.
  * The "1:1 default" picker rejected the source as having no
    usable DPI because `MinReasonableDpi = 100` filtered out 96.
    With no DPI, `Fits1to1` returned `NotApplicable`, the
    default-mode-when-it-fits branch didn't fire, and the
    `PendingPrint.Scale` field's initial value
    (`PrintScaleMode.OneToOne`) stayed put. Net effect: bot
    defaulted to 1:1 on an image where 1:1 meant "27-inch image
    on 8.27-inch paper, corner shown" — described to the bot as
    "covers 0% of the page" (very nearly true since the visible
    portion was clipped to a fraction of one corner). Manual
    flip to Fit produced the right result, but it shouldn't have
    needed a manual override.

The Fit-mode end result also exposed a quieter design wart: the
Lanczos finishing pass scaled to paper-pixel dimensions, but
PrintPdfWrap's Fit-mode cm matrix subsequently squeezed the
image into the smaller printable rectangle. The ratio of
paper / printable on A4 with 4.23 mm margins is 1.042, which
showed up as 600 / 0.96 = **625 dpi effective ppi reported by
`pdfimages -list`** on the printed-stub PDF. Two slightly
different definitions of "the target size" interacting through
the cm matrix.

### Core redesign: the bitmap IS the engine pixel grid

The whole point of the prior `/Interpolate false` + 600-dpi
upscale was to prevent any downstream resample at Ghostscript,
foo2zjs, or the printer's RET. The redesign makes that
invariant unconditional under every Scale mode by sizing the
output bitmap to the **engine's full-paper pixel grid**, not
the printable area, and pre-composing every Scale mode's
content placement INSIDE that grid.

A4 at 600 dpi = exactly 4962 × 7016 px. The bot emits a
single-page PDF whose:

  * `MediaBox` = `[0 0 595.44 841.68]` (A4 in pt).
  * One `Image XObject` of exactly 4962 × 7016 px, declared
    `/Interpolate false`, /BitsPerComponent 8, /DeviceGray.
  * cm matrix = `595.44 0 0 841.68 0 0` — pure scale, no
    translate, image fills MediaBox exactly. The cm has
    integer-friendly multiplicities (image's 4962 px × 72/600 =
    595.44 pt, image's 7016 px × 72/600 = 841.68 pt → the cm
    exactly maps Image-XObject unit square to MediaBox).
  * No clip, no rotation, no fractional offsets.

Ghostscript inside the foo2zjs filter chain rasterises this
PDF. The image's pixel pitch IS the engine's dot pitch, so
nearest-neighbour at the rasterizer is identity. foo2zjs hands
the bitmap to the printer's mechanical engine unchanged.

### Why full paper, not printable area, for the output bitmap

Margins are operator-configured in mm. At 600 dpi:

  * 4.23 mm = 4.23 × 600 / 25.4 = **99.92 px** (fractional)
  * 5 mm    = 5 × 600 / 25.4    = **118.11 px** (fractional)

If we sized the bitmap to the printable rectangle and asked the
cm matrix to translate it to `(left_margin_pt, bottom_margin_pt)`,
that translate would carry the fractional pixel offset directly
into the rasterizer's space — Ghostscript would resample
neighbouring pixels to reconstruct the fractionally-shifted
grid, and the engine receives a sub-pixel-blurred version of
the source.

Sizing the bitmap to the FULL paper grid and filling the margin
areas with white inside the bitmap avoids that: the cm matrix
needs no translate (the image starts at MediaBox origin), and
the engine's mechanical non-printable strip just doesn't reach
the white edges. The printer doesn't know we put pixels there;
it simply can't print them. Crucially, the pixel grid alignment
holds regardless of what margin configuration the user picks —
even an absurd 7.3 mm setting can't introduce sub-pixel shift
because the bitmap is always 4962 × 7016 starting at (0,0).

### Scale-mode semantics inside the engine grid

Common pipeline:
  1. Decide effective orientation (Auto picks landscape iff
     source is wider than tall; Portrait/Landscape force it).
  2. Compute the content rectangle in engine pixels per Scale
     mode (see below). All four corners are integer.
  3. Lanczos3 source to exactly those integer dimensions. No
     `Math.Round(scale_factor × srcW)` — the target pixel count
     is the input to the resize, the ratio is whatever it is.
  4. Composite into a 4962 × 7016 white-fill canvas at the
     centre of the content rectangle. If the content rect
     overflows the canvas (1:1 on an oversized source), crop at
     canvas bounds.
  5. PDF wrap as above. `Result.{Width,Height,Dpi}` always
     report the canvas dims and 600 dpi — they describe the
     output bitmap, not the source.

  * **1:1**: target rect = `(srcW_in × 600, srcH_in × 600)` —
    the source's declared physical size at engine DPI. Centred
    on canvas. If source is bigger than canvas it gets cropped
    at canvas edges (1:1 + oversized = "show me the centre of
    the image at native size" — explicit operator choice).
  * **Fit**: target rect = largest rectangle inside the
    printable-in-engine-pixels rectangle that preserves source
    aspect. (Printable = paper minus margins; margins go through
    `Math.Round(margin_mm × 600 / 25.4)` to get integer px.)
  * **Fill**: target rect = smallest rectangle that COVERS the
    printable-in-engine-px rectangle while preserving aspect.
    May exceed printable on one axis; gets cropped at the canvas
    edges (which sit at paper edges, not printable, so a few
    pixels of margin overflow are visible if the printer's
    mechanical margin allows).

For "Fit decision" semantics (e.g., classifying coverage,
deciding default mode), the bot reasons about printable
dimensions even though the output bitmap is full-paper. So
margin configuration affects USER-FACING SIZING decisions but
never affects the output bitmap's pixel structure.

### Upscale path — multi-pass smart upscale + always-Lanczos finish

The path becomes (Graphics class):

  1. Real-ESRGAN ×4 pass. Result is `srcW × 4, srcH × 4`.
  2. If the longer dimension is still under `target_long × 0.9`,
     run a second Real-ESRGAN pass: ×2 if the remaining ratio is
     ≤ 2, else ×4. Cap at 2 neural passes total.
  3. Lanczos3 to the exact target integer pixel dimensions (down
     by whatever fraction the neural overshoot landed on). Always
     run; Lanczos3 is the only step that hits integer-exact
     pixels.

Rationale: Real-ESRGAN's deep-network output is sharpest when
it's downscaled by a small factor (the network produces output
that's slightly larger than asked; downsampling by Lanczos
preserves the synthesised detail). Lanczos UP from a too-small
neural output adds soft texture from interpolation, which is
what the user observed as "softer than a manual desktop
upscale." Always finishing with a small Lanczos-down kept the
sharpest detail of the neural pass while landing on exact
pixels.

For Photo class (or graphics-class with neural unavailable):
single Lanczos3 pass from source to target. Same exact-pixel
contract. Photo content doesn't benefit from neural; the
network would add hallucinatory texture instead.

For sources already LARGER than the target (high-resolution
photos exceeding 4962 × 7016 on the long axis), the same
Lanczos3 step runs down to the target. No special-casing.

### DPI enforcement at every component boundary

The realesrgan-ncnn binary doesn't write pHYs. To prevent metadata
leakage at that boundary, `RendererClient.UpscaleAsync` now
re-encodes the returned PNG through ImageSharp with:

  * `Metadata.HorizontalResolution = sourceDpi × neuralScale`
  * `Metadata.VerticalResolution   = sourceDpi × neuralScale`

The caller passes the source's DPI explicitly. If the source had
no pHYs, the caller passes 96 (the most common screenshot DPI
and ImageSharp's own PNG default; calling it "sourceDpi unknown"
and falling back to 96 is the same operational behaviour as
today minus the rejection).

### Coverage-driven default scale mode + dropping MinReasonableDpi

`MinReasonableDpi = 100` is removed. 96 dpi is THE most common
DPI in the wild (Windows screenshot default + every browser
"save as image" + every macOS Retina screenshot at 144 → 96
after retina-density normalisation by Telegram). Rejecting it
as "unreasonable" causes the wrong default mode.

Replacement: if a PNG's pHYs is absent or ≤ 0, fall back to 96
as a low-confidence guess. Any positive DPI is accepted as-is.

Default scale mode is now driven by **linear coverage**:

```
linearCoverage = max(srcShortInches / paperShortInches,
                     srcLongInches  / paperLongInches)
```

with srcShortInches = `min(srcWidthPx, srcHeightPx) / sourceDpi`
and srcLongInches the matching max. The thresholds:

  * `coverage < 0.25`: Fit — at 1:1 the source would look lost
    on the page (less than a quarter on the longest axis).
  * `0.25 ≤ coverage ≤ 1.10`: 1:1 — respect the source's declared
    physical size. The 1.10 ceiling allows slight overrun for
    bleed/registration-mark workflows where the source genuinely
    is paper-sized-plus-a-bit.
  * `coverage > 1.10`: Fit — source is clearly bigger than paper,
    Fit is the user's intent.

The 1:1 button badge:
  * `1:1 ✓` (green) — coverage fits within printable area.
  * `1:1 ⚠ margins` (orange) — fits paper, exceeds printable.
  * `1:1 ⚠ won't fit` (red) — exceeds paper. Previously this
    used the same orange ⚠ as the margin-clip case; now it's
    visually distinct so the operator can tell at a glance.

### Result-shape changes

`PrintPreprocess.ProcessForPrintAsync` continues to return a
`Result(PdfBytes, Width, Height, Dpi, ContentClass,
ClassifierStats, Upscaler)`. With the redesign:

  * `Width`, `Height`: still report the BITMAP dimensions — but
    now they're always `paperShortIn × 600, paperLongIn × 600`
    (4962 × 7016 for A4). They describe what we sent to CUPS.
  * `Dpi`: always 600. The "report what we sent" reading.
  * The interesting content dimensions (post-upscale, pre-pad)
    move into the log line — caller sees both
    `output 4962x7016 @ 600dpi (content 4762x3676 from 647x500 src,
    neural=Real-ESRGAN-x4-x2, finish=Lanczos3-down)`. The exact
    content size + every step taken is now operator-visible.

### What CUPS / Ghostscript / foo2zjs see now

Identical to before but with one tighter invariant: the PDF's
image XObject is exactly 4962 × 7016 px (for A4), MediaBox is
A4 in pt, cm is pure scale to MediaBox. /Interpolate false plus
exact pixel-grid alignment means nearest-neighbour at the
rasterizer is identity, foo2zjs filter passes bytes unchanged,
engine receives the bitmap with zero resample at any stage. The
only place a downscale could happen is during the Lanczos
finishing pass inside PrintPreprocess — which is the only stage
where we have full control of the kernel and sampling.

### Implementation, split into commits

  1. PLAN.md (this commit).
  2. RendererClient.UpscaleAsync: stamp pHYs on the returned PNG
     via ImageSharp using caller-supplied sourceDpi × neuralScale.
  3. PrintPreprocess: switch to engine-grid bitmap targeting,
     exact pixel sizing per Scale mode, white-fill canvas
     composite, finalDpi always 600. PrintPdfWrap simplified to
     identity cm matrix.
  4. Multi-pass neural upscale (overshoot then Lanczos-down).
  5. UX: drop MinReasonableDpi, coverage-driven default mode,
     red-overrun badge on 1:1 button.

### Real-paper test patterns to run at 600 dpi 1:1

For verifying the pipeline end-to-end on the actual printer once
hardware is connected. Goal: catch any sub-pixel scaling drift,
nearest-neighbor misfit, and resolving-power loss between source
PNG and toner-on-paper.

Off-the-shelf charts (general resolution / MTF):

  * USAF 1951 three-bar chart — find the smallest still-resolvable
    group. Public domain, easy printable PDFs at
    en.wikipedia.org/wiki/1951_USAF_resolution_test_chart and
    sites.astro.caltech.edu/~lah/ay105/pdf/e2-usaf1951.pdf.
  * Siemens star — radial spokes, aliasing visible as
    hyperbolic-divergence in the centre.
    blog.kasson.com/lens-screening-testing/printable-siemens-star-targets/
  * Ronchi rulings — fixed-frequency square-wave gratings;
    cleanest moiré-against-engine-grid indicator.
  * Bealecorner curated PDFs (incl. ISO 12233):
    bealecorner.org/red/test-patterns/.

Custom patterns we should generate (pixel-defined at 4962×7014):
these expose the specific failure modes the engine-grid-lockstep
design is supposed to prevent, and the public charts don't cover
them well because they're defined in mm, not pixels.

  * Nyquist combs — alternating black/white 1-px rows (horizontal,
    vertical, 45°). Any resampling in the chain collapses these
    to grey.
  * Single-pixel diagonals at 0.5°, 1°, 2°, 5° — periodic jogs
    against a straight ruler reveal sub-pixel drift, with each
    jog spaced 1/(scale-error) pixels.
  * 1-px-dot grid at 8/16/32 px spacing — missing or doubled
    dots reveal cumulative drift.
  * 1-px-thick concentric circles — radial moiré if the bitmap
    isn't pixel-aligned.

A small generator that emits a single 4962×7014 PNG combining
these (USAF group + Siemens star + the four pixel-locked patterns)
would be the canonical "did the whole stack stay pixel-perfect"
acceptance test. ImageSharp does this cleanly — defer until we
have a real printer attached.

### Neural upscale on the Pi 5 — Vulkan ICD investigation (2026-05-17)

Symptom: Real-ESRGAN-ncnn-vulkan binary fails fast on the Pi with
`vkCreateInstance failed -9 / invalid gpu device` in both Vulkan
and CPU (`-g -1`) modes. The binary calls vkCreateInstance
unconditionally before honouring `-g`, so a host with no Vulkan
ICD at all is a hard fail even for "CPU mode". GhostHome runs
without `hardware.graphics.enable` because that toggle wedged
stage-1 init on this Pi 5 image (suspected race between v3d/vc4
KMS init and the rest of stage 1) — so the global graphics stack
isn't an option.

Findings from on-Pi experiments (with `nix-shell -p mesa
vulkan-loader vulkan-tools` and explicit `VK_ICD_FILENAMES`):

  * **lvp_icd.aarch64.json (llvmpipe — Mesa software Vulkan)**:
    works. No `/dev/dri` access required, no video/render group,
    no kernel modules. Vulkan 1.4.341 instance comes up; ncnn
    compute shaders compile and run on CPU.
    Timing (500x647 grayscale source, realesr-animevideov3 ×4):
      - pass 0 (500x647 → 2000x2588): ~25–30 s wall-clock
      - pass 1 (2000x2588 → 8000x10352): ~370 s wall-clock
      - Lanczos finish + composite: ~5 s
      - grand total per print job: ~7 min on the Pi 5 four-core
    For comparison the same pipeline runs in ~45 s on an
    x86_64 laptop with llvmpipe.

  * **broadcom_icd.aarch64.json (v3dv — Pi 5 V3D7 hardware
    Vulkan)**: detected (Vulkan 1.3, V3DV Mesa 26.1.0, device
    "V3D 7.1.10.2"), but ncnn's compute shaders fail to compile:
      MESA: error: Failed to pack instruction 120: utof t197.l,
            t196; thrsw
      MESA: error: Failed to compile MESA_SHADER_COMPUTE prog 29
            with any strategy
      vkCreateComputePipelines failed -13
    Core-dumps in ~17 s. Not usable until Mesa v3dv fixes
    instruction packing for ncnn's compute pipelines. Worth
    re-checking after major Mesa bumps.

Decision: deploy llvmpipe-only ICD via the renderer's systemd
unit `environment.{VK_ICD_FILENAMES,LD_LIBRARY_PATH}` (no global
graphics enable; mesa + vulkan-loader pulled in via the renderer
package's `passthru`).

CPU saturation: the ncnn-vulkan backend on llvmpipe spawns one
worker thread per core (4 on the Pi 5), pinned to PSR 0/1/2/3,
each running at **~96 % CPU sustained**. Pi 5's four cores are
already at full utilisation during a pass — C#-side parallel
upscale jobs would just thrash. Bot is naturally single-job-at-
a-time (one user, one print at a time), so concurrency at the
job-orchestration layer isn't needed.

Alternative-upscaler bench, all on the same 500×647 grayscale
source going to 2000×2588:

| Tool                          | pass 0 wall | model               | notes               |
|-------------------------------|-------------|---------------------|---------------------|
| realesrgan-ncnn-vulkan + llvmpipe |  25–30 s | realesr-animevideov3 | current production  |
| upscayl-ncnn                  | ~25 s       | realesr-animevideov3 | same ncnn backend, rebranded — interchangeable |
| waifu2x-converter-cpp         |  126 s      | waifu2x CNN          | NEON SIMD, no Vulkan dep, ~4× slower; lower-quality model |

So **ncnn-vulkan-via-llvmpipe wins on both speed and model
choice**. The waifu2x lane was the most plausible non-Vulkan
alternative; it's both slower and uses a smaller / older model.

Follow-up worth keeping in mind if Pi-side latency turns out
to feel sluggish in practice: raise the multi-pass threshold
from 1.5 to ~3.0 so pass 1 only fires when pass 0 leaves us
with a > 3× gap. Most graphics inputs at sensible upload sizes
already clear that bar after a single pass; the Lanczos finish
handles the residual.

### Deploying renderer/module changes without GitHub round-trip

Standard deploy path (what auto-rebuild does):
  1. Push to `github:hypersw/HyperNix`.
  2. `auto-rebuild-github-checker.timer` (~60 s) sees a new rev
     on the watched branch.
  3. `auto-rebuild-switch.service` runs:
        nix flake update upstream --flake /etc/nixos
        nixos-rebuild switch --flake /etc/nixos#default
     Only the `upstream` input is updated — nixpkgs / nixos-
     hardware stay pinned to whatever /etc/nixos/flake.lock had
     (no surprise kernel rebuild, no surprise dbus impl swap).

When the GitHub push is blocked (e.g. TPM PIN unavailable) and
the change needs to land NOW:

    rsync -a --exclude='result' /local/HyperNix/ ghosthome:/var/tmp/HyperNix/
    ssh ghosthome 'sudo nixos-rebuild test --flake /etc/nixos#default \
        --override-input upstream path:/var/tmp/HyperNix'

`--override-input upstream path:...` keeps the Pi's /etc/nixos
flake.lock — same nixpkgs pin, same nixos-hardware pin — and
only swaps the `upstream` source for the local path. `test`
activates without writing a new boot entry, so a reboot rolls
back. Use `switch` once you're confident.

DON'T deploy with `--flake /var/tmp/HyperNix#GhostHome` directly:
that uses the HyperNix repo's own `flake.lock` which can drift
behind /etc/nixos's. The first time I did this the local lock
had nixpkgs ~3 weeks older than the Pi's pin, so the build
wanted to downgrade dbus-broker → vanilla dbus and `switch`
got blocked by the impl-change inhibitor. The local lock
divergence comes from /etc/nixos having been manually
`nix flake update`d at some past point — auto-rebuild itself
never touches anything but `upstream`.

### Print-job progress wire (added 2026-05-17)

Renderer's `/image-upscale` is `text/event-stream` now. Frames
(after the standard `data: <json>\n\n` SSE encoding):

  * `{"type":"progress","percent":42.0}` — emitted per percent
    step from realesrgan-ncnn-vulkan's stdout/stderr. Throttled
    server-side so duplicate floor()'d values don't flood.
  * `{"type":"stage","stage":"cpu-fallback"}` — when the auto
    path bails out of GPU into CPU. Logged in the bot for
    debug, not surfaced to the user.
  * `{"type":"error","title":"...","detail":"..."}` — terminal,
    no `result` follows.
  * `{"type":"result","bytes":"<base64>"}` — terminal, contains
    the upscaled PNG inline. Bot decodes and pHYs-stamps the
    bytes before returning to PrintPreprocess.

Bot's RendererClient consumes the stream incrementally
(`HttpCompletionOption.ResponseHeadersRead` + `StreamReader.
ReadLineAsync`) and reports per-pass percent via
`IProgress<double>` to PrintPreprocess.

PrintPreprocess pre-walks the multi-pass loop's 1.5× ratio
gate once before the first pass to decide how many passes will
fire. Surface-area weights (pass N = 16^N units) reserve each
pass's slice of the global bar. Stage detail is the literal
"neural pass M of N · KK%" string.

### Future work: CUPS-side progress

Today PrintService is still the stub (writes to disk +
2-second sleep). When real CUPS lands, `PrintStage.Printing`
is the slot where its per-job percent shows up:

  * IPP attribute `job-media-progress` is spec for the
    per-job percent (cups-tools exposes via `lpstat -o
    PRINTER -W not-completed` and `cupsGetJobs2`).
  * For HP P2015n via foo2zjs the practical granularity is
    per-page, not per-byte — `job-impressions-completed` /
    `job-impressions` gives the right ratio.
  * Poll on a ~1 s timer while the job is in flight; feed the
    bot's `BotPrintSession.PrintProgress` field same as the
    preprocess path. The live message already has the
    "🖨 Printing X" stage line, only the bar needs filling in.

Until then `PrintStage.Printing` shows the stage label with
no bar (PrintProgress=-1), which is fine for the stub's 2-s
sleep but worth fleshing out before real prints can land.
