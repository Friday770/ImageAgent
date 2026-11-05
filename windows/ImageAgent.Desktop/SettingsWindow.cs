using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using ImageAgent.Core;

namespace ImageAgent.Desktop;
public sealed class SettingsWindow : Window
{
    readonly WorkspaceState state;
    readonly ConnectionDraft draft;
    readonly TextBox address = new();
    readonly TextBox key = new()
    {
        PasswordChar = '●',
        PlaceholderText = "输入 API Key"
    };
    readonly AutoCompleteBox planner = new()
    {
        MinimumPrefixLength = 0,
        FilterMode = AutoCompleteFilterMode.None,
        IsTextCompletionEnabled = false
    };
    readonly ContentControl error = new();
    readonly SelectableTextBlock currentConnection = new();
    readonly TextBlock note = new()
    {
        TextWrapping = TextWrapping.Wrap
    };
    readonly StackPanel connection = new()
    {
        Spacing = 12
    };
    readonly Button dropdown = new()
    {
        Content = "⌄"
    };
    readonly Button refresh = new()
    {
        Content = "↻"
    };
    readonly Button reveal = new()
    {
        Content = "显示"
    };
    readonly Button save = new()
    {
        Content = "验证并保存"
    };
    readonly Button reset = new()
    {
        Content = "取消编辑"
    };
    readonly Button disconnect = new()
    {
        Content = "断开并移除 Key"
    };
    bool updating;
    bool attempted;
    readonly MainWindow owner;
    public SettingsWindow(MainWindow owner, WorkspaceState state)
    {
        this.owner = owner;
        this.state = state;
        draft = new(state);
        Title = "ImageAgent · 设置";
        Width = 690;
        Height = 740;
        MinWidth = 600;
        MinHeight = 600;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var frame = new Grid
        {
            RowDefinitions = new("Auto,*")
        };
        Content = frame;
        var top = new Grid
        {
            ColumnDefinitions = new("*,Auto"),
            Margin = new(24, 18)
        };
        top.Children.Add(new TextBlock { Text = "设置", FontSize = 25, FontWeight = FontWeight.SemiBold });
        var done = MainWindow.Button("完成", () =>
        {
            if (!state.IsConnecting)
                Close();
        });
        Grid.SetColumn(done, 1);
        top.Children.Add(done);
        frame.Children.Add(top);
        var form = new StackPanel
        {
            Spacing = 22,
            Margin = new(24, 8, 24, 24)
        };
        var scroll = new ScrollViewer
        {
            Content = form
        };
        Grid.SetRow(scroll, 1);
        frame.Children.Add(scroll);
        connection.Children.Add(new TextBlock { Text = "API 连接", FontSize = 18, FontWeight = FontWeight.SemiBold });
        connection.Children.Add(MainWindow.Label("API URL"));
        address.Text = draft.Address;
        connection.Children.Add(address);
        connection.Children.Add(MainWindow.Label("API Key"));
        var keys = new Grid
        {
            ColumnDefinitions = new("*,Auto"),
            ColumnSpacing = 8
        };
        keys.Children.Add(key);
        Grid.SetColumn(reveal, 1);
        keys.Children.Add(reveal);
        connection.Children.Add(keys);
        connection.Children.Add(currentConnection);
        AutomationProperties.SetName(currentConnection, "当前连接");
        connection.Children.Add(MainWindow.Label("规划模型"));
        planner.Text = draft.Value;
        planner.ItemsSource = draft.Options;
        var models = new Grid
        {
            ColumnDefinitions = new("*,Auto,Auto"),
            ColumnSpacing = 8
        };
        models.Children.Add(planner);
        Grid.SetColumn(dropdown, 1);
        models.Children.Add(dropdown);
        Grid.SetColumn(refresh, 2);
        models.Children.Add(refresh);
        connection.Children.Add(models);
        connection.Children.Add(error);
        connection.Children.Add(note);
        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8
        };
        actions.Children.Add(save);
        actions.Children.Add(reset);
        actions.Children.Add(disconnect);
        connection.Children.Add(actions);
        form.Children.Add(connection);
        var memory = new StackPanel
        {
            Spacing = 12
        };
        memory.Children.Add(new TextBlock { Text = "当前会话的短期记忆", FontSize = 18, FontWeight = FontWeight.SemiBold });
        var hours = new NumericUpDown
        {
            Minimum = 1,
            Maximum = 720,
            Value = state.Settings.Memory.Hours,
            Increment = 1,
            FormatString = "0"
        };
        var turns = new NumericUpDown
        {
            Minimum = 1,
            Maximum = 100,
            Value = state.Settings.Memory.Turns,
            Increment = 1,
            FormatString = "0"
        };
        memory.Children.Add(MainWindow.Label("时间窗口（小时）"));
        memory.Children.Add(hours);
        memory.Children.Add(MainWindow.Label("最多轮数"));
        memory.Children.Add(turns);
        var memoryNote = MainWindow.Label("", 12);
        var clear = MainWindow.Button("清空当前会话记忆", () =>
        {
            state.ResetMemory();
            memoryNote.Text = "记忆已清空，历史已保留";
        });
        memory.Children.Add(clear);
        memory.Children.Add(memoryNote);
        form.Children.Add(memory);
        var files = new StackPanel
        {
            Spacing = 12
        };
        files.Children.Add(new TextBlock { Text = "本地数据", FontSize = 18, FontWeight = FontWeight.SemiBold });
        files.Children.Add(MainWindow.Selectable(state.Store.Paths.Root));
        files.Children.Add(MainWindow.Button("在文件资源管理器中打开", () => owner.OpenPath(state.Store.Paths.Root)));
        form.Children.Add(files);
        AutomationProperties.SetName(address, "API URL");
        AutomationProperties.SetName(key, "API Key");
        AutomationProperties.SetName(planner, "规划模型，可手动输入");
        AutomationProperties.SetName(refresh, "刷新规划模型");
        AutomationProperties.SetName(dropdown, "选择规划模型");
        dropdown.Click += (_, _) =>
        {
            planner.Focus();
            planner.IsDropDownOpen = !planner.IsDropDownOpen;
        };
        AutomationProperties.SetName(reveal, "显示或隐藏 API Key");
        address.TextChanged += (_, _) =>
        {
            if (updating || draft.Address == (address.Text ?? ""))
                return;
            draft.Address = address.Text ?? "";
            updating = true;
            key.Text = "";
            key.PasswordChar = '●';
            reveal.Content = "显示";
            updating = false;
            Update();
        };
        key.TextChanged += (_, _) =>
        {
            if (!updating && draft.Key != (key.Text ?? ""))
                draft.Key = key.Text ?? "";
        };
        planner.PropertyChanged += (_, e) =>
        {
            if (!updating && e.Property == AutoCompleteBox.TextProperty)
                draft.Value = planner.Text ?? "";
        };
        reveal.Click += (_, _) =>
        {
            draft.Revealed = !draft.Revealed;
            key.PasswordChar = draft.Revealed ? '\0' : '●';
            reveal.Content = draft.Revealed ? "隐藏" : "显示";
        };
        refresh.Click += async (_, _) => await draft.Refresh();
        save.Click += async (_, _) =>
        {
            attempted = true;
            draft.Value = planner.Text ?? "";
            if (await state.SaveConnection(draft.Address, draft.Key, draft.Value))
            {
                await draft.Reset();
                SyncFields();
            }

            Update();
        };
        reset.Click += async (_, _) =>
        {
            attempted = false;
            await draft.Reset();
            SyncFields();
            Update();
        };
        disconnect.Click += async (_, _) =>
        {
            await state.Disconnect();
            Close();
        };
        hours.ValueChanged += (_, _) =>
        {
            if (hours.Value is { } value)
                owner.Guard(() => state.SetMemory(state.Settings.Memory with { Hours = (int)value }));
        };
        turns.ValueChanged += (_, _) =>
        {
            if (turns.Value is { } value)
                owner.Guard(() => state.SetMemory(state.Settings.Memory with { Turns = (int)value }));
        };
        draft.Changed += DraftChanged;
        state.Changed += StateChanged;
        Opened += async (_, _) =>
        {
            await draft.LoadKey();
            SyncFields();
            if (draft.Key.Length > 0 && !state.IsBusy && !state.IsConnecting)
                await draft.Refresh();
        };
        Closing += (_, e) =>
        {
            if (state.IsConnecting)
                e.Cancel = true;
        };
        Closed += (_, _) =>
        {
            state.Changed -= StateChanged;
            draft.Changed -= DraftChanged;
            draft.Close();
        };
        void StateChanged()
        {
            Update();
            clear.IsEnabled = !state.IsBusy && state.SelectedID != null;
            done.IsEnabled = !state.IsConnecting;
        }

        void DraftChanged() => Update();
        Update();
    }

    void SyncFields()
    {
        updating = true;
        address.Text = draft.Address;
        key.Text = draft.Key;
        key.PasswordChar = '●';
        reveal.Content = "显示";
        planner.Text = draft.Value;
        updating = false;
    }

    void Update()
    {
        currentConnection.Text = "当前连接：" + state.Settings.Endpoint;
        bool disabled = state.IsBusy || state.IsConnecting;
        address.IsEnabled = !disabled;
        key.IsEnabled = !disabled;
        reveal.IsEnabled = !disabled && draft.Key.Length > 0;
        planner.IsEnabled = !disabled;
        dropdown.IsEnabled = !disabled;
        refresh.IsEnabled = !disabled && !draft.IsLoading;
        save.IsEnabled = !disabled;
        reset.IsEnabled = !disabled;
        disconnect.IsEnabled = !disabled;
        var current = planner.Text;
        updating = true;
        planner.ItemsSource = draft.Options;
        planner.Text = current;
        updating = false;
        var message = draft.Error ?? (attempted ? state.ConnectionError : null);
        error.Content = message == null ? null : MainWindow.Error(message);
        note.Text = state.IsConnecting ? state.ConnectionNote : state.IsBusy ? "当前任务结束后可更改连接。" : attempted ? state.ConnectionNote : "";
    }
}
