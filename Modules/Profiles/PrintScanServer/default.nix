{ config, lib, pkgs, ... }:
#
# PrintScanServer profile — single import that turns a host into the
# full print/scan stack: HP LaserJet driver via foo2zjs, Epson Perfection
# V33 scanner via the x86_64 epkowa-stub IPC, the print/scan daemon, the
# rendering sidecar (LibreOffice/pandoc/ImageMagick/heif-convert/avifdec/
# realesrgan), the Telegram bot front-end, plus a broad font set for the
# renderer's PDF font fallback.
#
# Hardware assumption: any aarch64 / x86_64 Linux host with USB. Hardware
# specifics (Pi 4 vs Pi 5 firmware, mmc / NVMe rootfs, brownout-mitigation
# kernel config) stay in the per-machine configuration; this profile is
# hardware-agnostic.
#
# The single mandatory caller-supplied input is the bot's API token
# (services-of-secrets surface — see below). Everything else has
# sensible defaults that match the HP P2015n / Epson V33 setup; the
# nix module options of the underlying services are still fully
# settable from the caller for one-off overrides.
#
let
  cfg = config.profiles.printScanServer;
in
{
  imports = [
    ../../PrintersScanners/LaserJetPrinter
    ../../PrintersScanners/EpkowaScanner
    ../../PrintersScanners/Daemon
    ../../PrintersScanners/Renderer
    ../../PrintersScanners/TelegramBot
  ];

  options.profiles.printScanServer = {
    enable = lib.mkEnableOption "Full print/scan server stack (CUPS + scanner + renderer + Telegram bot)";

    bot = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run the Telegram bot front-end. Disable for headless / cron-only setups.";
      };
      tokenFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          Path to a file containing the print/scan Telegram bot's API
          token. Typically <literal>config.sops.secrets.NAME.path</literal>;
          the path-not-secret-handle convention keeps the meta-module
          decoupled from the secret-delivery mechanism (sops / agenix /
          raw file).
        '';
      };
      allowedUsers = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            id   = lib.mkOption { type = lib.types.int; };
            name = lib.mkOption { type = lib.types.str; };
          };
        });
        default = [];
        description = ''
          Telegram users allowed to talk to the bot. Empty list means
          the bot rejects everyone, which is rarely what you want —
          set this in the caller's machine config.
        '';
      };
    };

    printer = {
      mediaSize = lib.mkOption {
        type = lib.types.str;
        default = "A4";
        description = "Default paper size — passed through to the daemon's mediaSize option.";
      };
      nonPrintableMarginsMm = lib.mkOption {
        type = lib.types.submodule {
          options = {
            top    = lib.mkOption { type = lib.types.float; default = 4.23; };
            bottom = lib.mkOption { type = lib.types.float; default = 4.23; };
            left   = lib.mkOption { type = lib.types.float; default = 4.23; };
            right  = lib.mkOption { type = lib.types.float; default = 4.23; };
          };
        };
        default = {};
        description = ''
          Non-printable margins of the loaded paper (mm). Defaults
          match HP LaserJet P2015n's plain-A4 spec; override per
          printer or paper choice.
        '';
      };
    };

    fonts = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Install a broad system font set so the renderer's PDF
          fallback (Ghostscript / soffice / pandoc) can substitute
          plausible glyphs for un-embedded fonts. Without this,
          PDFs with un-embedded fonts fall back to Type 3 boxes.
        '';
      };
    };

    epkowaScanner = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable the Epson scanner (epkowa) driver path.";
      };
    };

    laserjetPrinter = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable the HP LaserJet (foo2zjs) driver path.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # ── core daemon + renderer (always on when profile enabled) ──
    services.printscan-daemon = {
      enable = true;
      mediaSize = cfg.printer.mediaSize;
      nonPrintableMarginsMm = cfg.printer.nonPrintableMarginsMm;
    };
    services.printscan-renderer.enable = true;

    # ── opt-in legs ──────────────────────────────────────────────
    services.laserjet-printer.enable = cfg.laserjetPrinter.enable;
    services.epkowa-scanner.enable   = cfg.epkowaScanner.enable;

    services.printscan-telegram-bot = lib.mkIf cfg.bot.enable {
      enable = true;
      tokenFile = cfg.bot.tokenFile;
      allowedUsers = cfg.bot.allowedUsers;
    };

    # ── x86_64 binfmt for the EpkowaScanner stub ──
    # The Epson scanner driver path uses a short-lived x86_64 helper
    # per scan (see EpkowaStubX64/PROTOCOL.md). qemu-user runs it
    # transparently. The binfmt registration is system-wide, not
    # daemon-local, so it lives at this composition layer.
    boot.binfmt.emulatedSystems =
      lib.mkIf cfg.epkowaScanner.enable [ "x86_64-linux" ];

    # ── fonts ─────────────────────────────────────────────────────
    fonts.packages = lib.mkIf cfg.fonts.enable (with pkgs; [
      dejavu_fonts          # neutral sans / serif / mono, public domain
      liberation_ttf        # metric-compatible with Arial / Times / Courier
      corefonts             # actual MS Arial / Times / Courier
      noto-fonts            # huge Unicode coverage
      noto-fonts-cjk-sans   # CJK fallback
      freefont_ttf          # GNU FreeFont — additional metric-compat
      cantarell-fonts       # GNOME default sans
      source-sans
      source-serif
      source-code-pro
    ]);

    # SANE userspace tools — useful for the administrator on the
    # box (scanimage --list-devices etc).
    environment.systemPackages = lib.mkIf cfg.epkowaScanner.enable
      (with pkgs; [ sane-backends ]);

    # Profile is mildly aware of PhysicalServerBase — it reads the
    # configured administrator name and appends the print/scan-
    # specific groups via NixOS list-merge. Saves machine configs
    # from each having to know that scanner+lp are needed for
    # SANE+CUPS, and from re-stating the admin user's name.
    #
    # We don't assert that the base profile is enabled — if it's
    # not, nix evaluation here resolves an unconfigured option
    # default and we'd be appending groups to a "administrator"
    # user that doesn't exist. That's a degenerate case (someone
    # using PrintScanServer without PhysicalServerBase, which the
    # README doesn't recommend); a hard assertion is overkill.
    users.users.${config.profiles.physicalServerBase.administrator.name}
      .extraGroups =
        lib.optionals cfg.epkowaScanner.enable [ "scanner" ]
        ++ lib.optionals cfg.laserjetPrinter.enable [ "lp" ];
  };
}
