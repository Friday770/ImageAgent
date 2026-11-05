using Microsoft.Win32.SafeHandles;
using System.Buffers.Binary;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Xunit;

namespace ImageAgent.Tests;
/// Real directory links in unique test-owned temporary paths; Windows junctions require no symlink privilege.
internal static class DirectoryLinks
{
    public static void Create(string link, string target)
    {
        link = Path.GetFullPath(link);
        target = Path.GetFullPath(target);
        var temporaryRoot = Path.TrimEndingDirectorySeparator(Path.GetFullPath(Path.GetTempPath())) + Path.DirectorySeparatorChar;
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        if (!link.StartsWith(temporaryRoot, comparison) || !target.StartsWith(temporaryRoot, comparison))
            throw new InvalidOperationException("Directory-link fixtures must stay in test-owned temporary directories.");
        if (Directory.Exists(link) || File.Exists(link) || !Directory.Exists(target))
            throw new IOException("The test link must be new and its temporary target must exist.");
        if (!OperatingSystem.IsWindows())
        {
            Directory.CreateSymbolicLink(link, target);
            return;
        }

        Directory.CreateDirectory(link);
        try
        {
            using var handle = CreateFileW(link, 0x40000000, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
            if (handle.IsInvalid)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot open the temporary junction directory.");
            var buffer = JunctionData(target);
            if (!DeviceIoControl(handle, 0x000900A4, buffer, (uint)buffer.Length, IntPtr.Zero, 0, out _, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot create the temporary NTFS junction.");
            if ((File.GetAttributes(link) & FileAttributes.ReparsePoint) == 0)
                throw new IOException("The test fixture did not create a real Windows reparse point.");
        }
        catch
        {
            if (Directory.Exists(link))
                Directory.Delete(link);
            throw;
        }
    }

    internal static byte[] JunctionData(string target)
    {
        var substitute = Encoding.Unicode.GetBytes(target.StartsWith(@"\\", StringComparison.Ordinal) ? @"\??\UNC\" + target[2..] : @"\??\" + target);
        var print = Encoding.Unicode.GetBytes(target);
        var buffer = new byte[16 + substitute.Length + 2 + print.Length + 2];
        if (buffer.Length > 16 * 1024)
            throw new ArgumentException("The junction path exceeds the reparse-buffer limit.", nameof(target));
        BinaryPrimitives.WriteUInt32LittleEndian(buffer.AsSpan(0, 4), 0xA0000003);
        BinaryPrimitives.WriteUInt16LittleEndian(buffer.AsSpan(4, 2), checked((ushort)(buffer.Length - 8)));
        BinaryPrimitives.WriteUInt16LittleEndian(buffer.AsSpan(8, 2), 0);
        BinaryPrimitives.WriteUInt16LittleEndian(buffer.AsSpan(10, 2), checked((ushort)substitute.Length));
        BinaryPrimitives.WriteUInt16LittleEndian(buffer.AsSpan(12, 2), checked((ushort)(substitute.Length + 2)));
        BinaryPrimitives.WriteUInt16LittleEndian(buffer.AsSpan(14, 2), checked((ushort)print.Length));
        substitute.CopyTo(buffer, 16);
        print.CopyTo(buffer, 16 + substitute.Length + 2);
        return buffer;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
    static extern SafeFileHandle CreateFileW(string fileName, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(SafeFileHandle handle, uint code, byte[] input, uint inputLength, IntPtr output, uint outputLength, out uint bytesReturned, IntPtr overlapped);
}

public sealed class DirectoryLinkFixtureTests
{
    [Fact]
    public void JunctionBufferUsesTheWindowsMountPointWireFormatWithoutCommandQuoting()
    {
        const string target = @"C:\ImageAgent & 测试\owned";
        var data = DirectoryLinks.JunctionData(target);
        Assert.Equal(0xA0000003u, BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan(0, 4)));
        Assert.Equal(data.Length - 8, BinaryPrimitives.ReadUInt16LittleEndian(data.AsSpan(4, 2)));
        int substituteOffset = BinaryPrimitives.ReadUInt16LittleEndian(data.AsSpan(8, 2));
        int substituteLength = BinaryPrimitives.ReadUInt16LittleEndian(data.AsSpan(10, 2));
        int printOffset = BinaryPrimitives.ReadUInt16LittleEndian(data.AsSpan(12, 2));
        int printLength = BinaryPrimitives.ReadUInt16LittleEndian(data.AsSpan(14, 2));
        Assert.Equal(@"\??\" + target, Encoding.Unicode.GetString(data, 16 + substituteOffset, substituteLength));
        Assert.Equal(target, Encoding.Unicode.GetString(data, 16 + printOffset, printLength));
        Assert.Equal(substituteLength + 2, printOffset);
    }
}
