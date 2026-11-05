using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Headless.XUnit;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using Avalonia.VisualTree;
using ImageAgent.Core;
using ImageAgent.Desktop;
using System.Text;
using Xunit;
namespace ImageAgent.Tests;

public sealed class ReviewFixTests
{
    static async Task Pump()
    {
        await Task.Yield();
        Dispatcher.UIThread.RunJobs();
    }

    [AvaloniaFact]
    public async Task ExportToOriginalSourceKeepsItsBytesAndUsesAtomicLocalWriting()
    {
        using var data = new PrivateStore();
        var conversation = data.Store.CreateConversation();
        var asset = data.Store.SaveImage(Fixture.PNG, conversation.ID, AssetSource.Imported);
        var source = data.Store.AssetPath(asset);
        IStorageFile? destination = null;
        var state = new WorkspaceState(data.Store, new MemoryCredentials(), new FakeTransport());
        int pickerCalls = 0;
        var window = new MainWindow(state, new("frontend", "export-source", null, false), settings =>
        {
            pickerCalls++;
            Assert.Equal("保存图片副本", settings.Title);
            return Task.FromResult(destination);
        });
        try
        {
            destination = await window.StorageProvider.TryGetFileFromPathAsync(new Uri(source));
            Assert.NotNull(destination);
            string? failure = null;
            await window.Export(asset, message => failure = message);
            Assert.Null(failure);
            Assert.Equal(1, pickerCalls);
            Assert.Equal(Fixture.PNG, File.ReadAllBytes(source));
            Assert.Single(data.Store.Assets(conversation.ID));
        }
        finally { window.Close(); }
    }

    [AvaloniaFact]
    public async Task ExportOrdinaryLocalCopyIsByteExactAndPreservesTheSource()
    {
        using var data = new PrivateStore();
        var conversation = data.Store.CreateConversation();
        var asset = data.Store.SaveImage(Fixture.PNG, conversation.ID, AssetSource.Imported);
        var target = Path.Combine(data.Root, "copy.png");
        File.WriteAllBytes(target, Fixture.PNG.Concat(new byte[200]).ToArray());
        if (!OperatingSystem.IsWindows())
            File.SetUnixFileMode(target, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.GroupRead | UnixFileMode.OtherRead);
        IStorageFile? destination = null;
        var state = new WorkspaceState(data.Store, new MemoryCredentials(), new FakeTransport());
        var window = new MainWindow(state, new("frontend", "export-copy", null, false), _ => Task.FromResult(destination));
        try
        {
            destination = await window.StorageProvider.TryGetFileFromPathAsync(new Uri(target));
            Assert.NotNull(destination);
            string? failure = null;
            await window.Export(asset, message => failure = message);
            Assert.Null(failure);
            Assert.Equal(Fixture.PNG, File.ReadAllBytes(target));
            Assert.Equal(Fixture.PNG, File.ReadAllBytes(data.Store.AssetPath(asset)));
            if (!OperatingSystem.IsWindows())
                Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(target));
        }
        finally { window.Close(); }
    }

    [AvaloniaFact]
    public async Task RetainedEditorDraftBecomesSubmittableWhenTheHeldBackgroundTaskFinishes()
    {
        using var data = new PrivateStore();
        var transport = new FakeTransport();
        var state = new WorkspaceState(data.Store, new MemoryCredentials(), transport, a => Dispatcher.UIThread.Post(a));
        Assert.True(await state.SaveConnection("https://offline.invalid", "synthetic-key", "custom-planner", ct: TestContext.Current.CancellationToken));
        var asset = data.Store.SaveImage(Fixture.PNG, state.SelectedID!, AssetSource.Imported);
        Assert.True(state.OpenWorkspace(asset));
        var retained = state.Workspace!;
        var selection = new RegionSelection(asset.Width, asset.Height);
        selection.AddRectangle(new(4, 5), new(14, 15));
        state.RetainEditorDraft(retained.Target, new(selection, "保留的修改要求", EditorTool.Rectangle), retained.ID);
        state.CloseWorkspace(retained.ID);
        state.NewConversation();
        state.Draft = "a held task in another conversation";
        var gate = new TaskCompletionSource();
        transport.BeforeStream = () => gate.Task;
        var pending = state.Send();
        Assert.True(state.IsBusy);
        Assert.True(state.OpenWorkspace(asset));
        var session = state.Workspace!;
        var window = new MainWindow(state, new("frontend", "editor-held", null, false));
        window.Show();
        try
        {
            await Pump();
            var editor = Assert.Single(window.GetVisualDescendants().OfType<EditorOverlay>());
            var submit = Assert.Single(editor.GetVisualDescendants().OfType<Button>(), b => b.Content as string == "↑");
            var prompt = Assert.Single(editor.GetVisualDescendants().OfType<TextBox>());
            Assert.Equal("保留的修改要求", prompt.Text);
            Assert.False(submit.IsEnabled);
            gate.SetResult();
            var outcome = await pending;
            await Pump();
            Assert.Equal(RunStage.Completed, outcome!.Run.Stage);
            Assert.False(state.IsBusy);
            Assert.Same(editor, Assert.Single(window.GetVisualDescendants().OfType<EditorOverlay>()));
            Assert.Equal(session.ID, state.Workspace!.ID);
            Assert.Equal("保留的修改要求", prompt.Text);
            Assert.Equal(SwiftJson.Encode(selection), SwiftJson.Encode(state.GetEditorDraft(session.Target)!.Selection));
            Assert.True(submit.IsEnabled);
        }
        finally
        {
            gate.TrySetResult();
            await pending;
            window.Close();
        }
    }

    static string Endpoint(string encoding)
    {
        const string key = "configured-endpoint-secret-42";
        var part = encoding switch
        {
            "encoded" => string.Concat(Encoding.UTF8.GetBytes(key).Select(b => $"%{b:X2}")),
            "double-encoded" => string.Concat(Encoding.UTF8.GetBytes(key).Select(b => $"%25{b:X2}")),
            _ => key
        };
        return "https://candidate.invalid/prefix/" + part;
    }

    [Theory]
    [InlineData("raw")]
    [InlineData("encoded")]
    [InlineData("double-encoded")]
    public void APIClientRejectsAKeyBearingEndpointBeforeAnyNetwork(string encoding)
    {
        const string key = "configured-endpoint-secret-42";
        var transport = new FakeTransport();
        var error = Assert.Throws<AgentException>(() => new APIClient(Endpoint(encoding), key, transport: transport));
        Assert.Equal("API 地址不能包含 API 凭据。", error.Message);
        Assert.DoesNotContain(key, error.Message);
        Assert.Empty(transport.Requests);
    }

    [Theory]
    [InlineData("raw")]
    [InlineData("encoded")]
    [InlineData("double-encoded")]
    public async Task SaveConnectionRejectsAKeyBearingEndpointAndKeepsPriorSettingsWithoutPersistence(string encoding)
    {
        const string key = "configured-endpoint-secret-42";
        using var data = new PrivateStore();
        var transport = new FakeTransport();
        var credentials = new MemoryCredentials();
        var state = new WorkspaceState(data.Store, credentials, transport);
        Assert.True(await state.SaveConnection("https://prior.invalid", "old-synthetic-key", "old-planner", ct: TestContext.Current.CancellationToken));
        var prior = state.Settings;
        int requests = transport.Requests.Count;
        Assert.False(await state.SaveConnection(Endpoint(encoding), key, "new-planner", ct: TestContext.Current.CancellationToken));
        Assert.Equal(requests, transport.Requests.Count);
        Assert.True(state.HasConnection);
        Assert.Equal(prior, state.Settings);
        Assert.Equal(prior, data.Store.Settings());
        Assert.Equal("old-synthetic-key", credentials.Key(prior.Endpoint));
        Assert.Null(credentials.Key(new ServiceEndpoint(Endpoint(encoding)).String));
        Assert.Equal("API 地址不能包含 API 凭据。", state.ConnectionError);
        Assert.DoesNotContain(key, state.Error ?? "");
        foreach (var file in Directory.EnumerateFiles(data.Root, "*", SearchOption.AllDirectories))
            Assert.True(File.ReadAllBytes(file).AsSpan().IndexOf(Encoding.UTF8.GetBytes(key)) < 0, "The rejected key must not enter persisted records.");
    }
}
