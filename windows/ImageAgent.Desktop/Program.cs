using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Themes.Fluent;
using Avalonia.Threading;
using ImageAgent.Core;

namespace ImageAgent.Desktop;
internal static class Program
{
    public static LaunchOptions? Options;
    public static string? StartupError;
    public static StartupLease? Lease;
    public static WindowsActivation? Activation;
    [STAThread]
    public static int Main(string[] args)
    {
        try
        {
            Options = LaunchOptions.Parse(args, AppContext.BaseDirectory);
            if (Options.SelfTestOutput != null)
                return SelfTest.Run(Options.SelfTestOutput).GetAwaiter().GetResult();
            _ = Options.DataRoot();
            string? identity = OperatingSystem.IsWindows() && !Options.IsOffline ? WindowsActivation.UserIdentity() : null;
            Lease = new StartupLease(Options, OperatingSystem.IsWindows(), () => new NamedMutexLease(WindowsActivation.MutexName(identity!)), () => WindowsActivation.SignalExisting(identity!));
            if (!Lease.ShouldStart)
            {
                Lease.Dispose();
                return 0;
            }

            if (identity != null)
                Activation = new WindowsActivation(identity);
        }
        catch (Exception e)
        {
            StartupError = e.Message;
        }

        try
        {
            return BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
        }
        finally
        {
            Activation?.Dispose();
            Lease?.Dispose();
        }
    }

    public static AppBuilder BuildAvaloniaApp() => AppBuilder.Configure<App>().UsePlatformDetect().LogToTrace();
}

public sealed class App : Application
{
    SQLiteStore? store;
    HttpClientTransport? realTransport;
    public override void Initialize()
    {
        Name = "ImageAgent";
        Styles.Add(new FluentTheme());
        RequestedThemeVariant = Avalonia.Styling.ThemeVariant.Default;
    }

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime lifetime)
        {
            try
            {
                if (Program.StartupError != null)
                    throw new AgentException(Program.StartupError);
                var options = Program.Options!;
                store = Program.Lease?.Create(() => new SQLiteStore(new(options.DataRoot()))) ?? throw new AgentException("生产实例未取得数据目录所有权。");
                ICredentialStore credentials;
                IHTTPTransport transport;
                if (options.IsOffline)
                {
                    credentials = options.Mode == "connection" ? new MemoryCredentials() : new DemoCredentials(store.Paths.Root);
                    transport = new OfflineTransport();
                    if (options.Mode != "connection")
                        OfflineData.Seed(store);
                }
                else
                {
                    credentials = new WindowsCredentials();
                    transport = realTransport = new();
                }

                var state = new WorkspaceState(store, credentials, transport, a => Dispatcher.UIThread.Post(a));
                var window = new MainWindow(state, options);
                lifetime.MainWindow = window;
                window.Opened += async (_, _) =>
                {
                    if (options.ConfigureEnvironment)
                    {
                        var address = Environment.GetEnvironmentVariable("OPENAI_BASE_URL");
                        var key = Environment.GetEnvironmentVariable("OPENAI_API_KEY");
                        Environment.SetEnvironmentVariable("OPENAI_BASE_URL", null);
                        Environment.SetEnvironmentVariable("OPENAI_API_KEY", null);
                        if (string.IsNullOrEmpty(address) || string.IsNullOrEmpty(key))
                        {
                            state.Error = "环境配置需要 OPENAI_BASE_URL 与 OPENAI_API_KEY；已清除本进程中的这两个变量。";
                            state.Refresh();
                        }
                        else
                            await state.SaveConnection(address, key, state.Settings.PlannerModel);
                    }
                    else if (options.Mode != "connection")
                        await state.RestoreConnection();
                };
                lifetime.Exit += (_, _) =>
                {
                    store.Dispose();
                    realTransport?.Dispose();
                };
            }
            catch (Exception e)
            {
                lifetime.MainWindow = new Window
                {
                    Title = "ImageAgent · 启动错误",
                    Width = 650,
                    Height = 330,
                    Content = new StackPanel
                    {
                        Margin = new(30),
                        Spacing = 20,
                        Children =
                        {
                            new TextBlock
                            {
                                Text = "无法启动 ImageAgent",
                                FontSize = 24
                            },
                            new SelectableTextBlock
                            {
                                Text = e.Message,
                                TextWrapping = Avalonia.Media.TextWrapping.Wrap
                            },
                            new TextBlock
                            {
                                Text = "本地历史保留在原数据目录。请检查目录权限，或使用独立离线 session 运行自检。",
                                TextWrapping = Avalonia.Media.TextWrapping.Wrap
                            }
                        }
                    }
                };
            }
        }

        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime activeLifetime && activeLifetime.MainWindow is { } activeWindow)
            Program.Activation?.Bind(activeWindow);
        base.OnFrameworkInitializationCompleted();
    }
}
