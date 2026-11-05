using ImageAgent.Core;
using Xunit;

namespace ImageAgent.Tests;
public sealed class ProductionInstanceTests
{
    sealed class Lease(bool owns) : IInstanceLease
    {
        public bool OwnsInstance => owns;

        public bool Disposed;
        public void Dispose() => Disposed = true;
    }

    [Fact]
    public void SecondaryProductionLaunchActivatesWithoutConstructingAnyStore()
    {
        int activations = 0, stores = 0;
        var lease = new Lease(false);
        using var startup = new StartupLease(new("normal", null, null, false), true, () => lease, () => activations++);
        var result = startup.Create(() =>
        {
            stores++;
            return new object ();
        });
        Assert.False(startup.ShouldStart);
        Assert.Null(result);
        Assert.Equal(0, stores);
        Assert.Equal(1, activations);
        Assert.True(lease.Disposed);
    }

    [Theory]
    [InlineData("frontend", null)]
    [InlineData("streaming", null)]
    [InlineData("connection", null)]
    [InlineData("normal", "isolated-self-test")]
    public void OfflineAndSelfTestLaunchesNeverAcquireProductionLease(string mode, string? output)
    {
        using var startup = new StartupLease(new(mode, "isolated", output, false), true, () => throw new Exception("production lock accessed"), () => throw new Exception("activation accessed"));
        Assert.True(startup.ShouldStart);
        Assert.NotNull(startup.Create(() => new object ()));
    }
}

public sealed class NamedMutexTests
{
    [Fact]
    public void IndependentThreadsContendAndReleaseTheSameUniqueLease()
    {
        var name = "ImageAgentTest-" + Guid.NewGuid().ToString("N");
        using var owner = new NamedMutexLease(name);
        Assert.True(owner.OwnsInstance);
        bool? secondOwned = null;
        var contender = new Thread(() =>
        {
            using var second = new NamedMutexLease(name);
            secondOwned = second.OwnsInstance;
        });
        contender.Start();
        Assert.True(contender.Join(TimeSpan.FromSeconds(2)));
        Assert.False(secondOwned);
        owner.Dispose();
        using var next = new NamedMutexLease(name);
        Assert.True(next.OwnsInstance);
    }
}
