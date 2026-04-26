{ pkgs }:

let
  # Generate C# source with full nix-store paths to every external
  # tool the renderer drives. Baked into the assembly at build time —
  # same GC-rooted pattern the print/scan daemon uses for scanimage
  # and lp. Each tool is a separate, well-scoped subprocess; the
  # parent C# process never links or dlopens any of them.
  #
  # Tool roles:
  #   * soffice (LibreOffice) — DOC/DOCX/ODT/ODS/PPT/XLS/RTF/HTML/TXT
  #     → PDF. The "s" in soffice is from StarOffice (Sun's commercial
  #     forerunner before OOo was open-sourced in 2000); LibreOffice
  #     forked from OpenOffice in 2010 and is now the canonical FOSS
  #     office suite.
  #   * pandoc + weasyprint — Markdown (with LaTeX math) → PDF.
  #     pandoc renders the markdown via its own AST and delegates the
  #     final PDF step to weasyprint (HTML+CSS engine). Avoids dragging
  #     in a full TeX Live install (~2 GB) just for math; weasyprint
  #     does maths via MathML produced by pandoc.
  #   * libgxps (xpstopdf) — XPS / OXPS → PDF. Handles Microsoft's
  #     legacy fixed-document format that soffice can't import.
  #   * poppler-utils (pdfinfo / pdftoppm) — page-count metadata and
  #     thumbnail rasterisation for the bot's preview/checkbox UI.
  toolPathsCs = pkgs.writeText "ToolPaths.g.cs" ''
    namespace PrintScan.Renderer;

    static class ToolPaths
    {
        public static readonly string Soffice =
            "${pkgs.libreoffice}/bin/soffice";
        public static readonly string Pandoc =
            "${pkgs.pandoc}/bin/pandoc";
        public static readonly string XpsToPdf =
            "${pkgs.libgxps}/bin/xpstopdf";
        public static readonly string PdfInfo =
            "${pkgs.poppler-utils}/bin/pdfinfo";
        public static readonly string PdfToPpm =
            "${pkgs.poppler-utils}/bin/pdftoppm";
        // libheif's heif-convert decodes HEIC / HEIF (Apple devices)
        // and recent libheif builds also handle AVIF (AV1-encoded HEIF
        // container). Outputs JPEG / PNG / Y4M; we use PNG for
        // lossless transitional bytes the bot then re-reads via
        // ImageSharp.
        public static readonly string HeifConvert =
            "${pkgs.libheif}/bin/heif-convert";
        // libavif's avifdec — AVIF-specific decoder, used as a
        // fallback when heif-convert reports an unsupported AV1
        // codec configuration or build of libheif without the AOM
        // backend.
        public static readonly string AvifDec =
            "${pkgs.libavif}/bin/avifdec";
    }
  '';
in

pkgs.buildDotnetModule {
  pname = "printscan-renderer";
  version = "0.1.0";
  src = ./src;
  projectFile = "PrintScan.Renderer.csproj";
  dotnet-sdk = pkgs.dotnet-sdk_10;
  dotnet-runtime = pkgs.dotnet-aspnetcore_10;
  nugetDeps = ./deps.json;

  postPatch = ''
    cp ${toolPathsCs} ToolPaths.g.cs
  '';

  # Pin libreoffice as a runtime dep so it's part of the package
  # closure — the systemd unit doesn't otherwise reference it.
  passthru.libreoffice = pkgs.libreoffice;
}
