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
