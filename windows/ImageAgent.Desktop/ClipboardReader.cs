using Avalonia.Input;
using Avalonia.Input.Platform;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using ImageAgent.Core;

namespace ImageAgent.Desktop;
public static class ClipboardReader
{
    public static async Task<bool> Paste(IClipboard clipboard, Func<byte[], bool> import)
    {
        using var data = await clipboard.TryGetDataAsync();
        if (data == null)
            return false;
        var files = await data.TryGetFilesAsync();
        if (files is { Length: > 0 })
        {
            if (files.Length != 1 || data.Items.Count != 1 || files[0] is not IStorageFile file)
                throw new AgentException("请一次只粘贴一张本地图片文件；原草稿与附件已保留。");
            var properties = await file.GetBasicPropertiesAsync();
            if (properties.Size == 0 || properties.Size > DecodedImage.MaximumBytes)
                throw new AgentException("图片文件必须有效且不超过 100MiB。");
            await using var input = await file.OpenReadAsync();
            import(await Read(input));
            return true;
        }

        var formats = data.Formats.Where(f => f == DataFormat.Bitmap || IsImageName(f.Identifier)).ToArray();
        if (formats.Length == 0)
            return false;
        if (data.Items.Count != 1)
            throw new AgentException("请一次只粘贴一张图片；原草稿与附件已保留。");
        foreach (var format in formats.Where(f => f != DataFormat.Bitmap && IsEncodedImageName(f.Identifier)).OrderBy(f => f.Identifier.Contains("png", StringComparison.OrdinalIgnoreCase) ? 0 : 1))
        {
            var raw = await data.Items[0].TryGetRawAsync(format);
            byte[]? bytes = raw switch
            {
                byte[] b => b,
                MemoryStream m => m.ToArray(),
                Stream s => await Read(s),
                _ => null
            };
            if (bytes == null)
                continue;
            import(DecodedImage.ClipboardBytes(bytes));
            return true;
        }

        using var bitmap = await data.TryGetBitmapAsync();
        if (bitmap == null)
            throw new AgentException("剪贴板图片无法读取，请重新复制。");
        DecodedImage.ValidateDimensions(bitmap.PixelSize.Width, bitmap.PixelSize.Height);
        using var output = new MemoryStream();
        bitmap.Save(output, PngBitmapEncoderOptions.Default);
        import(DecodedImage.ClipboardBytes(output.ToArray()));
        return true;
    }

    static bool IsEncodedImageName(string s) => s.Contains("png", StringComparison.OrdinalIgnoreCase) || s.Contains("tiff", StringComparison.OrdinalIgnoreCase) || s.Contains("jpeg", StringComparison.OrdinalIgnoreCase) || s.Contains("webp", StringComparison.OrdinalIgnoreCase);
    static bool IsImageName(string s) => s.Contains("png", StringComparison.OrdinalIgnoreCase) || s.Contains("tiff", StringComparison.OrdinalIgnoreCase) || s.Contains("jpeg", StringComparison.OrdinalIgnoreCase) || s.Contains("webp", StringComparison.OrdinalIgnoreCase) || s.Equals("DIB", StringComparison.OrdinalIgnoreCase) || s.Contains("bitmap", StringComparison.OrdinalIgnoreCase);
    static async Task<byte[]> Read(Stream input)
    {
        using var bytes = new MemoryStream();
        var b = new byte[8192];
        int n;
        while ((n = await input.ReadAsync(b)) > 0)
        {
            if (bytes.Length + n > DecodedImage.MaximumBytes)
                throw new AgentException("图片超过 100MiB；原草稿与附件已保留。");
            bytes.Write(b, 0, n);
        }

        return bytes.ToArray();
    }
}
