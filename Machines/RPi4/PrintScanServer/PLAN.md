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
- `POST /sessions/{id}/scan` — ask for one scan now (not waiting for the button)
- `GET /sessions/{id}/image/{seq}` — stream an already-captured image (octet-stream, chunked; bot uses this on restart-retry)
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
  shows user a confirmation; on confirm, bot retries with `?takeover=true`.
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
scanimage stdout → daemon RecyclableMemoryStream → SSE chunked → bot
   → bot writes /var/lib/printscan-bot/<session>/<seq>.<ext>
   → bot.SendDocument(InputFileStream) → Telegram
   → on 200 OK: delete staged file; emit bot-side log
```

The daemon end uses `Microsoft.IO.RecyclableMemoryStream` — chunked pool-backed,
no LOH pressure, swap-friendly. The bot end stages to disk *before* attempting
the TG upload so an upload failure (network, TG rate-limit, bot crash) leaves
the scan recoverable.

**On bot startup**, scan directory is swept: any files still present are
uncommitted uploads to retry. Small per-session metadata file (`manifest.json`)
captures `seq → { chatId, filename, caption, contentType }` so retries don't
need session-server coordination.

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
