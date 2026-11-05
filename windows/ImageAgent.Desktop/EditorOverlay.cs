using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Presenters;
using Avalonia.Input;
using Avalonia.Input.GestureRecognizers;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Styling;
using Avalonia.Threading;
using Avalonia.VisualTree;
using ImageAgent.Core;

namespace ImageAgent.Desktop;

public sealed class EditorOverlay : Border, IDisposable
{
    public WorkspaceSession Session
    {
        get;
    }

    readonly WorkspaceState state;
    readonly MainWindow window;
    readonly TextBox prompt = new()
    {
        AcceptsReturn = true,
        TextWrapping = TextWrapping.Wrap,
        PlaceholderText = "选择区域，描述想怎样修改…",
        MinHeight = 44,
        MaxHeight = 112
    };
    readonly RegionCanvas? canvas;
    readonly RegionSelection? selection;
    readonly TextBlock zoom = new()
    {
        Text = "100%",
        VerticalAlignment = VerticalAlignment.Center
    };
    readonly Button submit = new()
    {
        Content = "↑",
        MinWidth = 42
    };
    readonly StackPanel toolBar = new()
    {
        Orientation = Orientation.Horizontal,
        Spacing = 10
    };
    readonly ContentControl error = new();
    EditorTool tool;
    bool loaded;
    bool disposed;
    readonly List<Button> toolButtons = [];
    readonly StackPanel actions = new()
    {
        Orientation = Orientation.Horizontal,
        Spacing = 16,
        HorizontalAlignment = HorizontalAlignment.Center
    };
    readonly AssetRecord? asset;
    public EditorOverlay(MainWindow window, WorkspaceState state, WorkspaceSession session)
    {
        this.window = window;
        this.state = state;
        Session = session;
        Background = new SolidColorBrush(Color.Parse("#111211"));
        Focusable = true;
        AutomationProperties.SetName(this, "图片工作区");
        AutomationProperties.SetAutomationId(this, "image-workspace");
        var layout = new Grid
        {
            RowDefinitions = new("Auto,*,Auto"),
            Margin = new(20)
        };
        Child = new ThemeVariantScope
        {
            RequestedThemeVariant = ThemeVariant.Dark,
            Child = layout
        };
        var top = new Grid
        {
            ColumnDefinitions = new("*,Auto"),
            Margin = new(0, 0, 0, 12)
        };
        top.Children.Add(new TextBlock { Text = "图像", FontSize = 15, Foreground = Brushes.LightGray, Margin = new(12), VerticalAlignment = VerticalAlignment.Center });
        var controls = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8
        };
        controls.Children.Add(MainWindow.Button("−", () => canvas?.ChangeZoom(1 / 1.25), "缩小"));
        controls.Children.Add(zoom);
        controls.Children.Add(MainWindow.Button("适应窗口", () => canvas?.Fit()));
        controls.Children.Add(MainWindow.Button("100%", () => canvas?.Actual()));
        controls.Children.Add(MainWindow.Button("＋", () => canvas?.ChangeZoom(1.25), "放大"));
        controls.Children.Add(MainWindow.Button("↓", () =>
        {
            if (asset != null)
                _ = window.Export(asset, message =>
                {
                    if (!disposed)
                        error.Content = MainWindow.Error(message);
                });
        }, "下载图片"));
        controls.Children.Add(MainWindow.Button("×", () => state.CloseWorkspace(session.ID), "关闭图片工作区"));
        Grid.SetColumn(controls, 1);
        top.Children.Add(controls);
        layout.Children.Add(top);
        try
        {
            asset = state.EditorAsset(session.Target.AssetID, session.Target.ConversationID);
            var pixels = PixelImage.Decode(File.ReadAllBytes(state.Store.AssetPath(asset)));
            var saved = state.GetEditorDraft(session.Target);
            selection = saved != null && saved.Selection.Width == pixels.Width && saved.Selection.Height == pixels.Height ? saved.Selection.Clone() : new(pixels.Width, pixels.Height);
            prompt.Text = saved?.Prompt ?? "";
            tool = saved?.Tool ?? EditorTool.Pan;
            canvas = new(pixels, selection)
            {
                Tool = tool
            };
            canvas.SelectionChanged += () =>
            {
                Retain();
                UpdateSubmit();
            };
            canvas.ZoomChanged += v => zoom.Text = $"{Math.Round(v * 100)}%";
            canvas.OnEscape = () => state.CloseWorkspace(session.ID);
            Grid.SetRow(canvas, 1);
            layout.Children.Add(canvas);
        }
        catch (Exception e)
        {
            error.Content = MainWindow.Error(e.Message);
            var missing = new TextBlock
            {
                Text = "图片不可用",
                FontSize = 24,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center
            };
            Grid.SetRow(missing, 1);
            layout.Children.Add(missing);
        }

        var bottom = new StackPanel
        {
            Spacing = 12,
            HorizontalAlignment = HorizontalAlignment.Center,
            MaxWidth = 780
        };
        Grid.SetRow(bottom, 2);
        layout.Children.Add(bottom);
        actions.Children.Add(MainWindow.Button("✎ 标注", () =>
        {
            SetTool(EditorTool.Pen);
            prompt.Focus();
        }));
        actions.Children.Add(MainWindow.Button("▧ 添加评论", () =>
        {
            if (state.Workspace?.ID != session.ID || asset == null)
                return;
            if (state.UseReference(asset))
                state.CloseWorkspace(session.ID);
            else
                error.Content = MainWindow.Error(state.Error ?? "不能添加参考图。");
        }));
        actions.Children.Add(MainWindow.Button("⌫ 擦除", () =>
        {
            SetTool(EditorTool.Pen);
            const string instruction = "移除选中的内容，并自然补全背景，保持其余部分不变。";
            if (string.IsNullOrWhiteSpace(prompt.Text))
                prompt.Text = instruction;
            else if (!prompt.Text.Contains(instruction, StringComparison.Ordinal))
                prompt.Text += "\n" + instruction;
            prompt.Focus();
        }));
        bottom.Children.Add(new Border { Child = actions, Padding = new(18, 12), CornerRadius = new(15), Background = new SolidColorBrush(Color.Parse("#242524")) });
        var edit = new StackPanel
        {
            Spacing = 10
        };
        edit.Children.Add(error);
        if (asset?.ModelWarning != null)
            edit.Children.Add(MainWindow.Error(asset.ModelWarning));
        if (state.GetEditorFailure(session.Target) is { } failed)
        {
            if (failed.Error != null)
                error.Content = MainWindow.Error(failed.Error);
            if (failed.RecoveryRelativePath != null)
                edit.Children.Add(MainWindow.Button("查看已保留的结果…", () => window.Guard(() =>
                {
                    if (state.Store.RecoveryPath(failed) is { } path)
                        window.OpenPath(path);
                })));
        }

        foreach (var t in Enum.GetValues<EditorTool>())
        {
            var b = MainWindow.Button(t switch
            {
                EditorTool.Pan => "平移",
                EditorTool.Pen => "钢笔圈选",
                _ => "方框"
            }, () => SetTool(t));
            toolBar.Children.Add(b);
            toolButtons.Add(b);
        }

        toolBar.Children.Add(MainWindow.Button("↶", () =>
        {
            selection?.Undo();
            canvas?.InvalidateVisual();
            Retain();
            UpdateSubmit();
        }, "撤销选区"));
        toolBar.Children.Add(MainWindow.Button("清空", () =>
        {
            selection?.Clear();
            canvas?.InvalidateVisual();
            Retain();
            UpdateSubmit();
        }));
        edit.Children.Add(toolBar);
        var row = new Grid
        {
            ColumnDefinitions = new("*,Auto"),
            ColumnSpacing = 12
        };
        row.Children.Add(prompt);
        Grid.SetColumn(submit, 1);
        row.Children.Add(submit);
        edit.Children.Add(row);
        bottom.Children.Add(new Border { Child = edit, Padding = new(16), CornerRadius = new(16), MinWidth = 680, Background = new SolidColorBrush(Color.Parse("#242524")) });
        submit.Click += async (_, _) => await Submit();
        prompt.TextChanged += (_, _) =>
        {
            Retain();
            UpdateSubmit();
        };
        prompt.AddHandler(KeyDownEvent, async (_, e) =>
        {
            if (e.Key == Key.Enter && e.KeyModifiers.HasFlag(KeyModifiers.Control) && !prompt.GetVisualDescendants().OfType<TextPresenter>().Any(p => !string.IsNullOrEmpty(p.PreeditText)))
            {
                e.Handled = true;
                await Submit();
            }
        }, handledEventsToo: true);
        KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape)
            {
                state.CloseWorkspace(session.ID);
                e.Handled = true;
            }
        };
        loaded = true;
        SetTool(tool);
        UpdateSubmit();
        state.Changed += RefreshSubmit;
    }

    public void FocusPrompt() => Dispatcher.UIThread.Post(() =>
    {
        if (!disposed)
            prompt.Focus();
    });
    void Retain()
    {
        if (!loaded || disposed || selection == null)
            return;
        state.RetainEditorDraft(Session.Target, new(selection, prompt.Text ?? "", tool), Session.ID);
    }

    void SetTool(EditorTool value)
    {
        tool = value;
        if (canvas != null)
        {
            canvas.Tool = value;
            canvas.CancelGesture();
        }

        toolBar.IsVisible = value != EditorTool.Pan;
        for (int i = 0; i < toolButtons.Count; i++)
            toolButtons[i].FontWeight = (int)value == i ? FontWeight.Bold : FontWeight.Normal;
        Retain();
    }

    void UpdateSubmit() => submit.IsEnabled = selection != null && !selection.IsEmpty && !string.IsNullOrWhiteSpace(prompt.Text) && !state.IsBusy && !state.IsConnecting && state.HasConnection;
    void RefreshSubmit()
    {
        if (disposed)
            return;
        if (!Dispatcher.UIThread.CheckAccess())
        {
            Dispatcher.UIThread.Post(RefreshSubmit);
            return;
        }
        UpdateSubmit();
    }
    async Task Submit()
    {
        if (!submit.IsEnabled || selection == null || state.Workspace?.ID != Session.ID)
            return;
        Retain();
        submit.IsEnabled = false;
        prompt.IsEnabled = false;
        actions.IsEnabled = false;
        toolBar.IsEnabled = false;
        if (canvas != null)
            canvas.SelectionEnabled = false;
        try
        {
            var result = await state.SubmitRegion(Session.ID, new(selection.Clone(), prompt.Text ?? "", tool));
            if (!disposed && result?.Run.Stage != RunStage.Completed)
                error.Content = MainWindow.Error(result?.Run.Error ?? state.Error ?? "局部编辑未完成，选区与要求已保留。");
        }
        catch (Exception e)
        {
            if (!disposed)
                error.Content = MainWindow.Error(e.Message);
        }
        finally
        {
            if (!disposed)
            {
                prompt.IsEnabled = true;
                actions.IsEnabled = true;
                toolBar.IsEnabled = true;
                if (canvas != null)
                    canvas.SelectionEnabled = true;
                UpdateSubmit();
            }
        }
    }

    public void Dispose()
    {
        disposed = true;
        state.Changed -= RefreshSubmit;
        canvas?.Dispose();
    }
}

public sealed class RegionCanvas : Control, IDisposable
{
    readonly PixelImage image;
    readonly Bitmap bitmap;
    readonly RegionSelection selection;
    readonly List<ImagePoint> stroke = [];
    ImagePoint? start, current;
    Point lastPoint;
    bool dragging, panning, space, fit = true;
    Vector pan;
    double scale = 1;
    double? pinchStart;
    public EditorTool Tool
    {
        get; set;
    }
    public bool SelectionEnabled { get; set; } = true;

    public event Action? SelectionChanged;
    public event Action<double>? ZoomChanged;
    public Action? OnEscape;
    public RegionCanvas(PixelImage image, RegionSelection selection)
    {
        this.image = image;
        this.selection = selection;
        using var data = new MemoryStream(image.PngData());
        bitmap = new Bitmap(data);
        Focusable = true;
        ClipToBounds = true;
        Cursor = new(StandardCursorType.Hand);
        GestureRecognizers.Add(new PinchGestureRecognizer());
        AddHandler(PinchEvent, (_, e) =>
        {
            pinchStart ??= scale;
            SetZoom(pinchStart.Value * e.Scale, e.ScaleOrigin);
            e.Handled = true;
        });
        AddHandler(PinchEndedEvent, (_, _) => pinchStart = null);
        PointerTouchPadGestureMagnify += (_, e) =>
        {
            SetZoom(scale * Math.Exp(e.Delta.Y != 0 ? e.Delta.Y : e.Delta.X), e.GetPosition(this));
            e.Handled = true;
        };
        SizeChanged += (_, _) =>
        {
            if (fit)
                Fit();
        };
    }

    Point Origin => new((Bounds.Width - image.Width * scale) / 2 + pan.X, (Bounds.Height - image.Height * scale) / 2 + pan.Y);

    Point View(ImagePoint p) => new(Origin.X + p.X * scale, Origin.Y + p.Y * scale);
    ImagePoint Source(Point p) => new((p.X - Origin.X) / scale, (p.Y - Origin.Y) / scale);
    public void Fit()
    {
        fit = true;
        pan = default;
        scale = Math.Max(.001, Math.Min(Bounds.Width / image.Width, Bounds.Height / image.Height) * .97);
        ZoomChanged?.Invoke(scale);
        InvalidateVisual();
    }

    public void Actual()
    {
        fit = false;
        pan = default;
        SetZoom(1, new(Bounds.Width / 2, Bounds.Height / 2));
    }

    public void ChangeZoom(double factor) => SetZoom(scale * factor, new(Bounds.Width / 2, Bounds.Height / 2));
    void SetZoom(double target, Point center)
    {
        var point = Source(center);
        scale = Math.Clamp(target, .001, 16);
        fit = false;
        pan = new(center.X - (Bounds.Width - image.Width * scale) / 2 - point.X * scale, center.Y - (Bounds.Height - image.Height * scale) / 2 - point.Y * scale);
        ZoomChanged?.Invoke(scale);
        InvalidateVisual();
    }

    public override void Render(DrawingContext context)
    {
        base.Render(context);
        using var clip = context.PushClip(new Rect(Bounds.Size));
        var origin = Origin;
        var destination = new Rect(origin.X, origin.Y, image.Width * scale, image.Height * scale);
        var visible = destination.Intersect(new Rect(Bounds.Size));
        context.FillRectangle(new SolidColorBrush(Color.Parse("#3c3c3c")), visible);
        var checker = new SolidColorBrush(Color.Parse("#515151"));
        for (int y = (int)Math.Floor(visible.Y / 12); y < Math.Ceiling(visible.Bottom / 12); y++)
            for (int x = (int)Math.Floor(visible.X / 12); x < Math.Ceiling(visible.Right / 12); x++)
                if ((x + y) % 2 == 0)
                    context.FillRectangle(checker, new Rect(x * 12, y * 12, 12, 12).Intersect(visible));
        context.DrawImage(bitmap, destination);
        var pen = new Pen(Brushes.Red, 2, lineCap: PenLineCap.Round, lineJoin: PenLineJoin.Round);
        void Outline(string kind, ImagePoint[] p, bool closed = true)
        {
            if (p.Length < 2)
                return;
            if (kind == "rectangle")
            {
                var a = View(p[0]);
                var b = View(p[1]);
                context.DrawRectangle(null, pen, new Rect(new Point(Math.Min(a.X, b.X), Math.Min(a.Y, b.Y)), new Size(Math.Abs(a.X - b.X), Math.Abs(a.Y - b.Y))));
            }
            else
            {
                var geometry = new StreamGeometry();
                using (var path = geometry.Open())
                {
                    path.BeginFigure(View(p[0]), false);
                    foreach (var pt in p.Skip(1))
                        path.LineTo(View(pt));
                    path.EndFigure(closed);
                }

                context.DrawGeometry(null, pen, geometry);
            }
        }

        foreach (var m in selection.Marks.Where(m => m.Kind is "rectangle" or "pen"))
            Outline(m.Kind, m.Points);
        if (Tool == EditorTool.Rectangle && start != null && current != null)
            Outline("rectangle", [start.Value, current.Value]);
        else if (Tool == EditorTool.Pen && stroke.Count > 1)
            Outline("pen", stroke.ToArray(), false);
    }

    public void CancelGesture()
    {
        dragging = false;
        panning = false;
        start = current = null;
        stroke.Clear();
        InvalidateVisual();
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        if (!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed)
            return;
        Focus();
        lastPoint = e.GetPosition(this);
        dragging = true;
        panning = Tool == EditorTool.Pan || space || !SelectionEnabled;
        if (!panning)
        {
            start = current = Source(lastPoint);
            if (Tool == EditorTool.Pen)
                stroke.Add(start.Value);
        }

        e.Pointer.Capture(this);
        e.Handled = true;
        InvalidateVisual();
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        Cursor = new(space || Tool == EditorTool.Pan ? StandardCursorType.Hand : StandardCursorType.Cross);
        if (!dragging)
            return;
        var p = e.GetPosition(this);
        if (panning)
        {
            fit = false;
            pan += p - lastPoint;
            lastPoint = p;
        }
        else
        {
            current = Source(p);
            if (Tool == EditorTool.Pen && (stroke.Count == 0 || stroke[^1] != current.Value) && stroke.Count < 100000)
                stroke.Add(current.Value);
        }

        e.Handled = true;
        InvalidateVisual();
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        base.OnPointerReleased(e);
        if (!dragging)
            return;
        if (!panning && SelectionEnabled && start != null)
        {
            try
            {
                var end = Source(e.GetPosition(this));
                if (Tool == EditorTool.Rectangle)
                    selection.AddRectangle(start.Value, end);
                else if (Tool == EditorTool.Pen)
                {
                    if (stroke.Count == 0 || stroke[^1] != end)
                        stroke.Add(end);
                    selection.AddPen(stroke);
                }

                SelectionChanged?.Invoke();
            }
            catch (AgentException)
            {
            }
        }

        e.Pointer.Capture(null);
        CancelGesture();
        e.Handled = true;
    }

    protected override void OnPointerCaptureLost(PointerCaptureLostEventArgs e)
    {
        base.OnPointerCaptureLost(e);
        CancelGesture();
    }

    protected override void OnPointerWheelChanged(PointerWheelEventArgs e)
    {
        base.OnPointerWheelChanged(e);
        if (e.KeyModifiers.HasFlag(KeyModifiers.Control) || e.KeyModifiers.HasFlag(KeyModifiers.Alt))
            SetZoom(scale * Math.Exp(e.Delta.Y * .15), e.GetPosition(this));
        else
        {
            fit = false;
            pan += new Vector(e.Delta.X * 36, e.Delta.Y * 36);
            InvalidateVisual();
        }

        e.Handled = true;
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (e.Key == Key.Space)
        {
            space = true;
            e.Handled = true;
        }
        else if (e.Key == Key.Escape)
        {
            OnEscape?.Invoke();
            e.Handled = true;
        }
        else if (SelectionEnabled && e.Key == Key.Z && e.KeyModifiers.HasFlag(KeyModifiers.Control))
        {
            selection.Undo();
            SelectionChanged?.Invoke();
            InvalidateVisual();
            e.Handled = true;
        }
    }

    protected override void OnKeyUp(KeyEventArgs e)
    {
        base.OnKeyUp(e);
        if (e.Key == Key.Space)
        {
            space = false;
            e.Handled = true;
        }
    }

    public void Dispose() => bitmap.Dispose();
}
