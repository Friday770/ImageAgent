using Xunit;

namespace ImageAgent.Tests;
public class BootstrapTests
{
    [Fact]
    public void CoreExposesThePortableSwiftContract()
    {
        var a = typeof(ImageAgent.Core.ServiceEndpoint).Assembly;
        foreach (var name in new[]
        {
            "ServiceEndpoint",
            "SQLiteStore",
            "RegionSelection",
            "ResponsesStreamDecoder",
            "AgentEngine",
            "WorkspaceState"
        }

        )
            Assert.True(a.GetType("ImageAgent.Core." + name)is not null, "Missing portable contract: " + name);
    }
}
