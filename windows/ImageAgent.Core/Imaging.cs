using SkiaSharp;
using System.Buffers.Binary;
using System.IO.Compression;
using System.Runtime.InteropServices;
using BitMiracle.LibTiff.Classic;

namespace ImageAgent.Core;
public sealed class DecodedImage
{
    public const int MaximumBytes = 100 * 1024 * 1024;
    public byte[] Data { get; }
    public int Width { get; }
    public int Height { get; }
    public string MediaType { get; }
    public string Extension { get; }

    public DecodedImage(byte[] data)
    {
        if (data.Length == 0 || data.Length > MaximumBytes || !CompletePNG(data))
            throw new AgentException("图片损坏、截断或超过 100 MiB。");
        if (IsTiff(data))
        {
            var t = TiffPixels(data);
            Width = t.Width;
            Height = t.Height;
            MediaType = "image/tiff";
            Extension = "tiff";
        }
        else
        {
            using var codec = SKCodec.Create(new SKMemoryStream(data));
            if (codec == null || codec.FrameCount > 1)
                throw new AgentException("返回内容无法解码为有效的单帧图片。");
            var info = codec.Info;
            ValidateDimensions(info.Width, info.Height);
            using var b = new SKBitmap(new SKImageInfo(info.Width, info.Height, SKColorType.Rgba8888, SKAlphaType.Premul, info.ColorSpace));
            if (codec.GetPixels(b.Info, b.GetPixels()) != SKCodecResult.Success)
                throw new AgentException("图片字节不完整。");
            Width = info.Width;
            Height = info.Height;
            (MediaType, Extension) = codec.EncodedFormat switch
            {
                SKEncodedImageFormat.Png => ("image/png", "png"),
                SKEncodedImageFormat.Jpeg => ("image/jpeg", "jpg"),
                SKEncodedImageFormat.Webp => ("image/webp", "webp"),
                SKEncodedImageFormat.Bmp => ("image/bmp", "bmp"),
                SKEncodedImageFormat.Gif => ("image/gif", "gif"),
                _ => throw new AgentException("图片编码格式不支持。")};
        }

        Data = data;
    }

    public static void ValidateDimensions(int w, int h)
    {
        if (w <= 0 || h <= 0 || (long)w * h > 150000000)
            throw new AgentException("图片像素缓冲无效或超过 150M 像素。");
    }

    public static byte[] ClipboardBytes(byte[] data)
    {
        var d = new DecodedImage(data);
        return new[]
        {
            "image/png",
            "image/jpeg",
            "image/webp"
        }.Contains(d.MediaType) ? data : PixelImage.Decode(data).PngData();
    }

    public static bool CompletePNG(byte[] b)
    {
        if (b.Length < 8 || !b.AsSpan(0, 8).SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }))
            return true;
        var p = 8;
        while (p <= b.Length - 12)
        {
            uint n = BinaryPrimitives.ReadUInt32BigEndian(b.AsSpan(p, 4));
            if (n > b.Length - p - 12)
                return false;
            if (b.AsSpan(p + 4, 4).SequenceEqual("IEND"u8))
                return n == 0;
            p += (int)n + 12;
        }

        return false;
    }

    internal static bool IsTiff(byte[] b) => b.Length >= 4 && ((b[0] == 73 && b[1] == 73 && b[2] == 42 && b[3] == 0) || (b[0] == 77 && b[1] == 77 && b[2] == 0 && b[3] == 42));
    internal static PixelImage TiffPixels(byte[] b)
    {
        using var stream = new MemoryStream(b, false);
        using var t = Tiff.ClientOpen("clipboard", "r", stream, new TiffStream());
        if (t == null || t.NumberOfDirectories() != 1)
            throw new AgentException("TIFF 损坏或包含多帧。");
        int w = t.GetField(TiffTag.IMAGEWIDTH)[0].ToInt(), h = t.GetField(TiffTag.IMAGELENGTH)[0].ToInt();
        ValidateDimensions(w, h);
        int orientation = t.GetField(TiffTag.ORIENTATION)?[0].ToInt() ?? 1;
        t.SetField(TiffTag.ORIENTATION, Orientation.TOPLEFT);
        var raster = new int[w * h];
        if (!t.ReadRGBAImageOriented(w, h, raster, Orientation.TOPLEFT))
            throw new AgentException("TIFF 图片字节不完整。");
        var bytes = new byte[w * h * 4];
        for (int i = 0; i < raster.Length; i++)
        {
            bytes[i * 4] = (byte)Tiff.GetR(raster[i]);
            bytes[i * 4 + 1] = (byte)Tiff.GetG(raster[i]);
            bytes[i * 4 + 2] = (byte)Tiff.GetB(raster[i]);
            bytes[i * 4 + 3] = (byte)Tiff.GetA(raster[i]);
        }

        var field = t.GetField(TiffTag.ICCPROFILE);
        var profile = field is { Length: >= 2 } ? field[1].ToByteArray() : null;
        return PixelImage.Orient(w, h, bytes, profile, orientation);
    }
}

public sealed class PixelImage
{
    public int Width { get; }
    public int Height { get; }
    public byte[] RGBA { get; }
    public byte[] ICC { get; }

    static byte[] SrgbProfile()
    {
        using var s = typeof(PixelImage).Assembly.GetManifestResourceStream("ImageAgent.Core.Resources.sRGB.icc")!;
        using var o = new MemoryStream();
        s.CopyTo(o);
        return o.ToArray();
    }

    static byte[] Profile(SKColorSpace s)
    {
        using var p = s.ToProfile();
        if (p.Size > 0)
        {
            var bytes = new byte[p.Size];
            Marshal.Copy(p.Buffer, bytes, 0, bytes.Length);
            return bytes;
        }

        using var bitmap = new SKBitmap(new SKImageInfo(1, 1, SKColorType.Rgba8888, SKAlphaType.Premul, s));
        bitmap.Erase(SKColors.Black);
        using var image = SKImage.FromBitmap(bitmap);
        using var png = image.Encode(SKEncodedImageFormat.Png, 100);
        return PngICC(png.ToArray()) ?? SrgbProfile();
    }

    internal SKColorSpace Space() => SKColorSpace.CreateIcc(ICC) ?? SKColorSpace.CreateSrgb();
    public PixelImage(int width, int height, byte[] rgba, byte[]? icc = null)
    {
        DecodedImage.ValidateDimensions(width, height);
        if (rgba.Length != (long)width * height * 4)
            throw new AgentException("图片像素缓冲无效。");
        Width = width;
        Height = height;
        RGBA = rgba;
        using var space = icc == null || !IsRGBProfile(icc) ? null : SKColorSpace.CreateIcc(icc);
        ICC = space is not null ? icc! : SrgbProfile();
    }

    public static PixelImage Decode(byte[] data)
    {
        if (DecodedImage.IsTiff(data))
        {
            if (data.Length > DecodedImage.MaximumBytes)
                throw new AgentException("图片超过 100MiB。");
            return DecodedImage.TiffPixels(data);
        }

        _ = new DecodedImage(data);
        using var codec = SKCodec.Create(new SKMemoryStream(data));
        var info = codec.Info;
        using var cs = info.ColorSpace ?? SKColorSpace.CreateSrgb();
        using var b = new SKBitmap(new SKImageInfo(info.Width, info.Height, SKColorType.Rgba8888, SKAlphaType.Premul, cs));
        if (codec.GetPixels(b.Info, b.GetPixels()) != SKCodecResult.Success)
            throw new AgentException("无法读取图片像素。");
        var bytes = new byte[info.Width * info.Height * 4];
        Marshal.Copy(b.GetPixels(), bytes, 0, bytes.Length);
        var profile = EmbeddedICC(data) ?? Profile(cs);
        int orientation = (int)codec.EncodedOrigin;
        int w = orientation is >= 5 and <= 8 ? info.Height : info.Width, h = orientation is >= 5 and <= 8 ? info.Width : info.Height;
        if (orientation <= 1 || orientation > 8)
            return new(w, h, bytes, profile);
        var normalized = new byte[bytes.Length];
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                var(sx, sy) = orientation switch
                {
                    2 => (info.Width - 1 - x, y),
                    3 => (info.Width - 1 - x, info.Height - 1 - y),
                    4 => (x, info.Height - 1 - y),
                    5 => (y, x),
                    6 => (y, info.Height - 1 - x),
                    7 => (info.Width - 1 - y, info.Height - 1 - x),
                    8 => (info.Width - 1 - y, x),
                    _ => (x, y)};
                Buffer.BlockCopy(bytes, (sy * info.Width + sx) * 4, normalized, (y * w + x) * 4, 4);
            }

        return new(w, h, normalized, profile);
    }

    internal static PixelImage Orient(int sourceWidth, int sourceHeight, byte[] raw, byte[]? icc, int orientation)
    {
        if (orientation <= 1 || orientation > 8)
            return new(sourceWidth, sourceHeight, raw, icc);
        int w = orientation >= 5 ? sourceHeight : sourceWidth, h = orientation >= 5 ? sourceWidth : sourceHeight;
        var normalized = new byte[raw.Length];
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                var(sx, sy) = orientation switch
                {
                    2 => (sourceWidth - 1 - x, y),
                    3 => (sourceWidth - 1 - x, sourceHeight - 1 - y),
                    4 => (x, sourceHeight - 1 - y),
                    5 => (y, x),
                    6 => (y, sourceHeight - 1 - x),
                    7 => (sourceWidth - 1 - y, sourceHeight - 1 - x),
                    8 => (sourceWidth - 1 - y, x),
                    _ => (x, y)};
                Buffer.BlockCopy(raw, (sy * sourceWidth + sx) * 4, normalized, (y * w + x) * 4, 4);
            }

        return new(w, h, normalized, icc);
    }

    internal SKBitmap Bitmap()
    {
        using var s = Space();
        var b = new SKBitmap(new SKImageInfo(Width, Height, SKColorType.Rgba8888, SKAlphaType.Premul, s));
        Marshal.Copy(RGBA, 0, b.GetPixels(), RGBA.Length);
        return b;
    }

    public byte[] PngData()
    {
        using var b = Bitmap();
        using var i = SKImage.FromBitmap(b);
        using var d = i.Encode(SKEncodedImageFormat.Png, 100);
        return AddICC(d.ToArray(), ICC);
    }

    public PixelImage Crop(PixelRect r)
    {
        if (r.X < 0 || r.Y < 0 || r.Width <= 0 || r.Height <= 0 || r.X + r.Width > Width || r.Y + r.Height > Height)
            throw new AgentException("选区裁图超出图片边界。");
        var a = new byte[r.Width * r.Height * 4];
        for (int y = 0; y < r.Height; y++)
            Buffer.BlockCopy(RGBA, ((r.Y + y) * Width + r.X) * 4, a, y * r.Width * 4, r.Width * 4);
        return new(r.Width, r.Height, a, ICC);
    }

    public PixelImage Resize(int w, int h, byte[] icc)
    {
        if (w == Width && h == Height && icc.AsSpan().SequenceEqual(ICC))
            return this;
        DecodedImage.ValidateDimensions(w, h);
        using var source = Bitmap();
        using var cs = SKColorSpace.CreateIcc(icc) ?? SKColorSpace.CreateSrgb();
        using var destination = new SKBitmap(new SKImageInfo(w, h, SKColorType.Rgba8888, SKAlphaType.Premul, cs));
        using (var canvas = new SKCanvas(destination))
        {
            canvas.Clear(SKColors.Transparent);
            using var image = SKImage.FromBitmap(source);
            canvas.DrawImage(image, new SKRect(0, 0, w, h), new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.Linear), null);
        }

        var a = new byte[w * h * 4];
        Marshal.Copy(destination.GetPixels(), a, 0, a.Length);
        return new(w, h, a, icc);
    }

    static bool IsRGBProfile(byte[] profile) => profile.Length >= 128 && profile.AsSpan(16, 4).SequenceEqual("RGB "u8);
    static byte[]? EmbeddedICC(byte[] bytes)
    {
        var png = PngICC(bytes);
        if (png != null && IsRGBProfile(png))
            return png;
        if (bytes.Length > 4 && bytes[0] == 255 && bytes[1] == 216)
        {
            var parts = new SortedDictionary<int, byte[]>();
            int totalParts = 0, p = 2, totalSize = 0;
            while (p < bytes.Length - 1)
            {
                if (bytes[p++] != 255)
                    break;
                while (p < bytes.Length && bytes[p] == 255)
                    p++;
                if (p >= bytes.Length)
                    break;
                int marker = bytes[p++];
                if (marker is 218 or 217)
                    break;
                if (marker == 1 || marker is >= 208 and <= 215)
                    continue;
                if (p > bytes.Length - 2)
                    break;
                int length = BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(p, 2));
                if (length < 2 || length > bytes.Length - p)
                    break;
                if (marker == 226 && length >= 16 && bytes.AsSpan(p + 2, 12).SequenceEqual("ICC_PROFILE\0"u8))
                {
                    int seq = bytes[p + 14], count = bytes[p + 15];
                    if (seq == 0 || count == 0 || seq > count || totalParts != 0 && totalParts != count || parts.ContainsKey(seq))
                        return null;
                    totalParts = count;
                    var part = bytes.AsSpan(p + 16, length - 16).ToArray();
                    totalSize += part.Length;
                    if (totalSize > 4 * 1024 * 1024)
                        return null;
                    parts.Add(seq, part);
                }

                p += length;
            }

            if (totalParts > 0 && parts.Count == totalParts)
            {
                var profile = parts.Values.SelectMany(v => v).ToArray();
                if (IsRGBProfile(profile))
                    return profile;
            }
        }

        if (bytes.Length >= 12 && bytes.AsSpan(0, 4).SequenceEqual("RIFF"u8) && bytes.AsSpan(8, 4).SequenceEqual("WEBP"u8))
        {
            int p = 12;
            while (p <= bytes.Length - 8)
            {
                uint n = BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(p + 4, 4));
                if (n > bytes.Length - p - 8)
                    break;
                if (bytes.AsSpan(p, 4).SequenceEqual("ICCP"u8) && n <= 4 * 1024 * 1024)
                {
                    var profile = bytes.AsSpan(p + 8, (int)n).ToArray();
                    return IsRGBProfile(profile) ? profile : null;
                }

                p += 8 + (int)n + ((int)n & 1);
            }
        }

        return null;
    }

    static byte[]? PngICC(byte[] bytes)
    {
        if (bytes.Length < 8 || bytes[0] != 137)
            return null;
        int p = 8;
        while (p <= bytes.Length - 12)
        {
            int n = (int)BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(p, 4));
            if (n < 0 || n > bytes.Length - p - 12)
                return null;
            if (bytes.AsSpan(p + 4, 4).SequenceEqual("iCCP"u8))
            {
                var data = bytes.AsSpan(p + 8, n);
                var nul = data.IndexOf((byte)0);
                if (nul < 0 || nul + 2 >= n || data[nul + 1] != 0)
                    return null;
                try
                {
                    using var z = new ZLibStream(new MemoryStream(data[(nul + 2)..].ToArray()), CompressionMode.Decompress);
                    using var o = new MemoryStream();
                    var block = new byte[4096];
                    int count;
                    while ((count = z.Read(block)) > 0)
                    {
                        if (o.Length + count > 4 * 1024 * 1024)
                            return null;
                        o.Write(block, 0, count);
                    }

                    return o.ToArray();
                }
                catch (InvalidDataException)
                {
                    return null;
                }
            }

            p += n + 12;
        }

        return null;
    }

    static byte[] AddICC(byte[] png, byte[] icc)
    {
        using var o = new MemoryStream();
        o.Write(png, 0, 8);
        int p = 8;
        bool added = false;
        while (p <= png.Length - 12)
        {
            int n = (int)BinaryPrimitives.ReadUInt32BigEndian(png.AsSpan(p, 4));
            var type = png.AsSpan(p + 4, 4);
            if (!type.SequenceEqual("iCCP"u8) && !type.SequenceEqual("sRGB"u8))
                o.Write(png, p, n + 12);
            p += n + 12;
            if (!added)
            {
                using var compressed = new MemoryStream();
                using (var z = new ZLibStream(compressed, CompressionLevel.Optimal, true))
                    z.Write(icc);
                using var payload = new MemoryStream();
                payload.Write("ImageAgent\0\0"u8);
                payload.Write(compressed.ToArray());
                WriteChunk(o, "iCCP"u8, payload.ToArray());
                added = true;
            }
        }

        return o.ToArray();
    }

    static void WriteChunk(Stream s, ReadOnlySpan<byte> type, byte[] data)
    {
        Span<byte> n = stackalloc byte[4];
        BinaryPrimitives.WriteInt32BigEndian(n, data.Length);
        s.Write(n);
        s.Write(type);
        s.Write(data);
        uint c = 0xffffffff;
        foreach (var b in type.ToArray().Concat(data))
        {
            c ^= b;
            for (int i = 0; i < 8; i++)
                c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
        }

        BinaryPrimitives.WriteUInt32BigEndian(n, c ^ 0xffffffff);
        s.Write(n);
    }
}
