using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

namespace ImageAgent.Core;
public sealed record ServiceEndpoint
{
    public string String { get; }

    public ServiceEndpoint(string input)
    {
        var s = input.Trim();
        if (!Uri.TryCreate(s, UriKind.Absolute, out var u) || u.UserInfo.Length > 0 || u.Query.Length > 0 || u.Fragment.Length > 0 || u.Host.Length == 0 || !(u.Scheme == "https" || u.Scheme == "http" && new[]
        {
            "localhost",
            "127.0.0.1",
            "[::1]",
            "::1"
        }.Contains(u.Host.ToLowerInvariant())))
            throw new AgentException("请输入 HTTPS API 服务地址；仅本机测试允许 HTTP。地址不能含账号、查询参数或片段。");
        var originalPath = Regex.Match(s, @"^[^:]+://[^/]+(?<p>/[^?#]*)?").Groups["p"].Value;
        var p = Uri.UnescapeDataString(originalPath).Trim('/');
        if (p.Contains("//") || p.Contains("v1/v1") || p.Split('/').Any(v => v is "." or ".."))
            throw new AgentException("API 地址包含重复或无效路径。");
        if (p != "v1" && !p.EndsWith("/v1", StringComparison.Ordinal))
            p = p.Length == 0 ? "v1" : p + "/v1";
        var b = new UriBuilder(u)
        {
            Scheme = u.Scheme.ToLowerInvariant(),
            Host = u.Host.ToLowerInvariant(),
            Path = "/" + p
        };
        String = b.Uri.AbsoluteUri.TrimEnd('/');
    }

    public Uri Url(string path) => new(String + "/" + path.Trim('/'));
}

public interface ICredentialStore
{
    string? Key(string endpoint);
    void Save(string key, string endpoint);
    void Delete(string endpoint);
}

public sealed class MemoryCredentials : ICredentialStore
{
    readonly Dictionary<string, string> values = [];
    public string? Key(string endpoint)
    {
        lock (values)
            return values.GetValueOrDefault(endpoint);
    }

    public void Save(string key, string endpoint)
    {
        lock (values)
            values[endpoint] = key;
    }

    public void Delete(string endpoint)
    {
        lock (values)
            values.Remove(endpoint);
    }
}

public sealed class DemoCredentials : ICredentialStore
{
    readonly string file;
    readonly object gate = new();
    public DemoCredentials(string privateRoot)
    {
        file = Path.Combine(privateRoot, "offline-credential-markers.json");
    }

    Dictionary<string, bool> Read() => File.Exists(file) ? SwiftJson.Decode<Dictionary<string, bool>>(File.ReadAllText(file)) : new()
    {
        {
            new AppSettings().Endpoint,
            true
        }
    };
    public string? Key(string endpoint)
    {
        lock (gate)
            return Read().GetValueOrDefault(endpoint) ? "offline-demo-placeholder" : null;
    }

    public void Save(string key, string endpoint)
    {
        lock (gate)
        {
            var m = Read();
            m[endpoint] = true;
            AppPaths.WriteAtomic(file, Encoding.UTF8.GetBytes(SwiftJson.Encode(m)));
        }
    }

    public void Delete(string endpoint)
    {
        lock (gate)
        {
            var m = Read();
            m.Remove(endpoint);
            AppPaths.WriteAtomic(file, Encoding.UTF8.GetBytes(SwiftJson.Encode(m)));
        }
    }
}

public sealed class WindowsCredentials : ICredentialStore
{
    public WindowsCredentials()
    {
        if (!OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException("正常连接仅支持 Windows；其他平台请显式使用离线模式。");
    }

    public static string Target(string endpoint) => "cn.mausy.ImageAgent/" + new ServiceEndpoint(endpoint).String;
    public string? Key(string endpoint)
    {
        if (!CredReadW(Target(endpoint), 1, 0, out var p))
        {
            var e = Marshal.GetLastWin32Error();
            if (e == 1168)
                return null;
            throw Failure(e);
        }

        try
        {
            var c = Marshal.PtrToStructure<Credential>(p);
            var b = new byte[c.CredentialBlobSize];
            Marshal.Copy(c.CredentialBlob, b, 0, b.Length);
            return Encoding.UTF8.GetString(b);
        }
        finally
        {
            CredFree(p);
        }
    }

    public void Save(string key, string endpoint)
    {
        if (string.IsNullOrWhiteSpace(key))
            throw new AgentException("API Key 不能为空。");
        var bytes = Encoding.UTF8.GetBytes(key);
        if (bytes.Length > 2560)
            throw new AgentException("API Key 超出系统凭据容量。");
        var p = Marshal.AllocCoTaskMem(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, p, bytes.Length);
            var c = new Credential
            {
                Type = 1,
                TargetName = Target(endpoint),
                CredentialBlobSize = (uint)bytes.Length,
                CredentialBlob = p,
                Persist = 2,
                UserName = "ImageAgent"
            };
            if (!CredWriteW(ref c, 0))
                throw Failure(Marshal.GetLastWin32Error());
        }
        finally
        {
            Marshal.Copy(new byte[bytes.Length], 0, p, bytes.Length);
            Marshal.FreeCoTaskMem(p);
            Array.Clear(bytes);
        }
    }

    public void Delete(string endpoint)
    {
        if (!CredDeleteW(Target(endpoint), 1, 0) && Marshal.GetLastWin32Error() != 1168)
            throw Failure(Marshal.GetLastWin32Error());
    }

    static AgentException Failure(int e) => new($"无法访问此服务的 Windows 凭据（{e}）。请重新输入 API Key 连接；本地历史仍会保留。");
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct Credential
    {
        public uint Flags, Type;
        public string TargetName;
        public string? Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist, AttributeCount;
        public IntPtr Attributes;
        public string? TargetAlias;
        public string UserName;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredReadW(string target, uint type, uint flags, out IntPtr credential);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredWriteW(ref Credential credential, uint flags);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredDeleteW(string target, uint type, uint flags);
    [DllImport("advapi32.dll")]
    static extern void CredFree(IntPtr credential);
}
