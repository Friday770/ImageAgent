using SkiaSharp;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ImageAgent.Core;
public record LaunchOptions(string Mode, string? Session, string? SelfTestOutput, bool ConfigureEnvironment)
{
    public bool IsOffline => Mode != "normal";

    public static LaunchOptions Parse(string[] args, string baseDirectory)
    {
        string? Value(string flag)
        {
            var i = Array.IndexOf(args, flag);
            if (i < 0)
                return null;
            if (i + 1 >= args.Length || args[i + 1].StartsWith("--", StringComparison.Ordinal))
                throw new AgentException("缺少参数 " + flag);
            return args[i + 1];
        }

        var mode = new[]
        {
            "frontend",
            "connection",
            "streaming",
            "demo"
        }.FirstOrDefault(v => args.Contains(v == "demo" ? "--demo" : "--" + v + "-demo")) ?? "normal";
        var session = Value("--frontend-demo-session") ?? Value("--streaming-demo-session") ?? Value("--connection-demo-session") ?? Value("--demo-session");
        var preview = Path.Combine(baseDirectory, "ImageAgent.preview.json");
        if (mode == "normal" && File.Exists(preview))
        {
            var json = SwiftJson.Parse(File.ReadAllText(preview));
            session = json.Str("demoSession") ?? throw new AgentException("预览缺少命名 session。");
            mode = json.Str("mode") ?? "frontend";
            if (mode is not ("frontend" or "connection" or "streaming" or "demo"))
                throw new AgentException("预览模式无效。");
        }

        if (session != null && !Regex.IsMatch(session, "^[A-Za-z0-9_-]{1,80}$"))
            throw new AgentException("离线演示 session 名称无效。");
        if (mode != "normal")
            session ??= Guid.NewGuid().ToString();
        var test = args.Contains("--self-test") ? Value("--output") ?? throw new AgentException("自检需要 --output <私有目录>。") : null;
        if (args.Contains("--configure-from-environment") && mode != "normal")
            throw new AgentException("离线模式不读取环境凭据。");
        return new(mode, session, test, args.Contains("--configure-from-environment"));
    }

    public string DataRoot()
    {
        if (IsOffline)
            return Path.Combine(Path.GetTempPath(), "ImageAgentWindowsDemo-" + Session);
        if (!OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException("正常模式仅限 Windows。当前平台请显式使用 --frontend-demo --frontend-demo-session <名称>。");
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ImageAgent");
    }
}

public sealed class OfflineTransport : IHTTPTransport
{
    public int ResponseCalls { get; private set; }
    public int ImageCalls { get; private set; }
    public int ModelCalls { get; private set; }
    public bool Slow { get; set; } = true;
    public byte[] Image { get; } = OfflineData.Image();

    public Task<HTTPResponse> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var path = request.RequestUri!.AbsolutePath;
        if (request.RequestUri.Host == "offline-network-failure.invalid")
            throw new IOException("离线模拟网络失败");
        if (path.EndsWith("/models", StringComparison.Ordinal))
        {
            ModelCalls++;
            if (request.Headers.Authorization?.Parameter == "fail")
                return Task.FromResult(new HTTPResponse(Encoding.UTF8.GetBytes("{\"error\":{\"message\":\"离线模拟：Key 验证失败\"}}"), 401));
            var ids = new[]
            {
                PlannerModel.Default,
                "gpt-6-sol",
                "custom-planner"
            }.Concat(ImageModels.All);
            return Task.FromResult(new HTTPResponse(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { data = ids.Select(id => new { id }) })), 200));
        }

        if (path.EndsWith("/images/generations", StringComparison.Ordinal) || path.EndsWith("/images/edits", StringComparison.Ordinal))
        {
            ImageCalls++;
            return Task.FromResult(new HTTPResponse(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { data = new[] { new { b64_json = Convert.ToBase64String(Image) } } })), 200));
        }

        throw new AgentException("离线演示禁止这个端点；没有访问网络。");
    }

    public async Task StreamAsync(HttpRequestMessage request, Action<HTTPStreamEvent> receive, CancellationToken ct)
    {
        if (!request.RequestUri!.AbsolutePath.EndsWith("/responses", StringComparison.Ordinal))
            throw new AgentException("离线演示只接受模拟规划。");
        ResponseCalls++;
        var j = SwiftJson.Parse(await request.Content!.ReadAsStringAsync(ct));
        var props = j.Get("tools").Array()[0].Get("parameters").Get("properties");
        string Choice(string key) => props.Get(key).Get("enum").Array()[0].GetString()!;
        var input = j.Get("input").Array();
        var system = input.FirstOrDefault().Str("content") ?? "";
        var text = input.LastOrDefault().Str("content") ?? "";
        var match = Regex.Match(system, "主动选定的参考图：([^。]+)。");
        var reference = match.Success && !match.Groups[1].Value.StartsWith('无') ? match.Groups[1].Value : null;
        bool reply = text.Contains("讨论", StringComparison.Ordinal) && reference == null;
        var prompt = reply ? "" : "一幅极简、温暖的山间湖泊插画。远山层叠，清晨的光从画面右上方落下，赭红色小屋坐落在岸边，深绿色松树与薄雾构成宁静的留白。保留原始构图和未选中的区域。\n用户要求：" + text;
        var args = JsonSerializer.Serialize(new { prompt, action = reply ? "reply" : reference == null ? "generate" : "edit", model = Choice("model"), size = Choice("size"), quality = Choice("quality"), reference_image_id = reference, reply_text = "离线模拟完成，没有访问网络或系统凭据。" });
        object Item(string arguments) => new
        {
            type = "function_call",
            id = "offline_item",
            call_id = "offline_call",
            name = "prepare_image_request",
            arguments
        };
        byte[] Event(string type, object fields)
        {
            var values = JsonSerializer.SerializeToElement(fields).EnumerateObject().ToDictionary(p => p.Name, p => (object)p.Value);
            values["type"] = type;
            return Encoding.UTF8.GetBytes("data: " + JsonSerializer.Serialize(values) + "\n\n");
        }

        receive(new(200, "text/event-stream"));
        if (text.Contains("[native]", StringComparison.Ordinal))
        {
            receive(new(Bytes: Event("response.completed", new { response = new { status = "completed", output = new[] { new { type = "image_generation_call", id = "native", result = Convert.ToBase64String(Image) } } } })));
            return;
        }

        receive(new(Bytes: Event("response.output_item.added", new { output_index = 0, item = Item("") })));
        int chunks = 0;
        foreach (var fragment in args.Chunk(65))
        {
            ct.ThrowIfCancellationRequested();
            if (Slow)
                await Task.Delay(160, ct);
            receive(new(Bytes: Event("response.function_call_arguments.delta", new { output_index = 0, item_id = "offline_item", delta = new string (fragment) })));
            if (++chunks == 9 && text.Contains("[interrupt]", StringComparison.Ordinal))
                throw new IOException("离线模拟：流中断");
        }

        receive(new(Bytes: Event("response.completed", new { response = new { status = "completed", output = new[] { Item(args) } } })));
        receive(new(Bytes: Encoding.UTF8.GetBytes("data: [DONE]\n\n")));
    }
}

public static class OfflineData
{
    public static byte[] Image()
    {
        using var b = new SKBitmap(new SKImageInfo(1024, 1024, SKColorType.Rgba8888, SKAlphaType.Premul));
        using var c = new SKCanvas(b);
        c.Clear(new(240, 224, 189));
        using var p = new SKPaint
        {
            IsAntialias = true
        };
        p.Color = new(250, 202, 122);
        c.DrawCircle(771, 243, 71, p);
        void Polygon(SKColor color, params float[] xy)
        {
            using var path = new SKPath();
            path.MoveTo(xy[0], xy[1]);
            for (int i = 2; i < xy.Length; i += 2)
                path.LineTo(xy[i], xy[i + 1]);
            path.Close();
            p.Color = color;
            c.DrawPath(path, p);
        }

        Polygon(new(151, 171, 148), 0, 624, 0, 434, 210, 224, 430, 464, 640, 274, 1024, 554, 1024, 724);
        Polygon(new(82, 125, 107), 0, 674, 0, 574, 340, 354, 600, 554, 850, 404, 1024, 604, 1024, 774);
        p.Color = new(138, 176, 156);
        c.DrawRect(0, 674, 1024, 350, p);
        Polygon(new(46, 89, 74), 0, 1024, 0, 774, 230, 694, 440, 754, 680, 764, 1024, 874, 1024, 1024);
        p.Color = new(199, 107, 66);
        c.DrawRect(560, 629, 180, 110, p);
        Polygon(new(71, 74, 59), 540, 629, 650, 539, 760, 629);
        p.Color = new(252, 212, 133);
        c.DrawRect(585, 661, 36, 43, p);
        foreach (var(x, y, h)in new[]
        {
            (130f, 854f, 280f),
            (230f, 834f, 190f),
            (850f, 924f, 320f)
        }

        )
            Polygon(new(31, 71, 59), x - 60, y, x, y - h, x + 60, y);
        using var i = SKImage.FromBitmap(b);
        using var png = i.Encode(SKEncodedImageFormat.Png, 100);
        return png.ToArray();
    }

    public static void Seed(SQLiteStore s)
    {
        if (s.Conversations().Count > 0)
            return;
        var now = DateTimeOffset.UtcNow;
        var c = s.CreateConversation("山间的一日 · 创作练习", now.AddMinutes(-15));
        s.CreateConversation("咖啡品牌视觉", now.AddHours(-1));
        s.CreateConversation("一些还没成形的想法", now.AddHours(-2));
        s.AddMessage(new() { ConversationID = c.ID, Role = MessageRole.User, Text = "想要一张安静的山间湖泊插画。暖一点的晨光，有一间小屋，像周末醒来的感觉。", CreatedAt = now.AddMinutes(-14) });
        var prompt = "一幅温暖的山间湖泊插画，层叠远山、赭红色小屋、深绿松树与清晨柔光。";
        var a = s.SaveImage(Image(), c.ID, AssetSource.Generated, prompt: prompt, selection: new(), now: now.AddMinutes(-13));
        s.AddMessage(new() { ConversationID = c.ID, Role = MessageRole.Assistant, Text = "把清晨留在了这片湖边。暖色天空、层叠的远山和一间临水小屋，让画面有一点慢下来的感觉。\n\n可以继续调整光线、色彩，或选这张图作为参考。", AssetIDs = [a.ID], DetailedPrompt = prompt, CreatedAt = now.AddMinutes(-12) });
        var run = new RunRecord
        {
            ConversationID = c.ID,
            Stage = RunStage.Cancelled,
            Request = "离线示例：让晨光更温暖一些。",
            CreatedAt = now.AddMinutes(-11),
            UpdatedAt = now.AddMinutes(-10)
        };
        s.SaveRun(run);
        s.AddMessage(new() { ConversationID = c.ID, Role = MessageRole.User, Text = run.Request, RunID = run.ID, CreatedAt = run.CreatedAt });
        s.AddMessage(new() { ConversationID = c.ID, Role = MessageRole.Assistant, Text = "离线模拟：任务已取消，可以返回编辑。", RunID = run.ID, CreatedAt = run.UpdatedAt });
        var selection = new RegionSelection(1024, 1024);
        selection.AddRectangle(new(540, 540), new(760, 750));
        var region = new RunRecord
        {
            ConversationID = c.ID,
            Stage = RunStage.Cancelled,
            Request = "离线局部示例：只让方框内的小屋变亮。",
            RegionEdit = new(a.ID, selection),
            CreatedAt = now.AddMinutes(-9),
            UpdatedAt = now.AddMinutes(-8)
        };
        s.SaveRun(region);
        s.AddMessage(new() { ConversationID = c.ID, Role = MessageRole.User, Text = region.Request, AssetIDs = [a.ID], RunID = region.ID, CreatedAt = region.CreatedAt });
        s.AddMessage(new() { ConversationID = c.ID, Role = MessageRole.Assistant, Text = "离线模拟：局部任务已取消，原选区可以返回图片工作区。", RunID = region.ID, CreatedAt = region.UpdatedAt });
    }
}

public static class SelfTest
{
    public static async Task<int> Run(string output)
    {
        var full = Path.GetFullPath(output);
        var production = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ImageAgent");
        if (full.StartsWith(Path.GetFullPath(production), StringComparison.OrdinalIgnoreCase))
            throw new AgentException("自检输出必须是独立私有目录。");
        AppPaths.SecureDirectory(full);
        var results = new Dictionary<string, object>();
        var data = Path.Combine(full, "isolated-" + Guid.NewGuid());
        try
        {
            using (var store = new SQLiteStore(new(data)))
            {
                var c = store.CreateConversation("自检");
                var t = new OfflineTransport
                {
                    Slow = false
                };
                var engine = new AgentEngine(store, new APIClient("https://offline.invalid", "synthetic-self-test", transport: t));
                var previews = new List<string>();
                var outcome = await engine.Submit(new(c.ID, "offline self test", new()), planningPreview: p => previews.Add(p.Text));
                if (outcome.Run.Stage != RunStage.Completed || t.ResponseCalls != 1 || t.ImageCalls != 1 || previews.Count < 2)
                    throw new AgentException("流式或调用计数自检失败。");
                results["streaming"] = new
                {
                    passed = true,
                    previewUpdates = previews.Count,
                    plannerCalls = t.ResponseCalls,
                    imageCalls = t.ImageCalls
                };
                var source = PixelImage.Decode(t.Image);
                var selection = new RegionSelection(source.Width, source.Height);
                selection.AddRectangle(new(20.2, 30.4), new(90.8, 95.1));
                var snap = new RegionEditSnapshot(source, selection);
                var patch = PixelImage.Decode(t.Image);
                var composed = PixelImage.Decode(snap.Composite(patch).PngData());
                int outside = 0;
                for (int i = 0; i < snap.Coverage.Length; i++)
                    if (snap.Coverage[i] == 0)
                    {
                        outside++;
                        if (!source.RGBA.AsSpan(i * 4, 4).SequenceEqual(composed.RGBA.AsSpan(i * 4, 4)))
                            throw new AgentException("选区外像素自检失败。");
                    }

                if (!source.ICC.AsSpan().SequenceEqual(composed.ICC))
                    throw new AgentException("ICC 自检失败。");
                results["region"] = new
                {
                    passed = true,
                    outsidePixelsVerified = outside,
                    iccBytes = source.ICC.Length,
                    roi = snap.ROI
                };
                var native = await engine.Submit(new(c.ID, "[native] offline recovery", new()));
                if (native.Assets.Count != 1 || native.Assets[0].ModelVerified != false || t.ImageCalls != 1 || !File.Exists(store.RecoveryPath(native.Run)))
                    throw new AgentException("Responses 恢复自检失败。");
                results["responsesRecovery"] = new
                {
                    passed = true,
                    additionalImageCalls = 0
                };
            }

            using (var reopen = new SQLiteStore(new(data)))
            {
                if (reopen.Conversations().Count != 1 || reopen.Messages(reopen.Conversations()[0].ID).Count != 4)
                    throw new AgentException("数据重开自检失败。");
                results["storageReopen"] = new
                {
                    passed = true
                };
            }

            if (OperatingSystem.IsWindows())
            {
                var credentials = new WindowsCredentials();
                var endpoint = "https://imageagent-self-test-" + Guid.NewGuid().ToString("N") + ".invalid/v1";
                var synthetic = Guid.NewGuid().ToString();
                try
                {
                    credentials.Save(synthetic, endpoint);
                    if (credentials.Key(endpoint) != synthetic)
                        throw new AgentException("Windows 凭据自检失败。");
                    results["windowsCredentialManager"] = new
                    {
                        passed = true,
                        syntheticUniqueTarget = true
                    };
                }
                finally
                {
                    credentials.Delete(endpoint);
                }
            }
            else
                results["windowsCredentialManager"] = new
                {
                    executed = false,
                    reason = "Windows 实机未执行"
                };
            results["passed"] = true;
            results["network"] = new
            {
                realRequests = 0
            };
            results["platform"] = System.Runtime.InteropServices.RuntimeInformation.OSDescription;
            AppPaths.WriteAtomic(Path.Combine(full, "self-test.json"), Encoding.UTF8.GetBytes(JsonSerializer.Serialize(results, new JsonSerializerOptions { WriteIndented = true })));
            return 0;
        }
        catch (Exception e)
        {
            results["passed"] = false;
            results["error"] = e.Message;
            AppPaths.WriteAtomic(Path.Combine(full, "self-test.json"), Encoding.UTF8.GetBytes(JsonSerializer.Serialize(results, new JsonSerializerOptions { WriteIndented = true })));
            return 1;
        }
    }
}
