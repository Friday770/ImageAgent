using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Input.Platform;
using Avalonia.Controls.Presenters;
using Avalonia.VisualTree;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Platform.Storage;
using Avalonia.Styling;
using Avalonia.Threading;
using ImageAgent.Core;
using System.Diagnostics;

namespace ImageAgent.Desktop;

public sealed class MainWindow : Window
{
    readonly WorkspaceState state;
    readonly LaunchOptions options;
    readonly Grid root = new();
    readonly Grid workspace = new();
    readonly Grid chat = new();
    readonly Grid side = new()
    {
        RowDefinitions = new("Auto,Auto,*,Auto")
    };
    readonly Border composerFrame = new();
    readonly ListBox conversations = new();
    readonly StackPanel timeline = new()
    {
        Spacing = 24,
        MaxWidth = 860,
        Margin = new(32, 24)
    };
    readonly ScrollViewer scroller = new();
    readonly StackPanel attachments = new()
    {
        Spacing = 8
    };
    readonly StackPanel notices = new()
    {
        Spacing = 8
    };
    readonly TextBox composer = new()
    {
        AcceptsReturn = true,
        TextWrapping = TextWrapping.Wrap,
        MinHeight = 56,
        MaxHeight = 160,
        PlaceholderText = "描述你的画面，或说说想怎样修改…",
        BorderThickness = new(0),
        Background = Brushes.Transparent
    };
    readonly Button send = new()
    {
        Content = "↑",
        MinWidth = 44
    };
    readonly Button cancel = new()
    {
        Content = "■ 取消"
    };
    readonly Button attach = new()
    {
        Content = "＋",
        MinWidth = 36
    };
    readonly ComboBox model = new()
    {
        Width = 198
    };
    readonly ComboBox size = new()
    {
        Width = 127
    };
    readonly ComboBox quality = new()
    {
        Width = 100
    };
    readonly TextBlock status = new()
    {
        FontSize = 12
    };
    readonly Dictionary<string, bool> promptExpanded = [];
    bool refreshing;
    bool nativeTextPaste;
    string? lastConversation;
    string? timelineSignature;
    string? renderedConversation;
    SelectableTextBlock? livePromptBody;
    string livePromptText = "";
    bool builtConnected;
    Control? login;
    EditorOverlay? editor;
    ConnectionDraft? loginDraft;
    readonly Func<FilePickerSaveOptions, Task<IStorageFile?>> pickExportFile;
    public MainWindow(WorkspaceState state, LaunchOptions options, Func<FilePickerSaveOptions, Task<IStorageFile?>>? pickExportFile = null)
    {
        this.state = state;
        this.options = options;
        this.pickExportFile = pickExportFile ?? (settings => StorageProvider.SaveFilePickerAsync(settings));
        Title = "ImageAgent";
        Width = 1180;
        Height = 860;
        MinWidth = 960;
        MinHeight = 680;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        using (var stream = AssetLoader.Open(new Uri("avares://ImageAgent/Assets/AppIcon.ico")))
            Icon = new WindowIcon(stream);
        Content = root;
        BuildWorkspace();
        PropertyChanged += (_, e) =>
        {
            if (e.Property == ActualThemeVariantProperty)
            {
                timelineSignature = null;
                Update();
            }
        };
        state.Changed += Update;
        KeyDown += OnWindowKeyDown;
        Closed += (_, _) =>
        {
            state.Changed -= Update;
            loginDraft?.Close();
            editor?.Dispose();
        };
        Update();
    }

    static IBrush Accent => new SolidColorBrush(Color.Parse("#306655"));

    bool Dark => ActualThemeVariant == ThemeVariant.Dark;

    IBrush Paper => new SolidColorBrush(Color.Parse(Dark ? "#292a27" : "#f0ede2"));

    IBrush Canvas => new SolidColorBrush(Color.Parse(Dark ? "#20211f" : "#fbfcfa"));

    public static TextBlock Label(string text, double font = 14) => new()
    {
        Text = text,
        FontSize = font,
        TextWrapping = TextWrapping.Wrap
    };
    public static SelectableTextBlock Selectable(string text) => new()
    {
        Text = text,
        TextWrapping = TextWrapping.Wrap
    };
    public static Button Button(string text, Action action, string? name = null)
    {
        var b = new Button
        {
            Content = text
        };
        b.Click += (_, _) => action();
        AutomationProperties.SetName(b, name ?? text);
        return b;
    }

    static Border Panel(Control child, IBrush? background = null, double radius = 12, Thickness? padding = null) => new()
    {
        Child = child,
        Background = background,
        CornerRadius = new(radius),
        Padding = padding ?? new(14)
    };
    void BuildWorkspace()
    {
        workspace.ColumnDefinitions = new("248,*");
        root.Children.Add(workspace);
        side.Background = Paper;
        workspace.Children.Add(side);
        side.Children.Add(new TextBlock { Text = "▧  ImageAgent", FontSize = 21, FontWeight = FontWeight.SemiBold, Foreground = Accent, Margin = new(20, 24) });
        var fresh = Button("＋ 新建会话", () => Guard(state.NewConversation));
        fresh.Margin = new(16, 0, 16, 12);
        Grid.SetRow(fresh, 1);
        side.Children.Add(fresh);
        Grid.SetRow(conversations, 2);
        side.Children.Add(conversations);
        conversations.SelectionChanged += (_, _) =>
        {
            if (!refreshing && conversations.SelectedItem is ListBoxItem row && row.Tag is string id)
                state.Select(id);
        };
        var sideBottom = new Grid
        {
            ColumnDefinitions = new("*,Auto"),
            Margin = new(16)
        };
        sideBottom.Children.Add(status);
        var settings = Button("⚙", () => _ = OpenSettings(), "设置");
        Grid.SetColumn(settings, 1);
        sideBottom.Children.Add(settings);
        Grid.SetRow(sideBottom, 3);
        side.Children.Add(sideBottom);
        Grid.SetColumn(chat, 1);
        workspace.Children.Add(chat);
        chat.RowDefinitions = new("*,Auto");
        chat.Background = Canvas;
        scroller.Content = timeline;
        scroller.HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        chat.Children.Add(scroller);
        var input = new StackPanel
        {
            Spacing = 10,
            Margin = new(28, 10, 28, 18)
        };
        Grid.SetRow(input, 1);
        chat.Children.Add(input);
        input.Children.Add(notices);
        input.Children.Add(attachments);
        var frame = new StackPanel
        {
            Spacing = 10
        };
        frame.Children.Add(composer);
        AutomationProperties.SetName(composer, "创作需求输入框");
        composer.TextChanged += (_, _) =>
        {
            if (!refreshing)
                state.Draft = composer.Text ?? "";
            send.IsEnabled = state.CanSend;
        };
        composer.AddHandler(KeyDownEvent, ComposerKeyDown, handledEventsToo: true);
        composer.PastingFromClipboard += async (_, e) =>
        {
            if (nativeTextPaste)
            {
                nativeTextPaste = false;
                return;
            }

            e.Handled = true;
            var source = state.SelectedID;
            if (!await PasteImage() && source == state.SelectedID && state.Workspace == null)
            {
                nativeTextPaste = true;
                composer.Paste();
            }
        };
        var actions = new Grid
        {
            ColumnDefinitions = new("Auto,Auto,Auto,Auto,*,Auto,Auto"),
            ColumnSpacing = 8
        };
        frame.Children.Add(actions);
        attach.Click += async (_, _) => await Upload();
        ToolTip.SetTip(attach, "上传参考图片");
        actions.Children.Add(attach);
        model.ItemsSource = ImageModels.All;
        size.ItemsSource = ImageModels.Sizes;
        size.ItemTemplate = new FuncDataTemplate<string>((value, _) => Label(value == "auto" ? "自动尺寸" : value ?? ""));
        quality.ItemsSource = ImageModels.Qualities;
        quality.ItemTemplate = new FuncDataTemplate<string>((value, _) => Label(value switch
        {
            "auto" => "自动质量",
            "low" => "低质量",
            "medium" => "中等质量",
            "high" => "高质量",
            _ => value ?? ""
        }));
        Grid.SetColumn(model, 1);
        Grid.SetColumn(size, 2);
        Grid.SetColumn(quality, 3);
        actions.Children.Add(model);
        actions.Children.Add(size);
        actions.Children.Add(quality);
        AutomationProperties.SetName(model, "图片模型");
        AutomationProperties.SetName(size, "尺寸");
        AutomationProperties.SetName(quality, "质量");
        foreach (var picker in new[]
        {
            model,
            size,
            quality
        }

        )
            picker.SelectionChanged += (_, _) =>
            {
                if (!refreshing && model.SelectedItem is string m && size.SelectedItem is string s && quality.SelectedItem is string q)
                    Guard(() => state.SetSelection(new() { Model = m, Size = s, Quality = q }));
            };
        Grid.SetColumn(cancel, 5);
        Grid.SetColumn(send, 6);
        actions.Children.Add(cancel);
        actions.Children.Add(send);
        cancel.Click += (_, _) => state.Cancel();
        send.Click += async (_, _) => await state.Send();
        ToolTip.SetTip(send, "发送（Ctrl+Enter）");
        composerFrame.Child = frame;
        composerFrame.Padding = new(14);
        composerFrame.CornerRadius = new(16);
        composerFrame.BorderThickness = new(1);
        composerFrame.BorderBrush = new SolidColorBrush(Color.Parse("#33808080"));
        input.Children.Add(composerFrame);
    }

    void Update()
    {
        if (!Dispatcher.UIThread.CheckAccess())
        {
            Dispatcher.UIThread.Post(Update);
            return;
        }

        refreshing = true;
        try
        {
            side.Background = Paper;
            chat.Background = Canvas;
            composerFrame.Background = Dark ? new SolidColorBrush(Color.Parse("#292a27")) : Brushes.White;
            if (login is Grid loginGrid && loginGrid.Children[0] is Border intro)
                intro.Background = Paper;
            workspace.IsVisible = state.HasConnection;
            if (!state.HasConnection)
            {
                if (login == null)
                {
                    login = BuildConnection();
                    root.Children.Add(login);
                }

                login.IsVisible = true;
                workspace.IsEnabled = false;
            }
            else
            {
                if (login != null)
                {
                    root.Children.Remove(login);
                    login = null;
                    loginDraft?.Close();
                    loginDraft = null;
                }

                workspace.IsEnabled = state.Workspace == null;
            }

            if (state.HasConnection && !builtConnected)
            {
                builtConnected = true;
                timelineSignature = null;
            }

            var rows = new List<ListBoxItem>();
            foreach (var c in state.Conversations)
            {
                var text = new StackPanel
                {
                    Spacing = 5,
                    Margin = new(5, 7)
                };
                text.Children.Add(new TextBlock { Text = (state.IsBusy && state.ActiveConversationID == c.ID ? "◌ " : "◦ ") + c.Title, TextTrimming = TextTrimming.CharacterEllipsis });
                text.Children.Add(new TextBlock { Text = c.UpdatedAt.LocalDateTime.ToString("M月d日"), FontSize = 11, Opacity = .55 });
                var row = new ListBoxItem
                {
                    Content = text,
                    Tag = c.ID
                };
                var menu = new MenuItem
                {
                    Header = "删除会话…",
                    IsEnabled = !(state.IsBusy && state.ActiveConversationID == c.ID)
                };
                menu.Click += async (_, _) =>
                {
                    if (await Confirm("删除此会话及其本地图片？", "此操作会移除会话历史和原始图片。"))
                        Guard(() => state.DeleteConversation(c.ID));
                };
                row.ContextMenu = new ContextMenu
                {
                    ItemsSource = new[]
                    {
                        menu
                    }
                };
                rows.Add(row);
            }

            conversations.ItemsSource = rows;
            conversations.SelectedItem = rows.FirstOrDefault(r => (string?)r.Tag == state.SelectedID);
            status.Text = options.IsOffline ? "● 离线演示" : "● 已连接到你的服务";
            status.Foreground = options.IsOffline ? Brushes.DarkOrange : Accent;
            if (lastConversation != state.SelectedID)
            {
                lastConversation = state.SelectedID;
                composer.IsUndoEnabled = false;
                composer.IsUndoEnabled = true;
            }

            if (composer.Text != state.Draft)
                composer.Text = state.Draft;
            model.SelectedItem = state.Settings.Selection.Model;
            size.SelectedItem = state.Settings.Selection.Size;
            quality.SelectedItem = state.Settings.Selection.Quality;
            attach.IsEnabled = !state.IsBusy && !state.IsConnecting;
            send.IsVisible = !state.IsBusy;
            send.IsEnabled = state.CanSend;
            cancel.IsVisible = state.IsBusy;
            cancel.IsEnabled = !state.IsCancelling;
            notices.Children.Clear();
            if (state.Error != null)
                notices.Children.Add(Error(state.Error));
            if (state.FailedEditorTarget?.ConversationID == state.SelectedID)
            {
                var row = new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 12
                };
                row.Children.Add(Label("上次编辑的要求与选区已保留。", 12));
                row.Children.Add(Button("重新打开编辑", state.ReopenFailedEditor));
                notices.Children.Add(row);
            }

            attachments.Children.Clear();
            if (state.ReferenceID is { } id && state.Store.Asset(id) is { } reference)
            {
                var row = new Grid
                {
                    ColumnDefinitions = new("Auto,*,Auto")
                };
                row.Children.Add(Thumbnail(reference, 48, 48));
                var remove = Button("×", () =>
                {
                    state.ReferenceID = null;
                    state.Error = null;
                    state.Refresh();
                }, "移除参考附件");
                Grid.SetColumn(remove, 2);
                row.Children.Add(remove);
                attachments.Children.Add(Panel(row, Paper, 10, new(8)));
            }

            RenderTimeline();
            if (state.Workspace is { } session)
            {
                if (editor?.Session.ID != session.ID)
                {
                    if (editor != null)
                    {
                        root.Children.Remove(editor);
                        editor.Dispose();
                    }

                    editor = new(this, state, session);
                    root.Children.Add(editor);
                    editor.FocusPrompt();
                }

                workspace.IsVisible = false;
                workspace.IsEnabled = false;
                AutomationProperties.SetAccessibilityView(workspace, AccessibilityView.Raw);
            }
            else
            {
                AutomationProperties.SetAccessibilityView(workspace, AccessibilityView.Control);
                if (editor != null)
                {
                    root.Children.Remove(editor);
                    editor.Dispose();
                    editor = null;
                    composer.Focus();
                }
            }
        }
        finally
        {
            refreshing = false;
        }
    }

    void RenderTimeline()
    {
        var p = state.PlanningPrompt?.ConversationID == state.SelectedID ? state.PlanningPrompt : null;
        var signature = string.Join("|", state.Messages.Select(m => m.ID)) + string.Join("|", state.Assets.Select(a => a.ID)) + "/" + state.SelectedID + "/" + state.IsBusy + "/" + state.IsCancelling + "/" + state.ActiveRun?.Stage + "/" + p?.RunID + "/" + p?.Status;
        var nearBottom = scroller.Offset.Y + scroller.Viewport.Height >= scroller.Extent.Height - 80;
        if (signature == timelineSignature)
        {
            if (p != null && livePromptBody != null && livePromptText != p.Text)
            {
                int start = livePromptBody.SelectionStart, end = livePromptBody.SelectionEnd;
                livePromptText = p.Text;
                livePromptBody.Text = p.Text;
                livePromptBody.SelectionStart = Math.Min(start, p.Text.Length);
                livePromptBody.SelectionEnd = Math.Min(end, p.Text.Length);
                if (nearBottom && start == end)
                    Dispatcher.UIThread.Post(() => scroller.ScrollToEnd(), DispatcherPriority.Background);
            }

            return;
        }

        var changedConversation = renderedConversation != state.SelectedID;
        renderedConversation = state.SelectedID;
        timelineSignature = signature;
        livePromptBody = null;
        livePromptText = "";
        timeline.Children.Clear();
        if (options.Mode == "streaming")
        {
            var demos = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 10
            };
            demos.Children.Add(Button("离线流式演示", () =>
            {
                state.Draft = "离线模拟：山间湖泊";
                _ = state.Send();
            }));
            demos.Children.Add(Button("模拟中断", () =>
            {
                state.Draft = "[interrupt] 离线模拟提示词中断";
                _ = state.Send();
            }));
            timeline.Children.Add(demos);
        }

        if (state.Messages.Count == 0)
        {
            var welcome = new StackPanel
            {
                Spacing = 20,
                Margin = new(10, 70),
                HorizontalAlignment = HorizontalAlignment.Center
            };
            welcome.Children.Add(new TextBlock { Text = "✧", FontSize = 40, Foreground = Accent, HorizontalAlignment = HorizontalAlignment.Center });
            welcome.Children.Add(new TextBlock { Text = "从一个想法开始", FontSize = 27, HorizontalAlignment = HorizontalAlignment.Center });
            var ideas = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 10
            };
            foreach (var idea in new[]
            {
                "暖色的山间湖泊插画",
                "极简咖啡品牌海报"
            }

            )
                ideas.Children.Add(Button(idea, () =>
                {
                    state.Draft = idea;
                    state.Refresh();
                    composer.Focus();
                }));
            welcome.Children.Add(ideas);
            timeline.Children.Add(welcome);
        }

        foreach (var m in state.Messages)
            timeline.Children.Add(Message(m));
        var shown = state.Messages.SelectMany(m => m.AssetIDs).ToHashSet();
        foreach (var a in state.Assets.Where(a => a.Source != AssetSource.Imported && !shown.Contains(a.ID)))
            timeline.Children.Add(ImageCard(a));
        if (p != null && p.Text.Length > 0)
            timeline.Children.Add(Prompt(p.Text, p.Status, p.RunID, true));
        if (state.IsBusy && state.ActiveConversationID == state.SelectedID)
        {
            var row = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 12
            };
            row.Children.Add(new ProgressBar { IsIndeterminate = true, Width = 32, Height = 4, VerticalAlignment = VerticalAlignment.Center });
            row.Children.Add(Label(state.IsCancelling ? "正在取消；已返回的图片会保留…" : state.ActiveRun?.Stage.Label() ?? "正在记录任务…"));
            timeline.Children.Add(row);
        }

        if (nearBottom || changedConversation)
            Dispatcher.UIThread.Post(() => scroller.ScrollToEnd(), DispatcherPriority.Background);
    }

    Control Message(MessageRecord m)
    {
        var stack = new StackPanel
        {
            Spacing = 10
        };
        if (m.Role == MessageRole.User)
        {
            stack.HorizontalAlignment = HorizontalAlignment.Right;
            stack.MaxWidth = 620;
            if (m.AssetIDs.Length > 0)
            {
                var refs = new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 8,
                    HorizontalAlignment = HorizontalAlignment.Right
                };
                foreach (var id in m.AssetIDs)
                    if (state.Store.Asset(id) is { } a)
                        refs.Children.Add(Thumbnail(a, 104, 88));
                    else
                        refs.Children.Add(Label("参考图不可用"));
                stack.Children.Add(refs);
            }

            var text = Selectable(m.Text);
            text.Foreground = Brushes.White;
            stack.Children.Add(Panel(text, new SolidColorBrush(Color.Parse("#2377d7")), 16, new(15)));
            var actions = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 8,
                HorizontalAlignment = HorizontalAlignment.Right
            };
            actions.Children.Add(Button("复制", () => _ = Copy(m.Text), "复制用户原话"));
            if (state.CanReturnToEdit(m))
                actions.Children.Add(Button("返回编辑", () =>
                {
                    state.ReturnToEdit(m);
                    composer.Focus();
                }, "返回编辑已取消的请求"));
            stack.Children.Add(actions);
        }
        else
        {
            stack.Children.Add(new TextBlock { Text = "✧ ImageAgent", FontSize = 12, FontWeight = FontWeight.SemiBold, Foreground = Accent });
            stack.Children.Add(Selectable(m.Text));
            if (!string.IsNullOrEmpty(m.DetailedPrompt))
                stack.Children.Add(Prompt(m.DetailedPrompt, "validated", m.ID, false));
            foreach (var id in m.AssetIDs)
                stack.Children.Add(state.Store.Asset(id) is { } a ? ImageCard(a) : Label("原始图片文件不可用"));
        }

        return stack;
    }

    Control Prompt(string text, string statusText, string id, bool live)
    {
        var body = new StackPanel
        {
            Spacing = 10
        };
        var expanded = promptExpanded.GetValueOrDefault(id, live);
        var selectable = Selectable(text);
        if (live)
        {
            livePromptBody = selectable;
            livePromptText = text;
        }

        var detail = new ScrollViewer
        {
            MaxHeight = 240,
            MinHeight = 55,
            Content = selectable,
            IsVisible = expanded
        };
        var row = new Grid
        {
            ColumnDefinitions = new("Auto,*,Auto"),
            ColumnSpacing = 10
        };
        var toggle = Button((expanded ? "⌄ " : "› ") + "增强后的提示词", () =>
        {
            var value = !detail.IsVisible;
            detail.IsVisible = value;
            promptExpanded[id] = value;
        });
        row.Children.Add(toggle);
        var label = Label(statusText switch
        {
            "planning" => "正在整理",
            "unfinished" => "未完成 · 未用于图片请求",
            _ => "完整提示词"
        }, 12);
        Grid.SetColumn(label, 1);
        row.Children.Add(label);
        var copy = Button(statusText == "validated" ? "复制提示词" : "复制预览", () => _ = Copy(live ? livePromptText : text));
        Grid.SetColumn(copy, 2);
        row.Children.Add(copy);
        body.Children.Add(row);
        body.Children.Add(detail);
        return Panel(body, Paper, 12);
    }

    Bitmap? LoadThumbnail(AssetRecord a)
    {
        try
        {
            using var file = File.OpenRead(state.Store.AssetPath(a));
            try
            {
                return Bitmap.DecodeToWidth(file, 768);
            }
            catch
            {
                using var normalized = new MemoryStream(PixelImage.Decode(File.ReadAllBytes(state.Store.AssetPath(a))).PngData());
                return Bitmap.DecodeToWidth(normalized, 768);
            }
        }
        catch (Exception)
        {
            return null;
        }
    }

    Control Thumbnail(AssetRecord a, double width, double height)
    {
        var available = File.Exists(state.Store.AssetPath(a));
        var button = Button("", () => state.OpenWorkspace(a), "参考图，查看与编辑");
        button.Padding = new(0);
        button.Content = !available ? Label("图片不可用") : new CheckerImage
        {
            Loader = () => LoadThumbnail(a),
            Width = width,
            Height = height
        };
        ToolTip.SetTip(button, "查看与编辑参考图");
        return button;
    }

    Control ImageCard(AssetRecord a)
    {
        var available = File.Exists(state.Store.AssetPath(a));
        var content = new StackPanel
        {
            Spacing = 0,
            MaxWidth = 520,
            HorizontalAlignment = HorizontalAlignment.Left
        };
        var preview = Button("", () => state.OpenWorkspace(a), "查看与编辑图片");
        preview.Padding = new(0);
        preview.HorizontalAlignment = HorizontalAlignment.Left;
        preview.Content = !available ? new TextBlock
        {
            Text = "原始图片文件不可用",
            Width = 460,
            Height = 230,
            VerticalAlignment = VerticalAlignment.Center
        }

        : new CheckerImage
        {
            Loader = () => LoadThumbnail(a),
            Width = Math.Min(520, 520d * a.Width / Math.Max(a.Width, a.Height)),
            Height = Math.Min(420, 520d * a.Height / Math.Max(a.Width, a.Height))
        };
        content.Children.Add(preview);
        var actions = new Grid
        {
            ColumnDefinitions = new("*,Auto,Auto"),
            ColumnSpacing = 8,
            Margin = new(12)
        };
        actions.Children.Add(Button("查看与编辑", () => state.OpenWorkspace(a)));
        var reference = Button("▧＋", () => state.UseReference(a), "作为参考继续编辑");
        ToolTip.SetTip(reference, "作为参考继续编辑");
        Grid.SetColumn(reference, 1);
        actions.Children.Add(reference);
        var save = Button("↓", () => _ = Export(a), "保存副本");
        ToolTip.SetTip(save, "保存副本");
        Grid.SetColumn(save, 2);
        actions.Children.Add(save);
        content.Children.Add(actions);
        if (a.ModelWarning != null)
            content.Children.Add(Error(a.ModelWarning));
        return new Border
        {
            Child = content,
            CornerRadius = new(13),
            ClipToBounds = true,
            BorderThickness = new(1),
            BorderBrush = new SolidColorBrush(Color.Parse("#33808080"))
        };
    }

    public static Control Error(string error) => new Border
    {
        Child = Selectable(error),
        Padding = new(12),
        CornerRadius = new(9),
        Background = new SolidColorBrush(Color.Parse("#18ee9d24")),
        BorderBrush = new SolidColorBrush(Color.Parse("#55bb8220")),
        BorderThickness = new(1)
    };
    Control BuildConnection()
    {
        loginDraft = new(state);
        var draft = loginDraft;
        var outer = new Grid
        {
            ColumnDefinitions = new("*,470")
        };
        var intro = new StackPanel
        {
            Spacing = 26,
            Margin = new(46),
            VerticalAlignment = VerticalAlignment.Center
        };
        intro.Children.Add(new TextBlock { Text = "▧  ImageAgent", FontSize = 23, Foreground = Accent });
        intro.Children.Add(new TextBlock { Text = "把想法，\n变成画面。", FontSize = 48, FontWeight = FontWeight.Medium, Margin = new(0, 55, 0, 0) });
        intro.Children.Add(new TextBlock { Text = "说出你想看见的。\n从第一张图片，到每一次细微调整。", FontSize = 19, Opacity = .65 });
        intro.Children.Add(Label("自然语言创作    连续编辑    本地记忆", 13));
        intro.Children.Add(new TextBlock { Text = "Windows · 图片与会话保存在你的电脑", FontSize = 12, Opacity = .5, Margin = new(0, 70, 0, 0) });
        outer.Children.Add(new Border { Child = intro, Background = Paper });
        var form = new StackPanel
        {
            Spacing = 18,
            Margin = new(44),
            VerticalAlignment = VerticalAlignment.Center
        };
        Grid.SetColumn(form, 1);
        outer.Children.Add(form);
        form.Children.Add(new TextBlock { Text = "✧", FontSize = 36, Foreground = Accent });
        form.Children.Add(new TextBlock { Text = "连接你的图片服务", FontSize = 27, FontWeight = FontWeight.SemiBold });
        form.Children.Add(Label("使用 API 地址和 Key 开始创作。"));
        form.Children.Add(Label("API 地址"));
        var address = new TextBox
        {
            Text = draft.Address,
            PlaceholderText = "https://api.example.com/v1"
        };
        form.Children.Add(address);
        form.Children.Add(new TextBlock { Text = "支持服务根地址或 /v1 地址", FontSize = 12, Opacity = .6 });
        form.Children.Add(Label("API Key"));
        var keyRow = new Grid
        {
            ColumnDefinitions = new("*,Auto"),
            ColumnSpacing = 8
        };
        var key = new TextBox
        {
            PasswordChar = '●',
            PlaceholderText = "输入此服务的 Key"
        };
        var reveal = Button("显示", () =>
        {
            draft.Revealed = !draft.Revealed;
            key.PasswordChar = draft.Revealed ? '\0' : '●';
        }, "显示或隐藏 API Key");
        keyRow.Children.Add(key);
        Grid.SetColumn(reveal, 1);
        keyRow.Children.Add(reveal);
        form.Children.Add(keyRow);
        form.Children.Add(new TextBlock { Text = "Key 加密保存在 Windows 凭据管理器，仅用于对应服务。", FontSize = 12, Opacity = .65, TextWrapping = TextWrapping.Wrap });
        var error = new ContentControl();
        form.Children.Add(error);
        var connect = new Button
        {
            Content = "验证并连接  →"
        };
        connect.Click += async (_, _) => await Connect();
        connect.HorizontalAlignment = HorizontalAlignment.Stretch;
        form.Children.Add(connect);
        if (options.IsOffline)
            form.Children.Add(Label("离线命名 session · 假凭据 / 假 HTTP", 12));
        address.TextChanged += (_, _) =>
        {
            if (draft.Address == (address.Text ?? ""))
                return;
            draft.Address = address.Text ?? "";
            key.Text = "";
            key.PasswordChar = '●';
        };
        key.TextChanged += (_, _) => draft.Key = key.Text ?? "";
        AutomationProperties.SetName(address, "API 地址");
        AutomationProperties.SetName(key, "API Key");
        async Task Connect()
        {
            connect.IsEnabled = false;
            address.IsEnabled = false;
            key.IsEnabled = false;
            var success = await state.SaveConnection(draft.Address, draft.Key, draft.Value);
            if (!success)
            {
                error.Content = Error(state.ConnectionError ?? "连接失败");
                connect.IsEnabled = true;
                address.IsEnabled = true;
                key.IsEnabled = true;
            }
        }

        return outer;
    }

    public void Guard(Action action)
    {
        try
        {
            action();
        }
        catch (Exception e)
        {
            state.Error = e.Message;
            state.Refresh();
        }
    }

    public async Task Copy(string text)
    {
        if (Clipboard != null)
            await Clipboard.SetValueAsync(DataFormat.Text, text);
    }

    public async Task Export(AssetRecord a, Action<string>? failure = null)
    {
        try
        {
            var path = state.Store.AssetPath(a);
            if (!File.Exists(path))
                throw new AgentException("原始图片文件不可用。");
            var bytes = await File.ReadAllBytesAsync(path);
            var file = await pickExportFile(new()
            {
                Title = "保存图片副本",
                SuggestedFileName = "ImageAgent-" + a.ID[..8] + Path.GetExtension(path),
                DefaultExtension = Path.GetExtension(path)
            });
            if (file == null)
                return;
            if (file.TryGetLocalPath() is { } localPath)
            {
                await Task.Run(() => AppPaths.WriteAtomic(localPath, bytes));
                return;
            }
            await using var output = await file.OpenWriteAsync();
            if (output.CanSeek)
                output.SetLength(0);
            await output.WriteAsync(bytes);
            await output.FlushAsync();
        }
        catch (Exception e)
        {
            state.Error = e.Message;
            failure?.Invoke(e.Message);
            state.Refresh();
        }
    }

    public void OpenPath(string path)
    {
        Guard(() =>
        {
            if (OperatingSystem.IsWindows())
            {
                var arg = File.Exists(path) ? "/select,\"" + path + "\"" : "\"" + path + "\"";
                Process.Start(new ProcessStartInfo("explorer.exe", arg) { UseShellExecute = true });
            }
            else
                Process.Start(new ProcessStartInfo("open", Path.GetDirectoryName(path) == null ? path : Directory.Exists(path) ? path : Path.GetDirectoryName(path)!) { UseShellExecute = false });
        });
    }

    async Task Upload()
    {
        var source = state.SelectedID;
        try
        {
            var files = await StorageProvider.OpenFilePickerAsync(new()
            {
                Title = "选择参考图片",
                AllowMultiple = false,
                FileTypeFilter = [new("图片") { Patterns = ["*.png", "*.tiff", "*.tif", "*.jpg", "*.jpeg", "*.webp", "*.bmp"] }]
            });
            if (files.Count == 0)
                return;
            if (files.Count != 1)
                throw new AgentException("请一次只选择一张图片。");
            await using var input = await files[0].OpenReadAsync();
            var bytes = await ReadImage(input);
            if (source != state.SelectedID)
                throw new AgentException("会话已切换；参考图片未附加到其他草稿。");
            state.ImportReference(bytes);
        }
        catch (Exception e)
        {
            state.Error = e.Message;
            state.Refresh();
        }
    }

    static async Task<byte[]> ReadImage(Stream input)
    {
        using var bytes = new MemoryStream();
        var buffer = new byte[8192];
        int n;
        while ((n = await input.ReadAsync(buffer)) > 0)
        {
            if (bytes.Length + n > DecodedImage.MaximumBytes)
                throw new AgentException("图片文件超过 100 MiB。");
            bytes.Write(buffer, 0, n);
        }

        return bytes.ToArray();
    }

    async void ComposerKeyDown(object? sender, KeyEventArgs e)
    {
        if (state.Workspace != null)
            return;
        if (e.Key == Key.Enter && e.KeyModifiers.HasFlag(KeyModifiers.Control) && !composer.GetVisualDescendants().OfType<TextPresenter>().Any(p => !string.IsNullOrEmpty(p.PreeditText)))
        {
            e.Handled = true;
            await state.Send();
        }
    }

    async Task<bool> PasteImage()
    {
        if (Clipboard == null)
            return false;
        var source = state.SelectedID;
        try
        {
            return await ClipboardReader.Paste(Clipboard, bytes =>
            {
                if (source != state.SelectedID)
                    throw new AgentException("会话已切换；剪贴板图片未附加到其他草稿。");
                return state.ImportReference(bytes);
            });
        }
        catch (Exception e)
        {
            state.Error = e.Message;
            state.Refresh();
            return true;
        }
    }

    void OnWindowKeyDown(object? sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape && state.Workspace is { } s)
        {
            state.CloseWorkspace(s.ID);
            e.Handled = true;
        }
        else if (state.Workspace == null && e.Key == Key.N && e.KeyModifiers.HasFlag(KeyModifiers.Control))
        {
            state.NewConversation();
            e.Handled = true;
        }
        else if (state.Workspace == null && e.Key == Key.OemComma && e.KeyModifiers.HasFlag(KeyModifiers.Control))
        {
            _ = OpenSettings();
            e.Handled = true;
        }
    }

    async Task<bool> Confirm(string title, string text)
    {
        var dialog = new Window
        {
            Title = title,
            Width = 450,
            Height = 220,
            CanResize = false,
            WindowStartupLocation = WindowStartupLocation.CenterOwner
        };
        var panel = new StackPanel
        {
            Spacing = 20,
            Margin = new(24)
        };
        panel.Children.Add(Label(text));
        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 10,
            HorizontalAlignment = HorizontalAlignment.Right
        };
        actions.Children.Add(Button("取消", () => dialog.Close(false)));
        actions.Children.Add(Button("删除会话", () => dialog.Close(true)));
        panel.Children.Add(actions);
        dialog.Content = panel;
        return await dialog.ShowDialog<bool>(this);
    }

    public async Task OpenSettings()
    {
        if (state.Workspace != null)
            return;
        var dialog = new SettingsWindow(this, state);
        await dialog.ShowDialog(this);
    }
}

public sealed class CheckerImage : Control
{
    Bitmap? source;
    public Func<Bitmap?>? Loader
    {
        get; set;
    }

    bool attempted;
    public CheckerImage()
    {
        EffectiveViewportChanged += (_, e) =>
        {
            bool visible = e.EffectiveViewport.Intersects(new Rect(Bounds.Size));
            if (visible && !attempted)
            {
                attempted = true;
                source = Loader?.Invoke();
                InvalidateVisual();
            }
            else if (!visible && attempted)
            {
                source?.Dispose();
                source = null;
                attempted = false;
                InvalidateVisual();
            }
        };
        DetachedFromVisualTree += (_, _) =>
        {
            source?.Dispose();
            source = null;
            attempted = false;
        };
    }

    public override void Render(DrawingContext context)
    {
        base.Render(context);
        var area = new Rect(Bounds.Size);
        context.FillRectangle(new SolidColorBrush(Color.Parse("#454545")), area);
        for (int y = 0; y < Bounds.Height; y += 12)
            for (int x = 0; x < Bounds.Width; x += 12)
                if ((x / 12 + y / 12) % 2 == 0)
                    context.FillRectangle(new SolidColorBrush(Color.Parse("#575757")), new Rect(x, y, Math.Min(12, Bounds.Width - x), Math.Min(12, Bounds.Height - y)));
        if (source != null)
        {
            var factor = Math.Min(Bounds.Width / source.PixelSize.Width, Bounds.Height / source.PixelSize.Height);
            var w = source.PixelSize.Width * factor;
            var h = source.PixelSize.Height * factor;
            context.DrawImage(source, new Rect((Bounds.Width - w) / 2, (Bounds.Height - h) / 2, w, h));
        }
        else if (attempted)
        {
            var text = new FormattedText("原始图片文件不可用", System.Globalization.CultureInfo.CurrentCulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), 14, Brushes.White);
            context.DrawText(text, new Point(10, Math.Max(10, Bounds.Height / 2 - 10)));
        }
    }
}
