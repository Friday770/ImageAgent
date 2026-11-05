using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Presenters;
using Avalonia.Headless;
using Avalonia.Headless.XUnit;
using Avalonia.Input;
using Avalonia.Input.Platform;
using Avalonia.Themes.Fluent;
using Avalonia.VisualTree;
using ImageAgent.Core;
using ImageAgent.Desktop;
using Xunit;

[assembly: AvaloniaTestApplication(typeof(ImageAgent.Tests.HeadlessBuilder))]
namespace ImageAgent.Tests;
public static class HeadlessBuilder
{
    public static AppBuilder BuildAvaloniaApp() => AppBuilder.Configure<HeadlessApp>().UseHeadless(new AvaloniaHeadlessPlatformOptions());
}

public sealed class HeadlessApp : Application
{
    public override void Initialize() => Styles.Add(new FluentTheme());
}

public sealed class DesktopContractTests
{
    static TextBox Composer(MainWindow window) => window.GetVisualDescendants().OfType<TextBox>().Single(c => AutomationProperties.GetName(c) == "创作需求输入框");
    static async Task Pump()
    {
        await Task.Yield();
        Avalonia.Threading.Dispatcher.UIThread.RunJobs();
    }

    [AvaloniaFact]
    public async Task RegionalCtrlEnterDoesNotSubmitDuringPreeditAndSubmitsAfterCompositionEnds()
    {
        using var data = new PrivateStore();
        var transport = new FakeTransport();
        var state = new WorkspaceState(data.Store, new MemoryCredentials(), transport);
        Assert.True(await state.SaveConnection("https://offline.invalid", "synthetic-test", "custom-planner", ct: TestContext.Current.CancellationToken));
        var asset = data.Store.SaveImage(Fixture.PNG, state.SelectedID!, AssetSource.Imported);
        transport.ForcedPlan = Fixture.Plan(new ImageSelection { Size = "auto" }, "edit", asset.ID);
        Assert.True(state.OpenWorkspace(asset));
        var session = state.Workspace!;
        var selection = new RegionSelection(asset.Width, asset.Height);
        selection.AddRectangle(new(5, 5), new(15, 15));
        state.RetainEditorDraft(session.Target, new(selection, "已输入的修改要求", EditorTool.Rectangle), session.ID);
        var owner = new MainWindow(state, new LaunchOptions("frontend", "headless", null, false));
        owner.Show();
        try
        {
            await Pump();
            var overlay = Assert.Single(owner.GetVisualDescendants().OfType<EditorOverlay>());
            var prompt = Assert.Single(overlay.GetVisualDescendants().OfType<TextBox>());
            var presenter = Assert.Single(prompt.GetVisualDescendants().OfType<TextPresenter>());
            var routing = new List<string>();
            prompt.AddHandler(InputElement.KeyDownEvent, (_, e) => routing.Add($"{e.Route}: handled={e.Handled}; preedit={presenter.PreeditText}; enabled={prompt.IsEnabled}; focused={prompt.IsFocused}"), Avalonia.Interactivity.RoutingStrategies.Tunnel | Avalonia.Interactivity.RoutingStrategies.Bubble, handledEventsToo: true);
            Assert.True(Assert.Single(overlay.GetVisualDescendants().OfType<Button>(), b => b.Content as string == "↑").IsEnabled);
            prompt.Focus();
            presenter.SetCurrentValue(TextPresenter.PreeditTextProperty, "尚未提交的中文组合");
            owner.KeyPress(Key.Enter, RawInputModifiers.Control, PhysicalKey.Enter, "\r");
            owner.KeyRelease(Key.Enter, RawInputModifiers.Control, PhysicalKey.Enter, "\r");
            await Pump();
            Assert.Equal(0, transport.Responses);
            Assert.Equal(0, transport.Edits);
            Assert.Empty(data.Store.Runs(asset.ConversationID));
            Assert.Equal(session.ID, state.Workspace?.ID);
            presenter.SetCurrentValue(TextPresenter.PreeditTextProperty, null);
            owner.KeyPress(Key.Enter, RawInputModifiers.Control, PhysicalKey.Enter, "\r");
            owner.KeyRelease(Key.Enter, RawInputModifiers.Control, PhysicalKey.Enter, "\r");
            await Pump();
            Assert.True(transport.Responses == 1, $"Expected one planner request; received {transport.Responses}. Routes: {string.Join(" | ", routing)}");
            Assert.Equal(1, transport.Edits);
            Assert.Equal(RunStage.Completed, Assert.Single(data.Store.Runs(asset.ConversationID)).Stage);
            Assert.Null(state.Workspace);
        }
        finally
        {
            owner.Close();
        }
    }

    [AvaloniaFact]
    public async Task CanvasMouseRectangleAndReleasedPenUseOrientedSourcePixelsAtBothDPIScales()
    {
        foreach (double dpi in new[]
        {
            1.0,
            2.0
        }

        )
        {
            var image = PixelImage.Decode(Fixture.PNG);
            var selection = new RegionSelection(image.Width, image.Height);
            using var canvas = new RegionCanvas(image, selection)
            {
                Tool = EditorTool.Rectangle
            };
            var owner = new Window
            {
                Width = 500,
                Height = 380,
                Content = canvas
            };
            owner.Show();
            try
            {
                owner.SetRenderScaling(dpi);
                await Pump();
                canvas.Actual();
                await Pump();
                Point WindowPoint(double x, double y, double scale = 1, double panX = 0, double panY = 0)
                {
                    var point = new Point((canvas.Bounds.Width - image.Width * scale) / 2 + panX + x * scale, (canvas.Bounds.Height - image.Height * scale) / 2 + panY + y * scale);
                    return canvas.TranslatePoint(point, owner)!.Value;
                }

                owner.MouseDown(WindowPoint(10.2, 8.7), MouseButton.Left, RawInputModifiers.None);
                owner.MouseMove(WindowPoint(40.4, 30.6), RawInputModifiers.LeftMouseButton);
                owner.MouseUp(WindowPoint(40.4, 30.6), MouseButton.Left, RawInputModifiers.None);
                await Pump();
                var rectangle = Assert.Single(selection.Marks);
                Assert.Equal("rectangle", rectangle.Kind);
                Assert.Equal(10.2, rectangle.Points[0].X, 6);
                Assert.Equal(8.7, rectangle.Points[0].Y, 6);
                Assert.Equal(40.4, rectangle.Points[1].X, 6);
                Assert.Equal(30.6, rectangle.Points[1].Y, 6);
                selection.Clear();
                canvas.Tool = EditorTool.Pen;
                canvas.CancelGesture();
                var contour = new[]
                {
                    new ImagePoint(60.5, 10.5),
                    new ImagePoint(80.5, 10.5),
                    new ImagePoint(80.5, 35.5),
                    new ImagePoint(60.5, 35.5)
                };
                owner.MouseDown(WindowPoint(contour[0].X, contour[0].Y), MouseButton.Left, RawInputModifiers.None);
                foreach (var point in contour.Skip(1))
                    owner.MouseMove(WindowPoint(point.X, point.Y), RawInputModifiers.LeftMouseButton);
                owner.MouseUp(WindowPoint(contour[^1].X, contour[^1].Y), MouseButton.Left, RawInputModifiers.None);
                await Pump();
                var pen = Assert.Single(selection.Marks);
                Assert.Equal("pen", pen.Kind);
                Assert.Equal(4, pen.Points.Length);
                Assert.Equal(255, selection.Coverage()[20 * image.Width + 70]);
                Assert.Equal(0, selection.Coverage()[20 * image.Width + 58]);
            }
            finally
            {
                owner.Close();
            }
        }
    }

    [AvaloniaFact]
    public async Task CanvasMouseCoordinatesRemainSourceBoundAfterZoomAndPan()
    {
        var image = PixelImage.Decode(Fixture.PNG);
        var selection = new RegionSelection(image.Width, image.Height);
        using var canvas = new RegionCanvas(image, selection)
        {
            Tool = EditorTool.Pan
        };
        var owner = new Window
        {
            Width = 500,
            Height = 380,
            Content = canvas
        };
        owner.Show();
        try
        {
            owner.SetRenderScaling(2);
            await Pump();
            canvas.Actual();
            canvas.ChangeZoom(2);
            await Pump();
            var center = canvas.TranslatePoint(new Point(canvas.Bounds.Width / 2, canvas.Bounds.Height / 2), owner)!.Value;
            owner.MouseDown(center, MouseButton.Left, RawInputModifiers.None);
            owner.MouseMove(center + new Vector(35, -20), RawInputModifiers.LeftMouseButton);
            owner.MouseUp(center + new Vector(35, -20), MouseButton.Left, RawInputModifiers.None);
            await Pump();
            canvas.Tool = EditorTool.Rectangle;
            canvas.CancelGesture();
            Point WindowPoint(double x, double y) => canvas.TranslatePoint(new Point((canvas.Bounds.Width - image.Width * 2) / 2 + 35 + x * 2, (canvas.Bounds.Height - image.Height * 2) / 2 - 20 + y * 2), owner)!.Value;
            owner.MouseDown(WindowPoint(5.25, 6.5), MouseButton.Left, RawInputModifiers.None);
            owner.MouseMove(WindowPoint(22.75, 24.5), RawInputModifiers.LeftMouseButton);
            owner.MouseUp(WindowPoint(22.75, 24.5), MouseButton.Left, RawInputModifiers.None);
            await Pump();
            var mark = Assert.Single(selection.Marks);
            Assert.Equal(5.25, mark.Points[0].X, 6);
            Assert.Equal(6.5, mark.Points[0].Y, 6);
            Assert.Equal(22.75, mark.Points[1].X, 6);
            Assert.Equal(24.5, mark.Points[1].Y, 6);
            Assert.Equal(255, selection.Coverage()[10 * image.Width + 10]);
            Assert.Equal(0, selection.Coverage()[10 * image.Width + 24]);
        }
        finally
        {
            owner.Close();
        }
    }

    [AvaloniaFact]
    public async Task CurrentConnectionLabelChangesOnlyAfterSuccessfulEndpointSave()
    {
        using var data = new PrivateStore();
        var fake = new FakeTransport();
        var state = new WorkspaceState(data.Store, new MemoryCredentials(), fake);
        Assert.True(await state.SaveConnection("https://first.invalid", "first-synthetic-key", "custom-planner", ct: TestContext.Current.CancellationToken));
        var owner = new MainWindow(state, new LaunchOptions("frontend", "headless", null, false));
        owner.Show();
        var dialog = new SettingsWindow(owner, state);
        dialog.Show(owner);
        try
        {
            for (int i = 0; i < 20; i++)
            {
                await Task.Delay(10, TestContext.Current.CancellationToken);
                await Pump();
            }

            var address = Assert.Single(dialog.GetVisualDescendants().OfType<TextBox>(), c => AutomationProperties.GetName(c) == "API URL");
            var key = Assert.Single(dialog.GetVisualDescendants().OfType<TextBox>(), c => AutomationProperties.GetName(c) == "API Key");
            var label = Assert.Single(dialog.GetVisualDescendants().OfType<SelectableTextBlock>(), t => t.Text?.StartsWith("当前连接：", StringComparison.Ordinal) == true);
            var save = Assert.Single(dialog.GetVisualDescendants().OfType<Button>(), c => c.Content as string == "验证并保存");
            Assert.Equal("当前连接：https://first.invalid/v1", label.Text);
            address.Text = "https://second.invalid";
            await Pump();
            key.Text = "second-synthetic-key";
            await Pump();
            Assert.Equal("当前连接：https://first.invalid/v1", label.Text);
            save.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
            for (int i = 0; i < 20; i++)
            {
                await Task.Delay(10, TestContext.Current.CancellationToken);
                await Pump();
            }

            Assert.Equal("https://second.invalid/v1", state.Settings.Endpoint);
            Assert.Equal("当前连接：https://second.invalid/v1", label.Text);
            fake.FailModels = true;
            address.Text = "https://failed.invalid";
            await Pump();
            key.Text = "failed-synthetic-key";
            await Pump();
            save.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
            for (int i = 0; i < 20; i++)
            {
                await Task.Delay(10, TestContext.Current.CancellationToken);
                await Pump();
            }

            Assert.Equal("当前连接：https://second.invalid/v1", label.Text);
            var cancel = Assert.Single(dialog.GetVisualDescendants().OfType<Button>(), c => c.Content as string == "取消编辑");
            cancel.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
            for (int i = 0; i < 20; i++)
            {
                await Task.Delay(10, TestContext.Current.CancellationToken);
                await Pump();
            }

            Assert.Equal("当前连接：https://second.invalid/v1", label.Text);
            Assert.Equal(state.Settings.Endpoint, address.Text);
        }
        finally
        {
            dialog.Close();
            owner.Close();
        }
    }

    [AvaloniaFact]
    public async Task WindowsSettingsShortcutAndChineseSelectionLabelsKeepRawRequestValues()
    {
        using var data = new PrivateStore();
        var state = new WorkspaceState(data.Store, new MemoryCredentials(), new FakeTransport());
        Assert.True(await state.SaveConnection("https://offline.invalid", "synthetic-test", "custom-planner", ct: TestContext.Current.CancellationToken));
        state.SetSelection(new ImageSelection { Size = "auto", Quality = "low" });
        var asset = data.Store.SaveImage(Fixture.PNG, state.SelectedID!, AssetSource.Imported);
        var owner = new MainWindow(state, new LaunchOptions("frontend", "headless", null, false));
        owner.Show();
        try
        {
            await Pump();
            Assert.Contains(owner.GetVisualDescendants().OfType<TextBlock>(), t => t.Text == "自动尺寸");
            Assert.Contains(owner.GetVisualDescendants().OfType<TextBlock>(), t => t.Text == "低质量");
            Assert.Equal("auto", state.Settings.Selection.Size);
            Assert.Equal("low", state.Settings.Selection.Quality);
            owner.KeyPress(Key.OemComma, Avalonia.Input.RawInputModifiers.Control, PhysicalKey.Comma, ",");
            await Pump();
            var settings = Assert.Single(owner.OwnedWindows.OfType<SettingsWindow>());
            settings.Close();
            await Pump();
            state.OpenWorkspace(asset);
            await Pump();
            owner.KeyPress(Key.OemComma, Avalonia.Input.RawInputModifiers.Control, PhysicalKey.Comma, ",");
            await Pump();
            Assert.Empty(owner.OwnedWindows.OfType<SettingsWindow>());
        }
        finally
        {
            foreach (var child in owner.OwnedWindows.ToArray())
                child.Close();
            owner.Close();
        }
    }

    [AvaloniaFact]
    public async Task SettingsLoadsMaskedSavedKeyDiscoversModelsAndResetsAfterAddressEdit()
    {
        using var data = new PrivateStore();
        var keys = new MemoryCredentials();
        var transport = new FakeTransport();
        var state = new WorkspaceState(data.Store, keys, transport);
        Assert.True(await state.SaveConnection("https://offline.invalid", "synthetic-saved-value", "custom-planner", ct: TestContext.Current.CancellationToken));
        var owner = new MainWindow(state, new LaunchOptions("frontend", "headless", null, false));
        owner.Show();
        var dialog = new SettingsWindow(owner, state);
        dialog.Show(owner);
        try
        {
            for (int i = 0; i < 30; i++)
            {
                await Task.Delay(10, TestContext.Current.CancellationToken);
                await Pump();
            }

            var key = Assert.Single(dialog.GetVisualDescendants().OfType<TextBox>(), c => AutomationProperties.GetName(c) == "API Key");
            var address = Assert.Single(dialog.GetVisualDescendants().OfType<TextBox>(), c => AutomationProperties.GetName(c) == "API URL");
            var planner = Assert.Single(dialog.GetVisualDescendants().OfType<AutoCompleteBox>());
            Assert.Equal("synthetic-saved-value", key.Text);
            Assert.Equal('●', key.PasswordChar);
            Assert.Contains("custom", planner.ItemsSource!.Cast<string>());
            Assert.DoesNotContain("gpt-image-2", planner.ItemsSource!.Cast<string>());
            var dropdown = Assert.Single(dialog.GetVisualDescendants().OfType<Button>(), c => AutomationProperties.GetName(c) == "选择规划模型");
            Assert.True(dropdown.IsEnabled);
            Assert.Equal(AutoCompleteFilterMode.None, planner.FilterMode);
            var beforeChoice = planner.Text;
            dropdown.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
            await Pump();
            Assert.True(planner.IsDropDownOpen);
            Assert.Equal(beforeChoice, planner.Text);
            Assert.Contains("custom", planner.ItemsSource!.Cast<string>());
            planner.IsDropDownOpen = false;
            var reveal = Assert.Single(dialog.GetVisualDescendants().OfType<Button>(), c => AutomationProperties.GetName(c) == "显示或隐藏 API Key");
            Assert.True(reveal.IsEnabled);
            address.Text = "https://another.invalid";
            await Pump();
            Assert.True(string.IsNullOrEmpty(key.Text));
            Assert.Equal('●', key.PasswordChar);
            var cancelEdit = Assert.Single(dialog.GetVisualDescendants().OfType<Button>(), c => c.Content as string == "取消编辑");
            cancelEdit.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
            for (int i = 0; i < 20; i++)
            {
                await Task.Delay(10, TestContext.Current.CancellationToken);
                await Pump();
            }

            Assert.Equal(state.Settings.Endpoint, address.Text);
            Assert.Equal("synthetic-saved-value", key.Text);
            Assert.Equal('●', key.PasswordChar);
            planner.Text = "custom";
            var save = Assert.Single(dialog.GetVisualDescendants().OfType<Button>(), c => c.Content as string == "验证并保存");
            var validation = new TaskCompletionSource();
            transport.WaitModels = () => validation.Task;
            save.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
            await Pump();
            Assert.True(state.IsConnecting);
            Assert.False(dropdown.IsEnabled);
            Assert.False(planner.IsEnabled);
            validation.SetResult();
            transport.WaitModels = null;
            for (int i = 0; i < 20; i++)
            {
                await Task.Delay(10, TestContext.Current.CancellationToken);
                await Pump();
            }

            Assert.Equal("custom", state.Settings.PlannerModel);
            Assert.Equal("synthetic-saved-value", key.Text);
            Assert.Equal('●', key.PasswordChar);
            dialog.Close();
            var reopened = new SettingsWindow(owner, state);
            reopened.Show(owner);
            try
            {
                for (int i = 0; i < 20; i++)
                {
                    await Task.Delay(10, TestContext.Current.CancellationToken);
                    await Pump();
                }

                var reopenedKey = Assert.Single(reopened.GetVisualDescendants().OfType<TextBox>(), c => AutomationProperties.GetName(c) == "API Key");
                Assert.Equal("synthetic-saved-value", reopenedKey.Text);
                Assert.Equal('●', reopenedKey.PasswordChar);
                var reopenedPlanner = Assert.Single(reopened.GetVisualDescendants().OfType<AutoCompleteBox>());
                Assert.Equal("custom", reopenedPlanner.Text);
                Assert.Contains("custom", reopenedPlanner.ItemsSource!.Cast<string>());
            }
            finally
            {
                reopened.Close();
            }
        }
        finally
        {
            dialog.Close();
            owner.Close();
        }
    }

    [AvaloniaFact]
    public async Task PlainAvaloniaPasteHasOneUndoStep()
    {
        var input = new TextBox
        {
            IsUndoEnabled = true
        };
        var window = new Window
        {
            Content = input
        };
        window.Show();
        try
        {
            input.Text = "original";
            input.CaretIndex = 8;
            input.Focus();
            await window.Clipboard!.SetValueAsync(DataFormat.Text, "paste");
            input.Paste();
            await Pump();
            Assert.Equal("originalpaste", input.Text);
            input.Undo();
            await Pump();
            Assert.Equal("original", input.Text);
        }
        finally
        {
            window.Close();
        }
    }

    [AvaloniaFact]
    public async Task NativeTextPasteUndoAndEncodedImagePastePreserveTextAndOneAttachment()
    {
        using var data = new PrivateStore();
        var state = new WorkspaceState(data.Store, new MemoryCredentials(), new FakeTransport());
        Assert.True(await state.SaveConnection("https://offline.invalid", "synthetic-test", "custom-planner", ct: TestContext.Current.CancellationToken));
        var window = new MainWindow(state, new LaunchOptions("frontend", "headless", null, false));
        window.Show();
        try
        {
            var input = Composer(window);
            input.Text = "原草稿";
            input.CaretIndex = input.Text.Length;
            input.Focus();
            await window.Clipboard!.SetValueAsync(DataFormat.Text, "粘贴文字");
            input.Paste();
            await Pump();
            Assert.Equal("原草稿粘贴文字", input.Text);
            await window.Clipboard!.SetValueAsync(DataFormat.Text, "第二次");
            input.Paste();
            await Pump();
            Assert.Equal("原草稿粘贴文字第二次", input.Text);
            input.Undo();
            await Pump();
            Assert.Equal("原草稿粘贴文字", input.Text);
            Assert.True(input.IsUndoEnabled, "Composer must enable native undo");
            Assert.True(input.CanUndo, "Native paste must create an undo step");
            input.Undo();
            await Pump();
            Assert.Equal("原草稿", input.Text);
            await window.Clipboard!.SetValueAsync(DataFormat.CreateBytesPlatformFormat("PNG"), Fixture.PNG);
            input.Paste();
            await Pump();
            Assert.Equal("原草稿", input.Text);
            Assert.NotNull(state.ReferenceID);
            Assert.Single(state.Assets);
            Assert.Empty(state.Messages);
            var reference = state.ReferenceID;
            input.Paste();
            await Pump();
            Assert.Equal(reference, state.ReferenceID);
            Assert.Equal("原草稿", input.Text);
            Assert.Single(state.Assets);
        }
        finally
        {
            window.Close();
        }
    }

    [AvaloniaFact]
    public async Task SameWindowOverlayHidesBackgroundAndSessionCloseRestoresTheComposer()
    {
        using var data = new PrivateStore();
        var state = new WorkspaceState(data.Store, new MemoryCredentials(), new FakeTransport());
        Assert.True(await state.SaveConnection("https://offline.invalid", "synthetic-test", "custom-planner", ct: TestContext.Current.CancellationToken));
        var asset = data.Store.SaveImage(Fixture.PNG, state.SelectedID!, AssetSource.Imported);
        var window = new MainWindow(state, new LaunchOptions("frontend", "headless", null, false));
        window.Show();
        try
        {
            state.Draft = "不能由背景发送";
            state.Refresh();
            var input = Composer(window);
            Assert.True(input.IsEffectivelyVisible);
            Assert.True(state.OpenWorkspace(asset));
            await Pump();
            Assert.False(input.IsEffectivelyVisible);
            Assert.False(state.CanSend);
            var overlay = Assert.Single(window.GetVisualDescendants().OfType<EditorOverlay>());
            Assert.Equal(state.Workspace!.ID, overlay.Session.ID);
            Assert.Single(window.GetVisualDescendants().OfType<RegionCanvas>());
            state.CloseWorkspace(state.Workspace.ID);
            await Pump();
            Assert.True(input.IsEffectivelyVisible);
            Assert.Empty(window.GetVisualDescendants().OfType<EditorOverlay>());
            Assert.Equal("不能由背景发送", input.Text);
        }
        finally
        {
            window.Close();
        }
    }

    [AvaloniaFact]
    public async Task StreamingPreviewKeepsSelectionOnTheSameNativeTextControl()
    {
        using var data = new PrivateStore();
        var transport = new HeldPlanningTransport();
        var state = new WorkspaceState(data.Store, new MemoryCredentials(), transport);
        Assert.True(await state.SaveConnection("https://offline.invalid", "synthetic-test", "custom-planner", ct: TestContext.Current.CancellationToken));
        var window = new MainWindow(state, new LaunchOptions("frontend", "headless", null, false));
        window.Show();
        Task<RunOutcome?>? pending = null;
        try
        {
            state.Draft = "stream this";
            pending = state.Send();
            await transport.Ready.Task;
            transport.Push("{\"prompt\":\"one");
            await Pump();
            var text = Assert.Single(window.GetVisualDescendants().OfType<SelectableTextBlock>(), x => x.Text == "one");
            text.SelectionStart = 0;
            text.SelectionEnd = 3;
            transport.Push(" two");
            await Pump();
            var updated = Assert.Single(window.GetVisualDescendants().OfType<SelectableTextBlock>(), x => x.Text == "one two");
            Assert.Same(text, updated);
            Assert.Equal("one", updated.SelectedText);
        }
        finally
        {
            state.Cancel();
            if (pending != null)
                await pending;
            window.Close();
        }
    }
}

public sealed class HeldPlanningTransport : IHTTPTransport
{
    readonly FakeTransport basic = new();
    readonly TaskCompletionSource finished = new();
    Action<HTTPStreamEvent>? receive;
    public TaskCompletionSource Ready { get; } = new();

    public Task<HTTPResponse> SendAsync(System.Net.Http.HttpRequestMessage request, CancellationToken ct) => basic.SendAsync(request, ct);
    public async Task StreamAsync(System.Net.Http.HttpRequestMessage request, Action<HTTPStreamEvent> callback, CancellationToken ct)
    {
        receive = callback;
        callback(new(200, "text/event-stream"));
        callback(new(Bytes: Fixture.Event("response.output_item.added", new { output_index = 0, item = Fixture.Call("") })));
        using var registration = ct.Register(() => finished.TrySetCanceled(ct));
        Ready.SetResult();
        await finished.Task;
    }

    public void Push(string text) => receive!(new(Bytes: Fixture.Event("response.function_call_arguments.delta", new { output_index = 0, item_id = "item", delta = text })));
}
