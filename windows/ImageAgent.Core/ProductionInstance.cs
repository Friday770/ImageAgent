namespace ImageAgent.Core;
public interface IInstanceLease : IDisposable
{
    bool OwnsInstance { get; }
}

/// Mutex ownership is kept on the bootstrap thread until the desktop lifetime ends.
public sealed class NamedMutexLease : IInstanceLease
{
    readonly Mutex mutex;
    bool disposed;
    public bool OwnsInstance { get; }

    public NamedMutexLease(string name)
    {
        mutex = new Mutex(false, name);
        try
        {
            OwnsInstance = mutex.WaitOne(0);
        }
        catch (AbandonedMutexException)
        {
            OwnsInstance = true;
        }
    }

    public void Dispose()
    {
        if (disposed)
            return;
        disposed = true;
        if (OwnsInstance)
            mutex.ReleaseMutex();
        mutex.Dispose();
    }
}

/// A secondary normal launch cannot execute the supplied store factory.
public sealed class StartupLease : IDisposable
{
    readonly IInstanceLease? lease;
    public bool ShouldStart { get; }

    public StartupLease(LaunchOptions options, bool windows, Func<IInstanceLease> acquire, Action activateExisting)
    {
        if (!windows || options.IsOffline || options.SelfTestOutput != null)
        {
            ShouldStart = true;
            return;
        }

        var candidate = acquire();
        if (candidate.OwnsInstance)
        {
            lease = candidate;
            ShouldStart = true;
        }
        else
        {
            candidate.Dispose();
            ShouldStart = false;
            activateExisting();
        }
    }

    public T? Create<T>(Func<T> factory)
        where T : class => ShouldStart ? factory() : null;
    public void Dispose() => lease?.Dispose();
}
