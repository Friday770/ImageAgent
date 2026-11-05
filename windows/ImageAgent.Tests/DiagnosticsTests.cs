using ImageAgent.Core;
using System.Text;
using System.Text.Json;
using Xunit;

namespace ImageAgent.Tests;
public sealed class DiagnosticsTests
{
    static string Output(PrivateStore root) => Path.Combine(root.Root, "diagnostics");
    static string? FakeEnvironment(string name) => name switch
    {
        "OPENAI_BASE_URL" => "https://offline.invalid",
        "OPENAI_API_KEY" => "synthetic-diagnostic-secret",
        _ => null
    };
    static string[] Arguments(PrivateStore root, params string[] mode) => ["--output", Output(root), ..mode];
    [Theory]
    [InlineData("local")]
    [InlineData("--local")]
    [InlineData("--streaming")]
    [InlineData("--region")]
    public async Task OfflineModesWriteReportsWithoutReadingEnvironmentOrUsingLiveHTTP(string mode)
    {
        using var data = new PrivateStore();
        var fake = new FakeTransport();
        var args = Arguments(data, mode == "local" ? [] : [mode]);
        var report = await new DiagnosticRunner(args, fake, _ => throw new Exception("offline read environment")).Run(TestContext.Current.CancellationToken);
        Assert.Equal("passed", report.Status);
        Assert.NotEmpty(report.Events);
        Assert.True(File.Exists(Path.Combine(Output(data), "report.json")));
        Assert.Equal(0, fake.Models + fake.Responses + fake.Generations + fake.Edits);
        using var reopened = new SQLiteStore(new(Path.Combine(Output(data), "data")));
        Assert.NotEmpty(reopened.Conversations());
        if (mode == "--streaming")
        {
            var runs = reopened.Conversations().SelectMany(c => reopened.Runs(c.ID)).ToArray();
            Assert.Contains(runs, r => r.Stage == RunStage.Completed && r.DetailedPrompt != null);
            Assert.Contains(runs, r => r.Stage == RunStage.Failed && r.DetailedPrompt == null);
        }

        if (mode == "--region")
        {
            Assert.True(File.Exists(Path.Combine(Output(data), "region-crop.png")));
            Assert.True(File.Exists(Path.Combine(Output(data), "region-mask.png")));
            var again = await new DiagnosticRunner(args, fake, _ => throw new Exception("offline read environment")).Run(TestContext.Current.CancellationToken);
            Assert.Contains(again.Events, e => e.Name == "region" && e.Status == "retained");
        }
    }

    [Fact]
    public async Task SavedNativeResponseRecoveryIsUnverifiedByteExactAndIdempotent()
    {
        using var data = new PrivateStore();
        var file = Path.Combine(data.Root, "response.json");
        File.WriteAllText(file, JsonSerializer.Serialize(new { status = "failed", output = new[] { new { type = "image_generation_call", id = "native", result = Convert.ToBase64String(Fixture.PNG) } } }));
        var args = Arguments(data, "--recover-response", file, "--model", "gpt-image-2.5");
        var report = await new DiagnosticRunner(args, environment: _ => throw new Exception("offline read environment")).Run(TestContext.Current.CancellationToken);
        Assert.Equal("recovered-unverified", report.Status);
        using (var s = new SQLiteStore(new(Path.Combine(Output(data), "data"))))
        {
            var c = Assert.Single(s.Conversations());
            var a = Assert.Single(s.Assets(c.ID));
            Assert.False(a.ModelVerified);
            Assert.Equal("gpt-image-2.5", a.Model);
            Assert.Equal(Fixture.PNG, File.ReadAllBytes(s.AssetPath(a)));
            Assert.True(File.Exists(s.RecoveryPath(Assert.Single(s.Runs(c.ID)))));
        }

        var again = await new DiagnosticRunner(args, environment: _ => throw new Exception("offline read environment")).Run(TestContext.Current.CancellationToken);
        Assert.Contains(again.Events, e => e.Status == "retained-unverified");
        using var reopened = new SQLiteStore(new(Path.Combine(Output(data), "data")));
        Assert.Single(reopened.Assets(reopened.Conversations()[0].ID));
    }

    [Fact]
    public async Task ExplicitLiveGenerationUsesOnlyInjectedEnvironmentAndNeverReplaysAnExistingResult()
    {
        using var data = new PrivateStore();
        var fake = new OfflineTransport
        {
            Slow = false
        };
        var cleared = new List<string>();
        var args = Arguments(data, "--live-generate", "--model", "gpt-image-2.5-flare", "--size", "1024x1536", "--quality", "high", "--prompt", "hide synthetic-diagnostic-secret");
        var report = await new DiagnosticRunner(args, fake, FakeEnvironment, cleared.Add).Run(TestContext.Current.CancellationToken);
        Assert.Equal("passed", report.Status);
        Assert.Equal(1, fake.ResponseCalls);
        Assert.Equal(1, fake.ImageCalls);
        Assert.Equal(1, fake.ModelCalls);
        Assert.Equal(new[] { "OPENAI_BASE_URL", "OPENAI_API_KEY" }, cleared);
        using (var s = new SQLiteStore(new(Path.Combine(Output(data), "data"))))
        {
            var c = s.Conversations()[0];
            var r = Assert.Single(s.Runs(c.ID));
            Assert.Equal("gpt-image-2.5-flare", r.Selection.Model);
            Assert.Equal("1024x1536", r.Selection.Size);
            Assert.Equal("high", r.Selection.Quality);
        }

        var again = await new DiagnosticRunner(args, fake, _ => throw new Exception("retained attempt read environment")).Run(TestContext.Current.CancellationToken);
        Assert.Contains(again.Events, e => e.Status == "retained");
        Assert.Equal(1, fake.ResponseCalls);
        Assert.Equal(1, fake.ImageCalls);
        Assert.Equal(1, fake.ModelCalls);
        foreach (var file in Directory.EnumerateFiles(Output(data), "*", SearchOption.AllDirectories))
            Assert.True(File.ReadAllBytes(file).AsSpan().IndexOf(Encoding.UTF8.GetBytes("synthetic-diagnostic-secret")) < 0);
    }

    [Fact]
    public async Task FailedLiveAttemptIsNeverReplannedOrReplayed()
    {
        using var data = new PrivateStore();
        var fake = new FakeTransport
        {
            Truncate = true
        };
        var args = Arguments(data, "--live-generate");
        await Assert.ThrowsAsync<AgentException>(() => new DiagnosticRunner(args, fake, FakeEnvironment, _ =>
        {
        }).Run(TestContext.Current.CancellationToken));
        Assert.Equal(1, fake.Responses);
        Assert.Equal(0, fake.Generations);
        await Assert.ThrowsAsync<AgentException>(() => new DiagnosticRunner(args, fake, _ => throw new Exception("old attempt read environment")).Run(TestContext.Current.CancellationToken));
        Assert.Equal(1, fake.Responses);
        Assert.Equal(0, fake.Generations);
    }

    [Fact]
    public async Task ExplicitLiveRegionUsesExactMaskFixedReferenceAndOriginalOutsideBytes()
    {
        using var data = new PrivateStore();
        var fake = new OfflineTransport
        {
            Slow = false
        };
        var args = Arguments(data, "--live-region", "--reference", Path.Combine(Fixture.Root, "reference.png"), "--region-rect", "5,7,20,15", "--model", "gpt-image-2.5-sunburst", "--quality", "medium");
        var report = await new DiagnosticRunner(args, fake, FakeEnvironment, _ =>
        {
        }).Run(TestContext.Current.CancellationToken);
        Assert.Equal("passed", report.Status);
        Assert.Equal(1, fake.ResponseCalls);
        Assert.Equal(1, fake.ImageCalls);
        Assert.Contains(report.Events, e => e.Name == "live-region-preservation" && e.Detail.Contains("outside pixels exactly equal", StringComparison.Ordinal));
        using var s = new SQLiteStore(new(Path.Combine(Output(data), "data")));
        var c = s.Conversations()[0];
        var run = Assert.Single(s.Runs(c.ID));
        Assert.Equal("auto", run.Selection.Size);
        Assert.NotNull(run.RegionEdit);
        Assert.Equal("gpt-image-2.5-sunburst", run.Selection.Model);
    }

    [Fact]
    public async Task ContradictoryModesFailBeforeReadingAnyCredentials()
    {
        using var data = new PrivateStore();
        await Assert.ThrowsAsync<AgentException>(() => new DiagnosticRunner(Arguments(data, "--streaming", "--live-region"), environment: _ => throw new Exception("invalid mode read environment")).Run(TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task ExplicitLiveEditPinsSavedReferenceAndDoesNotReplay()
    {
        using var data = new PrivateStore();
        var fake = new OfflineTransport
        {
            Slow = false
        };
        var args = Arguments(data, "--live-edit", "--reference", Path.Combine(Fixture.Root, "reference.png"), "--edit-prompt", "only edit this reference");
        var report = await new DiagnosticRunner(args, fake, FakeEnvironment, _ =>
        {
        }).Run(TestContext.Current.CancellationToken);
        Assert.Equal("passed", report.Status);
        Assert.Equal(1, fake.ResponseCalls);
        Assert.Equal(1, fake.ImageCalls);
        using (var s = new SQLiteStore(new(Path.Combine(Output(data), "data"))))
        {
            var c = s.Conversations()[0];
            var assets = s.Assets(c.ID);
            var original = Assert.Single(assets, a => a.Source == AssetSource.Imported);
            var edited = Assert.Single(assets, a => a.Source == AssetSource.Edited);
            Assert.Equal(original.ID, edited.ParentAssetID);
        }

        var again = await new DiagnosticRunner(args, fake, _ => throw new Exception("retained edit read environment")).Run(TestContext.Current.CancellationToken);
        Assert.Contains(again.Events, e => e.Name == "live-edit" && e.Status == "retained");
        Assert.Equal(1, fake.ResponseCalls);
        Assert.Equal(1, fake.ImageCalls);
    }
}
