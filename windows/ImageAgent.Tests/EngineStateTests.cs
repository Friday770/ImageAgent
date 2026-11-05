using ImageAgent.Core;
using System.Text;
using System.Text.Json;
using Xunit;

namespace ImageAgent.Tests;
public sealed class FakeTransport : IHTTPTransport
{
    public int Models, Responses, Generations, Edits, Downloads;
    public bool FailModels, Truncate, Native, FailAfterJSON;
    public byte[][]? NativeImages;
    public Action? OnImage;
    public string? ForcedPlan;
    public readonly List<HttpRequestMessage> Requests = [];
    public readonly List<string> Bodies = [];
    public Func<Task>? WaitModels;
    public Func<Task>? BeforeStream;
    public async Task<HTTPResponse> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        Requests.Add(request);
        Bodies.Add(request.Content == null ? "" : await request.Content.ReadAsStringAsync(ct));
        var path = request.RequestUri!.AbsolutePath;
        if (path.EndsWith("/models", StringComparison.Ordinal))
        {
            Models++;
            if (WaitModels != null)
                await WaitModels();
            return new(Encoding.UTF8.GetBytes(FailModels ? "{\"error\":{\"message\":\"bad key\"}}" : "{\"data\":[{\"id\":\"gpt-6.1-sol\"},{\"id\":\"custom\"},{\"id\":\"gpt-image-2\"}]}"), FailModels ? 401 : 200);
        }

        if (path.EndsWith("/generations", StringComparison.Ordinal))
            Generations++;
        else if (path.EndsWith("/edits", StringComparison.Ordinal))
            Edits++;
        else
            Downloads++;
        OnImage?.Invoke();
        return new(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { data = new[] { new { b64_json = Convert.ToBase64String(Fixture.PNG) } } })), 200);
    }

    public async Task StreamAsync(HttpRequestMessage request, Action<HTTPStreamEvent> receive, CancellationToken ct)
    {
        Responses++;
        Requests.Add(request);
        if (BeforeStream != null)
            await BeforeStream();
        var raw = await request.Content!.ReadAsStringAsync(ct);
        Bodies.Add(raw);
        var body = SwiftJson.Parse(raw);
        var props = body.Get("tools").Array()[0].Get("parameters").Get("properties");
        var s = new ImageSelection
        {
            Model = props.Get("model").Get("enum").Array()[0].GetString()!,
            Size = props.Get("size").Get("enum").Array()[0].GetString()!,
            Quality = props.Get("quality").Get("enum").Array()[0].GetString()!
        };
        receive(new(200, "text/event-stream"));
        if (Native)
        {
            var data = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { status = "completed", output = (NativeImages ?? new[] { Fixture.PNG }).Select((png, i) => new { type = "image_generation_call", id = "native-" + i, result = Convert.ToBase64String(png) }) }));
            receive(new(Bytes: data));
            if (FailAfterJSON)
                throw new IOException("lost after body");
            return;
        }

        var args = ForcedPlan ?? Fixture.Plan(s);
        receive(new(Bytes: Fixture.Event("response.output_item.added", new { output_index = 0, item = Fixture.Call("") })));
        foreach (var segment in args.Chunk(12))
        {
            ct.ThrowIfCancellationRequested();
            receive(new(Bytes: Fixture.Event("response.function_call_arguments.delta", new { output_index = 0, item_id = "item", delta = new string (segment) })));
        }

        if (!Truncate)
            receive(new(Bytes: Fixture.Event("response.completed", new { response = SwiftJson.Parse(Fixture.Completed(args)) })));
    }
}

public class EngineStateTests
{
    [Fact]
    public async Task GenerateUsesOneStrictPlannerOneImageAndLocalFinalization()
    {
        using var p = new PrivateStore();
        var t = new FakeTransport();
        var c = p.Store.CreateConversation();
        var api = new APIClient("https://offline.invalid", "synthetic-key", transport: t);
        var previews = new List<string>();
        var o = await new AgentEngine(p.Store, api).Submit(new(c.ID, "  原话\n", new()), planningPreview: v => previews.Add(v.Text), ct: TestContext.Current.CancellationToken);
        Assert.Equal(RunStage.Completed, o.Run.Stage);
        Assert.Equal(1, t.Responses);
        Assert.Equal(1, t.Generations);
        Assert.Equal(Fixture.PNG, File.ReadAllBytes(p.Store.AssetPath(o.Assets.Single())));
        Assert.Equal("  原话\n", p.Store.Messages(c.ID)[0].Text);
        Assert.NotEmpty(previews);
        var body = SwiftJson.Parse(t.Bodies[0]);
        Assert.False(body.GetProperty("store").GetBoolean());
        Assert.True(body.GetProperty("stream").GetBoolean());
        Assert.False(body.GetProperty("parallel_tool_calls").GetBoolean());
        Assert.Equal(4096, body.GetProperty("max_output_tokens").GetInt32());
        Assert.Single(body.Get("tools").Array());
    }

    [Fact]
    public async Task TruncatedPlanNeverCallsImageOrStoresPreview()
    {
        using var p = new PrivateStore();
        var t = new FakeTransport
        {
            Truncate = true
        };
        var c = p.Store.CreateConversation();
        var o = await new AgentEngine(p.Store, new("https://offline.invalid", "fake", transport: t)).Submit(new(c.ID, "test", new()), ct: TestContext.Current.CancellationToken);
        Assert.Equal(RunStage.Failed, o.Run.Stage);
        Assert.Null(o.Run.DetailedPrompt);
        Assert.Equal(0, t.Generations + t.Edits);
        Assert.All(p.Store.Messages(c.ID), m => Assert.Null(m.DetailedPrompt));
    }

    [Theory]
    [InlineData("gpt-image-2.5")]
    [InlineData("extra")]
    public async Task StrictPlanRejectsChangedModelOrExtraField(string mutation)
    {
        using var p = new PrivateStore();
        var c = p.Store.CreateConversation();
        var args = Fixture.Plan();
        args = mutation == "extra" ? args[..^1] + ",\"extra\":1}" : args.Replace("gpt-image-2", "gpt-image-2.5", StringComparison.Ordinal);
        var t = new FakeTransport
        {
            ForcedPlan = args
        };
        var o = await new AgentEngine(p.Store, new("https://offline.invalid", "fake", transport: t)).Submit(new(c.ID, "test", new()), ct: TestContext.Current.CancellationToken);
        Assert.Equal(RunStage.Failed, o.Run.Stage);
        Assert.Equal(0, t.Generations + t.Edits);
    }

    [Fact]
    public async Task ReplyDoesNotCreateAnImageOrDetailedPrompt()
    {
        using var p = new PrivateStore();
        var c = p.Store.CreateConversation();
        var t = new FakeTransport
        {
            ForcedPlan = Fixture.Plan(action: "reply", prompt: "", reply: "讨论完成")
        };
        var o = await new AgentEngine(p.Store, new("https://offline.invalid", "fake", transport: t)).Submit(new(c.ID, "讨论", new()), ct: TestContext.Current.CancellationToken);
        Assert.Equal(RunStage.Completed, o.Run.Stage);
        Assert.Empty(o.Assets);
        Assert.Equal("讨论完成", o.Message.Text);
        Assert.Null(o.Message.DetailedPrompt);
        Assert.Equal(0, t.Generations + t.Edits);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task UnexpectedNativeBytesRecoverWithoutAnotherImageRequest(bool transportFailure)
    {
        using var p = new PrivateStore();
        var c = p.Store.CreateConversation();
        var t = new FakeTransport
        {
            Native = true,
            FailAfterJSON = transportFailure
        };
        var o = await new AgentEngine(p.Store, new("https://offline.invalid", "fake", transport: t)).Submit(new(c.ID, "test", new()), ct: TestContext.Current.CancellationToken);
        Assert.Equal(RunStage.Failed, o.Run.Stage);
        Assert.False(o.Assets.Single().ModelVerified);
        Assert.Equal(Fixture.PNG, File.ReadAllBytes(p.Store.RecoveryPath(o.Run)!));
        Assert.Equal(0, t.Generations + t.Edits);
    }

    [Fact]
    public async Task CancellationAfterKnownImageRetainsItAndCaptionFailureRetainsIt()
    {
        using var p = new PrivateStore();
        var c = p.Store.CreateConversation();
        using var cancel = new CancellationTokenSource();
        var t = new FakeTransport
        {
            OnImage = () => cancel.Cancel()
        };
        var o = await new AgentEngine(p.Store, new("https://offline.invalid", "fake", transport: t)).Submit(new(c.ID, "test", new()), ct: cancel.Token);
        Assert.Equal(RunStage.Cancelled, o.Run.Stage);
        Assert.Single(o.Assets);
        Assert.True(File.Exists(p.Store.RecoveryPath(o.Run)));
        var final = await new AgentEngine(p.Store, new("https://offline.invalid", "fake", transport: new FakeTransport()), finalizer: new BrokenFinalizer()).Submit(new(c.ID, "test", new()), ct: TestContext.Current.CancellationToken);
        Assert.Equal(RunStage.Failed, final.Run.Stage);
        Assert.Single(final.Assets);
        Assert.Single(final.Message.AssetIDs);
    }

    sealed class BrokenFinalizer : IImageReplyFinalizer
    {
        public string Finalize(IReadOnlyList<AssetRecord> a, string c) => throw new IOException("caption failure");
    }

    [Fact]
    public async Task RegionForcesAutoMaskAndFixedTargetWithoutMutatingGenerationSelection()
    {
        using var p = new PrivateStore();
        var c = p.Store.CreateConversation();
        var source = p.Store.SaveImage(Fixture.PNG, c.ID, AssetSource.Imported);
        var selection = new RegionSelection(source.Width, source.Height);
        selection.AddRectangle(new(20, 12), new(38, 28));
        var chosen = new ImageSelection
        {
            Size = "1536x1024",
            Model = "gpt-image-2.5-flare",
            Quality = "high"
        };
        var t = new FakeTransport
        {
            ForcedPlan = Fixture.Plan(chosen with { Size = "auto" }, "edit", source.ID)
        };
        var o = await new AgentEngine(p.Store, new("https://offline.invalid", "fake", transport: t)).Submit(new(c.ID, "only selection", chosen, source.ID, new(source.ID, selection)), ct: TestContext.Current.CancellationToken);
        Assert.Equal(RunStage.Completed, o.Run.Stage);
        Assert.Equal("1536x1024", chosen.Size);
        Assert.Equal(0, t.Generations);
        Assert.Equal(1, t.Edits);
        var form = t.Bodies.Last();
        Assert.Contains("mask", form);
        Assert.Contains("auto", form);
        var before = PixelImage.Decode(Fixture.PNG);
        var after = PixelImage.Decode(File.ReadAllBytes(p.Store.AssetPath(o.Assets.Single())));
        var coverage = selection.Coverage();
        for (int i = 0; i < coverage.Length; i++)
            if (coverage[i] == 0)
                Assert.Equal(before.RGBA.AsSpan(i * 4, 4).ToArray(), after.RGBA.AsSpan(i * 4, 4).ToArray());
    }

    [Fact]
    public async Task ReturnedImageRegistrationFailureRetainsRawBytesWithoutAnOrphanAssetOrRetry()
    {
        using var data = new PrivateStore();
        var conversation = data.Store.CreateConversation();
        var transport = new FakeTransport();
        data.Store.BeforeWrite = stage =>
        {
            if (stage == "asset")
                throw new IOException("asset registration fault");
        };
        var outcome = await new AgentEngine(data.Store, new("https://offline.invalid", "synthetic-test", transport: transport)).Submit(new(conversation.ID, "generate a test image", new()), ct: TestContext.Current.CancellationToken);
        Assert.Equal(RunStage.Failed, outcome.Run.Stage);
        Assert.Empty(outcome.Assets);
        Assert.Empty(data.Store.Assets(conversation.ID));
        Assert.Empty(Directory.EnumerateFiles(data.Store.Paths.Assets, "*", SearchOption.AllDirectories));
        Assert.Equal(Fixture.PNG, File.ReadAllBytes(data.Store.RecoveryPath(outcome.Run)!));
        Assert.Equal(1, transport.Responses);
        Assert.Equal(1, transport.Generations);
        Assert.Equal(0, transport.Edits);
    }

    [Fact]
    public async Task ConnectionFailureCompensatesCandidateCredentialAndPreservesSettings()
    {
        using var p = new PrivateStore();
        var keys = new MemoryCredentials();
        var t = new FakeTransport();
        var app = new WorkspaceState(p.Store, keys, t);
        Assert.True(await app.SaveConnection("https://first.invalid", "first-key", "planner-a", ct: TestContext.Current.CancellationToken));
        p.Store.BeforeWrite = stage =>
        {
            if (stage == "settings")
                throw new IOException("disk");
        };
        Assert.False(await app.SaveConnection("https://second.invalid", "second-key", "planner-b", ct: TestContext.Current.CancellationToken));
        Assert.True(app.HasConnection);
        Assert.Equal("https://first.invalid/v1", app.Settings.Endpoint);
        Assert.Null(keys.Key("https://second.invalid/v1"));
        Assert.Equal("first-key", keys.Key("https://first.invalid/v1"));
    }

    [Fact]
    public async Task ConnectionSaveUsesLatestUnrelatedSettings()
    {
        using var p = new PrivateStore();
        var t = new FakeTransport();
        var gate = new TaskCompletionSource();
        t.WaitModels = () => gate.Task;
        var app = new WorkspaceState(p.Store, new MemoryCredentials(), t);
        var save = app.SaveConnection("https://offline.invalid", "fake", "manual-planner", ct: TestContext.Current.CancellationToken);
        app.SetSelection(new() { Model = "gpt-image-2.5-sunburst" });
        gate.SetResult();
        Assert.True(await save);
        Assert.Equal("gpt-image-2.5-sunburst", app.Settings.Selection.Model);
        Assert.Equal("manual-planner", p.Store.Settings().PlannerModel);
    }

    [Fact]
    public void ComposerDraftAndReferenceAreConversationBound()
    {
        using var p = new PrivateStore();
        var app = new WorkspaceState(p.Store, new MemoryCredentials(), new FakeTransport());
        app.NewConversation();
        var first = app.SelectedID;
        app.Draft = "保留文字";
        Assert.True(app.ImportReference(Fixture.PNG));
        var reference = app.ReferenceID;
        Assert.False(app.ImportReference(Fixture.PNG));
        Assert.Equal("保留文字", app.Draft);
        app.NewConversation();
        Assert.Equal("", app.Draft);
        Assert.Null(app.ReferenceID);
        app.Select(first);
        Assert.Equal("保留文字", app.Draft);
        Assert.Equal(reference, app.ReferenceID);
    }

    [Fact]
    public void CancelledReturnIsExactSourceBoundConflictProtectedAndKeepsHistory()
    {
        using var p = new PrivateStore();
        var c = p.Store.CreateConversation();
        var r = new RunRecord
        {
            ConversationID = c.ID,
            Stage = RunStage.Cancelled,
            Request = "text"
        };
        p.Store.SaveRun(r);
        var m = new MessageRecord
        {
            ConversationID = c.ID,
            Role = MessageRole.User,
            RunID = r.ID,
            Text = "  text\n"
        };
        p.Store.AddMessage(m);
        var app = new WorkspaceState(p.Store, new MemoryCredentials(), new FakeTransport());
        app.Draft = "other";
        Assert.False(app.ReturnToEdit(m));
        Assert.Equal("other", app.Draft);
        app.Draft = "";
        Assert.True(app.ReturnToEdit(m));
        Assert.Equal(m.Text, app.Draft);
        Assert.Single(p.Store.Messages(c.ID));
        r.Stage = RunStage.Failed;
        p.Store.SaveRun(r);
        Assert.False(app.CanReturnToEdit(m));
    }

    [Fact]
    public void EditorSessionGuardsAndErasePresetDoNotBroadenSelection()
    {
        using var p = new PrivateStore();
        var c = p.Store.CreateConversation();
        var a = p.Store.SaveImage(Fixture.PNG, c.ID, AssetSource.Imported);
        var app = new WorkspaceState(p.Store, new MemoryCredentials(), new FakeTransport());
        app.OpenWorkspace(a);
        var old = app.Workspace!;
        app.OpenWorkspace(a);
        app.CloseWorkspace(old.ID);
        Assert.NotNull(app.Workspace);
        var s = new RegionSelection(a.Width, a.Height);
        s.AddRectangle(new(2, 2), new(9, 9));
        app.RetainEditorDraft(old.Target, new(s, "stale"), old.ID);
        Assert.Null(app.GetEditorDraft(old.Target));
        app.RetainEditorDraft(app.Workspace!.Target, new(s, "valid"), app.Workspace.ID);
        app.CloseWorkspace();
        Assert.Equal("valid", app.GetEditorDraft(old.Target)!.Prompt);
    }

    [Fact]
    public async Task SettingsDraftNeverLeaksSavedKeyAcrossEndpointChanges()
    {
        using var p = new PrivateStore();
        var keys = new MemoryCredentials();
        keys.Save("first-key", new AppSettings().Endpoint);
        var app = new WorkspaceState(p.Store, keys, new FakeTransport());
        var d = new ConnectionDraft(app);
        await d.LoadKey();
        Assert.Equal("first-key", d.Key);
        d.Revealed = true;
        d.Address = "https://other.invalid";
        Assert.Equal("", d.Key);
        Assert.False(d.Revealed);
        d.Value = "manually-typed-model";
        await d.Refresh();
        Assert.Equal("manually-typed-model", d.Value);
        d.Close();
        Assert.Equal("", d.Key);
        Assert.Empty(d.Options);
    }

    [Fact]
    public async Task PersistedRegionAcceptanceReturnsToSourceConversation()
    {
        using var p = new PrivateStore();
        var source = p.Store.CreateConversation();
        var a = p.Store.SaveImage(Fixture.PNG, source.ID, AssetSource.Imported);
        var t = new FakeTransport
        {
            ForcedPlan = Fixture.Plan(new ImageSelection { Size = "auto" }, "edit", a.ID)
        };
        var app = new WorkspaceState(p.Store, new MemoryCredentials(), t);
        Assert.True(await app.SaveConnection("https://offline.invalid", "fake", "custom-planner", ct: TestContext.Current.CancellationToken));
        app.NewConversation();
        Assert.NotEqual(source.ID, app.SelectedID);
        app.OpenWorkspace(a);
        var session = app.Workspace!;
        var selection = new RegionSelection(a.Width, a.Height);
        selection.AddRectangle(new(10, 10), new(20, 20));
        var outcome = await app.SubmitRegion(session.ID, new(selection, "only this region"));
        Assert.Equal(RunStage.Completed, outcome!.Run.Stage);
        Assert.Null(app.Workspace);
        Assert.Equal(source.ID, app.SelectedID);
    }

    [Fact]
    public async Task MutableCallerSelectionCannotChangeAcceptedRegionHistory()
    {
        using var p = new PrivateStore();
        var c = p.Store.CreateConversation();
        var a = p.Store.SaveImage(Fixture.PNG, c.ID, AssetSource.Imported);
        var selection = new RegionSelection(a.Width, a.Height);
        selection.AddRectangle(new(1, 1), new(6, 6));
        var expected = SwiftJson.Encode(selection);
        var gate = new TaskCompletionSource();
        var t = new FakeTransport
        {
            ForcedPlan = Fixture.Plan(new ImageSelection { Size = "auto" }, "edit", a.ID),
            BeforeStream = () => gate.Task
        };
        var pending = new AgentEngine(p.Store, new("https://offline.invalid", "fake", transport: t)).Submit(new(c.ID, "region", new(), a.ID, new(a.ID, selection)), ct: TestContext.Current.CancellationToken);
        selection.Clear();
        selection.AddRectangle(new(0, 0), new(a.Width, a.Height));
        gate.SetResult();
        var outcome = await pending;
        Assert.Equal(expected, SwiftJson.Encode(outcome.Run.RegionEdit!.Selection));
        Assert.Equal(expected, SwiftJson.Encode(p.Store.Run(outcome.Run.ID)!.RegionEdit!.Selection));
    }

    [Fact]
    public async Task AllKnownNativeBytesAreDurableBeforeMetadataFailure()
    {
        using var p = new PrivateStore();
        var c = p.Store.CreateConversation();
        var image = PixelImage.Decode(Fixture.PNG);
        var second = image.Resize(23, 25, image.ICC).PngData();
        var t = new FakeTransport
        {
            Native = true,
            NativeImages = [Fixture.PNG, second]
        };
        bool fault = true;
        p.Store.BeforeWrite = stage =>
        {
            if (stage == "recoveryMetadata" && fault)
            {
                fault = false;
                throw new IOException("metadata fault");
            }
        };
        var outcome = await new AgentEngine(p.Store, new("https://offline.invalid", "fake", transport: t)).Submit(new(c.ID, "test", new()), ct: TestContext.Current.CancellationToken);
        Assert.Equal(RunStage.Failed, outcome.Run.Stage);
        var directory = Path.Combine(p.Root, "recovery", outcome.Run.ID);
        Assert.Equal(Fixture.PNG, File.ReadAllBytes(Path.Combine(directory, "native-1.png")));
        Assert.True(File.Exists(Path.Combine(directory, "native-2.png")), "Second native response must be durable before metadata writes");
        Assert.Equal(second, File.ReadAllBytes(Path.Combine(directory, "native-2.png")));
        Assert.Equal(0, t.Generations + t.Edits);
    }

    [Fact]
    public void CommentActionReturnsToAssetSourceAndPreservesOtherDraft()
    {
        using var p = new PrivateStore();
        var c = p.Store.CreateConversation();
        var a = p.Store.SaveImage(Fixture.PNG, c.ID, AssetSource.Imported);
        var app = new WorkspaceState(p.Store, new MemoryCredentials(), new FakeTransport());
        app.NewConversation();
        var other = app.SelectedID;
        app.Draft = "preserve other";
        app.OpenWorkspace(a);
        Assert.True(app.UseReference(a));
        Assert.Equal(c.ID, app.SelectedID);
        Assert.Equal(a.ID, app.ReferenceID);
        app.CloseWorkspace();
        app.Select(other);
        Assert.Equal("preserve other", app.Draft);
        Assert.Null(app.ReferenceID);
    }

    [Fact]
    public void OfflineBootstrapRejectsUnsafeSessionsAndNormalMacBeforeCreatingStore()
    {
        Assert.Throws<AgentException>(() => LaunchOptions.Parse(new[] { "--frontend-demo", "--frontend-demo-session", "../escape" }, Path.GetTempPath()));
        var options = LaunchOptions.Parse(new[] { "--frontend-demo", "--frontend-demo-session", "qa_42" }, Path.GetTempPath());
        Assert.EndsWith("ImageAgentWindowsDemo-qa_42", options.DataRoot());
        if (!OperatingSystem.IsWindows())
            Assert.Throws<PlatformNotSupportedException>(() => new LaunchOptions("normal", null, null, false).DataRoot());
    }

    [WindowsOnlyFact]
    public void SyntheticWindowsCredentialRoundtripNeverReadsExistingTargets()
    {
        var keys = new WindowsCredentials();
        var endpoint = "https://imageagent-test-" + Guid.NewGuid().ToString("N") + ".invalid/v1";
        var key = Guid.NewGuid().ToString();
        try
        {
            Assert.Null(keys.Key(endpoint));
            keys.Save(key, endpoint);
            Assert.Equal(key, keys.Key(endpoint));
        }
        finally
        {
            keys.Delete(endpoint);
        }

        Assert.Null(keys.Key(endpoint));
    }
}

public sealed class WindowsOnlyFactAttribute : FactAttribute
{
    public WindowsOnlyFactAttribute([System.Runtime.CompilerServices.CallerFilePath] string sourceFilePath = "", [System.Runtime.CompilerServices.CallerLineNumber] int sourceLineNumber = 0) : base(sourceFilePath, sourceLineNumber)
    {
        if (!OperatingSystem.IsWindows())
            Skip = "Windows 实机未执行；仅使用唯一合成 target。";
    }
}
