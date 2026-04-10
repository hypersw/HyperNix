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
  - Resolution: 200 dpi (default), with other options available
  - Format: JPEG 90% quality (default), PNG or TIFF as lossless alternatives
  - Scan result is sent back over the bot as a file

- **Physical button**: pressing the scanner's hardware button triggers a scan
  automatically, but only if a bot session is active (someone requested a scan
  within the last ~10 minutes). Uses the same settings as the last bot request.
  Result goes to the same user's chat.

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
- Hardware button: epkowa does NOT expose button sensors, so scanbd/scanbuttond can't poll it.
  Workaround: monitor USB HID interrupt endpoint directly for button press events, bypass SANE
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

### Scanner Button Detection (Epson V33)

- V33 buttons use **vendor-specific bulk commands** (ESC/I protocol), NOT USB HID
- No `/dev/input/` or `/dev/hidraw/` events — the host must **poll** the scanner
- **scanbuttond** `backends/epson.c` is the best reference for the ESC/I button query
  command format (sends `ESC !`, reads response byte with button state)
- **scanbd** and **insaned** use SANE polling but epkowa doesn't expose buttons — won't work
- Reverse-engineering approach:
  1. `lsusb -v -d 04b8:0142` to enumerate interfaces/endpoints
  2. `modprobe usbmon` + Wireshark on `usbmonN` to capture USB traffic
  3. pyusb script to poll with suspected ESC/I commands while pressing buttons
  4. Diff responses to map which bytes/bits correspond to which buttons
- The scanner has 4 buttons — all should generate distinct response patterns
- The polling daemon can be part of the main service daemon or a separate systemd unit

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

**Endpoints (draft):**
- `POST /print` — accept file (PDF/image), options (page range, copies)
- `POST /scan` — start scan with options (resolution, format), returns job ID
- `GET /scan/{id}` — poll scan status, download result when done
- `GET /status` — printer/scanner status (online, paper, errors)
- `POST /button/subscribe` — register for scanner button events (with callback)
- `GET /jobs` — list recent print/scan jobs

**Scanner button integration:** the daemon's button poller thread monitors the
scanner via ESC/I bulk commands (every 500ms). On button press, it checks for
active subscriptions (e.g., a Telegram user requested scan within 10 min) and
auto-starts a scan with that user's last settings. Result is pushed to the
subscriber via their bot.

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

Using a camcorder-grade high-endurance SD card. Additional measures:
- `boot.tmp.useTmpfs = true` — /tmp in RAM
- `services.journald.extraConfig = "Storage=volatile"` — journal in RAM only
- `fileSystems."/".options = [ "noatime" ]` — no access time writes
- `nix.settings.auto-optimise-store = true` — dedup hard links in store
- `nix-collect-garbage` on a weekly timer
- Consider `f2fs` for root filesystem (flash-friendly, less tested with NixOS)

### Duplex Printing

Deferred. P2015n has no duplex unit. Manual even/odd via print-to-file for now.
Could add bot UI for this later (print odd → prompt user to flip → print even).

### Build & Deploy

1. **Initial**: Ethernet connection. Cross-build SD image on x86_64 host via
   `boot.binfmt.emulatedSystems`. Flash to SD, boot RPi4.
2. **Ongoing**: `system.autoUpgrade.flake = "github:hypersw/HyperNix#Machines-RPi4-PrintScanServer"`
   with `--refresh` daily. `OnFailure` → Telegram alert on upgrade failure
3. **WiFi**: added later, EAP-PEAP with Unifi built-in RADIUS, password via sops-nix
4. **Public repo**: readonly GitHub access, no deploy key needed for `nix build`

### Implementation Order

1. Machine flake (NixOS config, cross-build image, boot on RPi4 via Ethernet)
2. Scanner button reverse-engineering (pyusb script on dev host with scanner connected)
3. LaserJetPrinter module (CUPS + foo2zjs, verify printing works)
4. EpkowaScanner module (SANE + epkowa, verify scanning works)
5. Print/Scan daemon (C#, Unix socket API, print/scan job handling, button poller)
6. Telegram bot (C#, long-polling, file receive → print, /scan command → scan)
7. AirSane (LAN scanning for iOS/macOS/Android)
8. Monitoring module (OnFailure + health timer → Telegram)
9. WiFi configuration (EAP-PEAP, separate SSID)
10. WhatsApp bot (Node.js/Baileys, same Unix socket API)
11. Web UI (SPA + oauth2-proxy + TCP API with key)
