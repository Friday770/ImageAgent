using Avalonia.Controls;
using Avalonia.Threading;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;

namespace ImageAgent.Desktop;
/// Only normal Windows bootstrap uses this current-user IPC endpoint.
internal sealed class WindowsActivation : IDisposable
{
    readonly string pipeName;
    readonly CancellationTokenSource stop = new();
    readonly Task listener;
    Window? window;
    bool pending;
    public static string UserIdentity()
    {
        if (!OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException();
        using var identity = WindowsIdentity.GetCurrent();
        var sid = identity.User?.Value ?? Environment.UserDomainName + "\\" + Environment.UserName;
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(sid)));
    }

    // LocalAppData is user-wide, including other logon sessions: a user-wide mutex protects the shared DB.
    public static string MutexName(string identity) => "Global\\ImageAgent." + identity;
    public static string PipeName(string identity) => "ImageAgent.Activate." + identity;
    public WindowsActivation(string identity)
    {
        if (!OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException();
        pipeName = PipeName(identity);
        listener = Task.Run(Listen);
    }

    public void Bind(Window target)
    {
        window = target;
        target.Opened += (_, _) =>
        {
            if (pending)
                Activate();
        };
        if (pending && target.IsVisible)
            Activate();
    }

    void Activate()
    {
        if (window is not { IsVisible: true })
        {
            pending = true;
            return;
        }

        pending = false;
        if (window.WindowState == WindowState.Minimized)
            window.WindowState = WindowState.Normal;
        window.Activate();
        var handle = window.TryGetPlatformHandle()?.Handle ?? IntPtr.Zero;
        if (handle != IntPtr.Zero)
            _ = SetForegroundWindow(handle);
    }

    async Task Listen()
    {
        while (!stop.IsCancellationRequested)
        {
            try
            {
                using var server = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await server.WaitForConnectionAsync(stop.Token).ConfigureAwait(false);
                await server.WriteAsync(BitConverter.GetBytes(Environment.ProcessId), stop.Token).ConfigureAwait(false);
                await server.FlushAsync(stop.Token).ConfigureAwait(false);
                var signal = new byte[1];
                if (await server.ReadAsync(signal, stop.Token).ConfigureAwait(false) == 1 && signal[0] == 1)
                    Dispatcher.UIThread.Post(Activate);
            }
            catch (OperationCanceledException)when (stop.IsCancellationRequested)
            {
                break;
            }
            catch (IOException)
            {
                if (stop.IsCancellationRequested)
                    break;
            }
            catch (UnauthorizedAccessException)
            {
                break;
            }
        }
    }

    public static void SignalExisting(string identity)
    {
        if (!OperatingSystem.IsWindows())
            return;
        try
        {
            using var client = new NamedPipeClientStream(".", PipeName(identity), PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            client.ConnectAsync(timeout.Token).GetAwaiter().GetResult();
            var pid = new byte[4];
            client.ReadExactlyAsync(pid, timeout.Token).GetAwaiter().GetResult();
            _ = AllowSetForegroundWindow((uint)BitConverter.ToInt32(pid));
            client.Write(new byte[] { 1 });
            client.Flush();
        }
        catch (IOException)
        {
        }
        catch (OperationCanceledException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    public void Dispose()
    {
        stop.Cancel();
        try
        {
            listener.GetAwaiter().GetResult();
        }
        catch (OperationCanceledException)
        {
        }

        stop.Dispose();
    }

    [DllImport("user32.dll")]
    static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")]
    static extern bool AllowSetForegroundWindow(uint processID);
}
