using System.IO.Compression;
using System.Text;
using PrintScan.Shared;
using SixLabors.ImageSharp;
using SixLabors.ImageSharp.PixelFormats;
using SixLabors.ImageSharp.Processing;

namespace PrintScan.TelegramBot;

/// <summary>
/// Wrap an upscaled, grayscale image into a hand-rolled single-page
/// PDF whose MediaBox, image-XObject resolution, and rendering
/// directives are all designed to defeat any further resampling
/// downstream. The "downstream" we care about is Ghostscript inside
/// CUPS' rasterization filter chain — when our image's pixel grid
/// lines up with the printer's mechanical resolution and we emit
/// <c>/Interpolate false</c> on the Image dict, GS does an identity
/// nearest-neighbor map at the rasterizer and the foo2zjs filter
/// then passes the bitmap to the printer engine pixel-for-pixel
/// (modulo RET edge enhancement).
///
/// Why a hand-rolled PDF rather than a library: the surface we need
/// is a single-page-with-one-image PDF — twenty objects total at the
/// outside. QuestPDF / iText / PdfSharp would each pull in a
/// few-hundred-KB-to-MB of dependencies for that. The trade-off is
/// that we maintain ~50 lines of explicit byte-offset bookkeeping
/// for the xref table; in exchange there's nothing to keep current
/// with PDF-spec churn (1.4 features cover everything we need).
/// </summary>
public static class PrintPdfWrap
{
    /// <summary>
    /// Build a print-ready single-page PDF whose page geometry is
    /// the configured paper, wrapping a bitmap that has ALREADY been
    /// composed to the engine pixel grid for the full paper
    /// (paperShort × 600 px by paperLong × 600 px for A4 = 4962×7016).
    /// Scale-mode placement, orientation, margin insets, and
    /// white-fill have all been baked into the bitmap by the caller
    /// (PrintPreprocess.ProcessForPrintAsync). This function's job
    /// is just to wrap that bitmap in a minimal-viable PDF whose cm
    /// matrix maps the image XObject identity-onto the MediaBox.
    /// </summary>
    public static byte[] WrapImage(
        Image<L8> grayImage,
        double paperShortInches, double paperLongInches)
    {
        // PDF user space is 1/72 inch. MediaBox is the paper in
        // portrait orientation — short × long. The caller's bitmap
        // is also short × long (portrait-shaped); landscape content
        // is realised by rotating WITHIN the bitmap, not by swapping
        // the page dimensions.
        const double PtPerInch = 72.0;
        var mediaWPt = paperShortInches * PtPerInch;
        var mediaHPt = paperLongInches  * PtPerInch;

        // cm matrix: scale-only, no translate. The image's unit
        // square (0..1 × 0..1) maps to the MediaBox exactly. Pure
        // integer-friendly scale: grayImage.Width × 72/600 maps to
        // mediaWPt by construction (and same on H). No sub-pixel
        // offset for Ghostscript to interpolate around.
        var cmMatrix = $"{F(mediaWPt)} 0 0 {F(mediaHPt)} 0 0";

        // Pixel data: dump the L8 buffer raw, deflate as zlib (PDF's
        // /FlateDecode format = RFC 1950 zlib stream, NOT raw deflate
        // — ZLibStream is the right type, DeflateStream would emit a
        // headerless raw stream that GS would reject).
        var pixels = new byte[grayImage.Width * grayImage.Height];
        grayImage.CopyPixelDataTo(pixels);
        byte[] deflatedPixels;
        using (var ms = new MemoryStream())
        {
            using (var zlib = new ZLibStream(ms, CompressionLevel.Optimal, leaveOpen: true))
                zlib.Write(pixels);
            deflatedPixels = ms.ToArray();
        }

        // Content stream — graphics-state save, cm transform, image
        // draw, restore. No clip needed (bitmap fills MediaBox
        // exactly, no overflow possible).
        var contentBytes = Encoding.ASCII.GetBytes(
            $"q\n{cmMatrix} cm\n/Im0 Do\nQ\n");

        // Object emission. Order: Catalog, Pages, Page, Image,
        // Contents. We emit in this order so referenced objects
        // exist by the time the referencing object's dict serializes
        // — the actual on-disk order is what determines xref offsets,
        // not the object-number ordering.
        var pdf = new MinimalPdfBuilder();

        var catalogNum = pdf.BeginObject();
        pdf.WriteDict("<< /Type /Catalog /Pages 2 0 R >>");
        pdf.EndObject();

        var pagesNum = pdf.BeginObject();
        pdf.WriteDict("<< /Type /Pages /Kids [3 0 R] /Count 1 >>");
        pdf.EndObject();

        var pageNum = pdf.BeginObject();
        pdf.WriteDict(
            "<< /Type /Page /Parent 2 0 R " +
            $"/MediaBox [0 0 {F(mediaWPt)} {F(mediaHPt)}] " +
            "/Resources << /XObject << /Im0 4 0 R >> >> " +
            "/Contents 5 0 R >>");
        pdf.EndObject();

        var imageNum = pdf.BeginObject();
        var imageDict =
            "<< /Type /XObject /Subtype /Image " +
            $"/Width {grayImage.Width} /Height {grayImage.Height} " +
            "/ColorSpace /DeviceGray /BitsPerComponent 8 " +
            // /Interpolate false: when the rasterizer's output dot
            // pitch differs from the image's pixel pitch, do
            // nearest-neighbor instead of bilinear. Combined with
            // a 600-dpi-targeted upscale this gives identity
            // mapping at the printer engine.
            "/Interpolate false " +
            "/Filter /FlateDecode " +
            $"/DecodeParms << /Predictor 1 /Columns {grayImage.Width} >>";
        pdf.WriteStream(imageDict, deflatedPixels);
        pdf.EndObject();

        var contentsNum = pdf.BeginObject();
        pdf.WriteStream("<<", contentBytes);
        pdf.EndObject();

        return pdf.Finish(catalogNum);
    }

    /// <summary>Compact double-to-string for PDF; avoids scientific.</summary>
    private static string F(double v) =>
        v.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture);
}

/// <summary>
/// Minimal PDF byte-stream builder. Tracks indirect-object byte
/// offsets so the trailing xref table is exact. Only knows the
/// concepts our wrapper needs — direct-dict objects and
/// stream objects with /FlateDecode bytes.
/// </summary>
internal sealed class MinimalPdfBuilder
{
    private readonly MemoryStream _stream = new();
    /// 1-based: index 0 is the catalog (object number 1), and so on.
    private readonly List<long> _offsets = new();
    private static readonly Encoding Latin1 = Encoding.GetEncoding("ISO-8859-1");

    public MinimalPdfBuilder()
    {
        // %PDF-1.4 marker. The four-byte binary comment that follows
        // is the spec's recommended hint to transfer agents that
        // this is a binary file (some legacy MTAs would otherwise
        // CRLF-mangle the content streams).
        WriteAscii("%PDF-1.4\n");
        _stream.WriteByte((byte)'%');
        _stream.WriteByte(0xE2);
        _stream.WriteByte(0xE3);
        _stream.WriteByte(0xCF);
        _stream.WriteByte(0xD3);
        WriteAscii("\n");
    }

    public int BeginObject()
    {
        var num = _offsets.Count + 1;
        _offsets.Add(_stream.Position);
        WriteAscii($"{num} 0 obj\n");
        return num;
    }

    public void EndObject()
    {
        WriteAscii("endobj\n");
    }

    /// <summary>Emit a direct-dict object body, e.g. "&lt;&lt; /Type /Foo &gt;&gt;".</summary>
    public void WriteDict(string dictBody)
    {
        WriteAscii(dictBody);
        WriteAscii("\n");
    }

    /// <summary>
    /// Emit a stream object. <paramref name="dictPrefix"/> is the
    /// open dict literal up to (but excluding) the closing "&gt;&gt;";
    /// the builder tacks on the /Length entry for the supplied
    /// stream bytes. Pass "&lt;&lt;" alone for a stream with no
    /// other dict entries.
    /// </summary>
    public void WriteStream(string dictPrefix, byte[] streamBytes)
    {
        // PDF spec requires /Length to declare the exact byte count
        // of the stream payload (between the bytes following "stream\n"
        // and the byte preceding the trailing newline + "endstream").
        // We always emit /Length as an inline integer rather than as
        // an indirect reference — simpler, no second pass.
        WriteAscii(dictPrefix);
        WriteAscii($" /Length {streamBytes.Length} >>\n");
        WriteAscii("stream\n");
        _stream.Write(streamBytes);
        WriteAscii("\nendstream\n");
    }

    /// <summary>
    /// Close the file: emit the xref table, trailer, startxref,
    /// %%EOF. Returns the assembled bytes.
    /// </summary>
    public byte[] Finish(int rootObjectNum)
    {
        var xrefOffset = _stream.Position;
        WriteAscii("xref\n");
        WriteAscii($"0 {_offsets.Count + 1}\n");
        // Object 0 is the head of the free-objects list — required
        // by the spec, generation 65535, marker 'f'.
        WriteAscii("0000000000 65535 f \n");
        foreach (var off in _offsets)
            WriteAscii($"{off:D10} 00000 n \n");
        WriteAscii("trailer\n");
        WriteAscii($"<< /Size {_offsets.Count + 1} /Root {rootObjectNum} 0 R >>\n");
        WriteAscii($"startxref\n{xrefOffset}\n%%EOF\n");
        return _stream.ToArray();
    }

    private void WriteAscii(string s) => _stream.Write(Latin1.GetBytes(s));
}
