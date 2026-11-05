using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace ImageAgent.Core;
public record DiagnosticEvent(string Name, string Status, string Detail, string[] ImagePaths);
public record DiagnosticReport
{
    public string Application { get; init; } = "ImageAgent 1.5.0";
    public int Build { get; init; } = 8;
    public DateTimeOffset CreatedAt { get; init; } = DateTimeOffset.UtcNow;
    public string Status { get; set; } = "running";
    public string? Endpoint { get; set; }
    public List<DiagnosticEvent> Events { get; init; } = [];
}

public sealed class DiagnosticOptions
{
    readonly Dictionary<string, string> values = [];
    readonly HashSet<string> flags = [];
    public string Output { get; private set; } = "";
    public bool Generate => flags.Contains("--live-generate");
    public bool Edit => flags.Contains("--live-edit");
    public bool LiveRegion => flags.Contains("--live-region");
    public bool Region => flags.Contains("--region") || LiveRegion;
    public bool Streaming => flags.Contains("--streaming");
    public string? Recovery => Value("--recover-response");

    public string? Value(string name) => values.GetValueOrDefault(name);
    public ImageSelection Selection(bool region = false)
    {
        var selection = new ImageSelection
        {
            Model = Value("--model") ?? "gpt-image-2",
            Size = region ? "auto" : Value("--size") ?? "1024x1024",
            Quality = Value("--quality") ?? "low"
        };
        selection.Validate();
        return selection;
    }

    public static DiagnosticOptions Parse(string[] args)
    {
        var result = new DiagnosticOptions();
        string[] switches = ["--live-generate", "--live-edit", "--live-region", "--region", "--streaming", "--local"];
        string[] options = ["--output", "--model", "--size", "--quality", "--reference", "--region-rect", "--prompt", "--edit-prompt", "--recover-response"];
        for (int i = 0; i < args.Length; i++)
        {
            var argument = args[i] == "local" ? "--local" : args[i];
            if (switches.Contains(argument))
            {
                if (!result.flags.Add(argument))
                    throw new AgentException("重复诊断参数：" + argument);
            }
            else if (options.Contains(argument))
            {
                if (++i >= args.Length || !result.values.TryAdd(argument, args[i]))
                    throw new AgentException("缺少或重复诊断参数：" + argument);
            }
            else
                throw new AgentException("未知诊断参数；请使用 --help 查看用法。");
        }

        int modes = (result.Generate || result.Edit ? 1 : 0) + (result.Region ? 1 : 0) + (result.Streaming ? 1 : 0) + (result.Recovery != null ? 1 : 0) + (result.flags.Contains("--local") ? 1 : 0);
        if (modes > 1 || result.flags.Contains("--region") && result.LiveRegion)
            throw new AgentException("请选择一个诊断模式；不会隐式串联另一次图片操作。");
        _ = result.Selection();
        result.Output = Path.GetFullPath(result.Value("--output") ?? Path.Combine("artifacts", "diagnostics-" + Guid.NewGuid()));
        var production = Path.GetFullPath(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ImageAgent"));
        if (result.Output.Equals(production, StringComparison.OrdinalIgnoreCase) || result.Output.StartsWith(production + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new AgentException("诊断必须使用独立输出目录，不能使用生产数据目录。");
        return result;
    }
}

/// The runner accepts an injected live transport/environment for tests; offline modes never read either.
public sealed class DiagnosticRunner
{
    readonly string[] arguments;
    readonly IHTTPTransport? liveTransport;
    readonly Func<string, string?> readEnvironment;
    readonly Action<string> clearEnvironment;
    DiagnosticOptions options = null!;
    SQLiteStore store = null!;
    APIClient? client;
    HttpClientTransport? ownedTransport;
    string? secret;
    bool validatedConnection;
    DiagnosticReport report = new();
    static readonly JsonSerializerOptions ReportJson = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };
    public DiagnosticRunner(string[] args, IHTTPTransport? liveTransport = null, Func<string, string?>? environment = null, Action<string>? clearEnvironment = null)
    {
        arguments = args;
        this.liveTransport = liveTransport;
        readEnvironment = environment ?? Environment.GetEnvironmentVariable;
        this.clearEnvironment = clearEnvironment ?? (name => Environment.SetEnvironmentVariable(name, null));
    }

    public string? OutputDirectory => options?.Output;

    public async Task<DiagnosticReport> Run(CancellationToken ct = default)
    {
        options = DiagnosticOptions.Parse(arguments);
        using var local = new SQLiteStore(new(Path.Combine(options.Output, "data")));
        store = local;
        store.RecoverInterruptedRuns();
        report = new();
        try
        {
            if (!ImageModels.All.SequenceEqual(new[] { "gpt-image-2", "gpt-image-2.5-flare", "gpt-image-2.5", "gpt-image-2.5-sunburst" }) || new ImageSelection().Model != "gpt-image-2" || PlannerModel.Default != "gpt-6.1-sol")
                throw new AgentException("Model contract failed");
            Record("model-contract", "Four exact image model identifiers; gpt-image-2 default; planner gpt-6.1-sol");
            if (options.Streaming)
                await RunStreaming(ct);
            else if (options.Region)
                await RunRegion(ct);
            else if (options.Recovery != null)
                RecoverResponse(options.Recovery);
            else if (options.Generate || options.Edit)
                await RunLive(ct);
            else
                RunLocal();
            report.Status = options.Recovery == null ? "passed" : "recovered-unverified";
            WriteReport();
            return report;
        }
        catch (Exception error)
        {
            report.Status = "failed";
            var safe = Safe(error.Message);
            try
            {
                Record("failure", safe, "failed");
            }
            catch (IOException)
            {
            }

            throw new AgentException(safe);
        }
        finally
        {
            ownedTransport?.Dispose();
        }
    }

    string Safe(string value)
    {
        if (client != null)
            return client.Sanitize(value);
        if (!string.IsNullOrEmpty(secret))
            value = value.Replace(secret, "[已隐藏]", StringComparison.Ordinal);
        value = Regex.Replace(value, "(?i)Bearer\\s+[^\\s\"'<>]+", "Bearer [已隐藏]");
        return Regex.Replace(value, "sk-[A-Za-z0-9_-]{6,}", "[已隐藏]");
    }

    void WriteReport() => AppPaths.WriteAtomic(Path.Combine(options.Output, "report.json"), Encoding.UTF8.GetBytes(JsonSerializer.Serialize(report, ReportJson)));
    void Record(string name, string detail, string status = "passed", IEnumerable<AssetRecord>? images = null)
    {
        report.Events.Add(new(name, status, Safe(detail), (images ?? []).Select(store.AssetPath).ToArray()));
        WriteReport();
    }

    Conversation Conversation(string title) => store.Conversations().FirstOrDefault() ?? store.CreateConversation(title);
    static byte[] ReadFile(string filename, int limit)
    {
        var path = Path.GetFullPath(filename);
        var info = new FileInfo(path);
        if (!info.Exists || info.Length == 0 || info.Length > limit)
            throw new AgentException("诊断输入文件不存在、为空或超过大小上限。");
        return File.ReadAllBytes(path);
    }

    async Task<APIClient> LiveClient(bool validate, CancellationToken ct)
    {
        if (client == null)
        {
            string? address = null, key = null;
            try
            {
                address = readEnvironment("OPENAI_BASE_URL");
                key = readEnvironment("OPENAI_API_KEY");
            }
            finally
            {
                clearEnvironment("OPENAI_BASE_URL");
                clearEnvironment("OPENAI_API_KEY");
            }

            secret = key?.Trim();
            if (string.IsNullOrWhiteSpace(address) || string.IsNullOrWhiteSpace(key))
                throw new AgentException("显式 live 诊断需要进程环境 OPENAI_BASE_URL 与 OPENAI_API_KEY；不会读取其他应用或系统凭据。");
            if (Uri.UnescapeDataString(address).Contains(secret!, StringComparison.Ordinal))
                throw new AgentException("API 地址不能包含 API Key。");
            var transport = liveTransport ?? (ownedTransport = new HttpClientTransport());
            client = new APIClient(address, key, transport: transport);
            report.Endpoint = client.Endpoint.String;
        }

        if (validate && !validatedConnection)
        {
            var models = await client.ValidateConnection(ct);
            validatedConnection = true;
            Record("connection", $"GET /v1/models returned {models.Length} model identifiers; credentials excluded from report");
        }

        return client;
    }

    void RunLocal()
    {
        var now = DateTimeOffset.UtcNow;
        var conversation = store.CreateConversation("Local diagnostics", now);
        store.AddMessage(new() { ConversationID = conversation.ID, Role = MessageRole.User, Text = "A local memory check", CreatedAt = now });
        if (new MemoryBuilder(store, () => now).Build(conversation.ID, new()).Entries.Count != 1)
            throw new AgentException("Local memory check failed");
        store.ResetMemory(conversation.ID, now);
        using var reopened = new SQLiteStore(store.Paths);
        if (new MemoryBuilder(reopened, () => now).Build(conversation.ID, new()).Entries.Count != 0 || reopened.Messages(conversation.ID).Count != 1)
            throw new AgentException("Memory reset/reopen failed");
        Record("sqlite-memory", "SQLite reopened; memory reset excludes context and preserves history");
        var png = new PixelImage(1, 1, new byte[] { 100, 140, 180, 255 }).PngData();
        var asset = store.SaveImage(png, conversation.ID, AssetSource.Imported);
        if (!File.ReadAllBytes(store.AssetPath(asset)).AsSpan().SequenceEqual(png))
            throw new AgentException("Original image bytes changed");
        Record("image-decode-save", $"Skia decoded {asset.Width}×{asset.Height}; original bytes saved", images: [asset]);
    }

    async Task RunStreaming(CancellationToken ct)
    {
        foreach (bool interrupted in new[]
        {
            false,
            true
        }

        )
        {
            var conversation = store.CreateConversation(interrupted ? "Offline interrupted stream" : "Offline completed stream");
            var transport = new OfflineTransport
            {
                Slow = false
            };
            var api = new APIClient("https://offline.invalid", "offline-stream-diagnostic", transport: transport);
            var lengths = new List<int>();
            var outcome = await new AgentEngine(store, api).Submit(new(conversation.ID, interrupted ? "[interrupt] 离线合成图片的流式提示词验证。" : "离线合成图片的流式提示词验证。", new()), planningPreview: p => lengths.Add(TextElements.Count(p.Text)), ct: ct);
            if (lengths.Count < 3 || lengths[0] >= lengths[^1] || transport.ResponseCalls != 1 || transport.ImageCalls != (interrupted ? 0 : 1) || outcome.Run.Stage != (interrupted ? RunStage.Failed : RunStage.Completed))
                throw new AgentException("Offline stream growth, terminal gate or request-count check failed");
            if (interrupted)
            {
                if (outcome.Run.DetailedPrompt != null || outcome.Message.DetailedPrompt != null || outcome.Assets.Count != 0)
                    throw new AgentException("Unfinished preview was promoted to a final prompt");
            }
            else
            {
                using var reopened = new SQLiteStore(store.Paths);
                if (outcome.Run.DetailedPrompt == null || outcome.Message.DetailedPrompt != outcome.Assets[0].Prompt || reopened.Messages(conversation.ID).Last().DetailedPrompt != outcome.Run.DetailedPrompt)
                    throw new AgentException("Final prompt persistence/equality check failed");
            }

            Record(interrupted ? "streaming-interrupted" : "streaming-completed", $"Offline incremental SSE: {lengths.Count} real preview updates ({string.Join(',', lengths)} chars); one planner, {transport.ImageCalls} image calls; {(interrupted ? "unfinished text never persisted" : "validated final prompt and reopened history match image asset")}", images: outcome.Assets);
        }
    }

    void RecoverResponse(string filename)
    {
        var conversation = Conversation("恢复服务已有图片");
        var existing = store.Assets(conversation.ID).Where(a => a.ModelVerified == false).ToArray();
        if (existing.Length > 0)
        {
            Record("native-output-recovery", "Existing recovered images retained; no HTTP request was made; actual model remains unverified", "retained-unverified", existing);
            return;
        }

        var response = ResponseResult.Decode(Encoding.UTF8.GetString(ReadFile(filename, 145 * 1024 * 1024)));
        var recovery = response.RecoverImages();
        var images = recovery.Images.DistinctBy(i => Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(i.Data))).ToArray();
        if (images.Length == 0)
            throw new AgentException("保存的 Responses JSON 没有可恢复的有效图片。" + string.Join(' ', recovery.Failures));
        ImageSelection? selection = options.Value("--model") == null ? null : options.Selection();
        var run = new RunRecord
        {
            ConversationID = conversation.ID,
            Stage = RunStage.Saving,
            Request = "从已有 Responses JSON 离线恢复图片；实际模型未验证。",
            Selection = selection ?? new()
        };
        store.SaveRun(run);
        for (int i = 0; i < images.Length; i++)
            run.RecoveryRelativePath = store.SaveRawImage(images[i].Data, run, "native-" + (i + 1));
        store.SaveRecoveryMetadata(run, modelVerified: false);
        var assets = new List<AssetRecord>();
        foreach (var image in images)
        {
            var asset = store.SaveImage(image.Data, conversation.ID, AssetSource.Generated, selection: selection, modelVerified: false, run: run);
            assets.Add(asset);
            run.ResultAssetIDs = [..assets.Select(a => a.ID)];
        }

        run.Stage = RunStage.Failed;
        run.UpdatedAt = DateTimeOffset.UtcNow;
        run.Error = "已有图片已恢复，实际图片模型未验证。未调用图片接口或规划接口。";
        store.SaveRun(run);
        store.AddMessage(new() { ConversationID = conversation.ID, Role = MessageRole.Assistant, Text = run.Error, AssetIDs = run.ResultAssetIDs, RunID = run.ID });
        Record("native-output-recovery", $"Decoded {assets.Count} existing image(s); no HTTP request was made; actual model remains unverified. {string.Join(' ', recovery.Failures)}", "recovered-unverified", assets);
    }

    async Task RunLive(CancellationToken ct)
    {
        var selection = options.Selection();
        var conversation = Conversation("Live NewAPI validation");
        if (options.Generate)
        {
            var existing = store.Assets(conversation.ID).Where(a => a.Source == AssetSource.Generated).ToArray();
            if (existing.Length > 0)
                Record("live-generation", "Existing generated result retained without another HTTP request", "retained", existing);
            else
            {
                if (store.Runs(conversation.ID).Count > 0)
                    throw new AgentException("此输出目录已有尝试过的 live 请求。不会重新规划或重放；请检查现有结果，或为显式新任务选择新目录。");
                var api = await LiveClient(true, ct);
                var text = options.Value("--prompt") ?? "请画一幅极简的山间湖泊插画，柔和晨光、层叠远山、湖畔小屋，森林绿和温暖米色，纸张质感，画面无文字。";
                var outcome = await new AgentEngine(store, api).Submit(new(conversation.ID, text, selection), ct: ct);
                Record("live-generation", $"Requested {selection.Model} at {selection.Size}; decoded {string.Join(", ", outcome.Assets.Select(a => $"{a.Width}×{a.Height}"))}; run {outcome.Run.ID}", outcome.Run.Stage.ToString().ToLowerInvariant(), outcome.Assets);
                if (outcome.Run.Stage != RunStage.Completed || outcome.Assets.Count == 0)
                    throw new AgentException(outcome.Run.Error ?? "Planner did not produce an image");
            }
        }

        if (options.Edit)
        {
            var all = store.Assets(conversation.ID);
            var existing = all.LastOrDefault(a => a.Source == AssetSource.Edited);
            if (existing != null)
            {
                Record("live-edit", "Existing edited result retained without another HTTP request", "retained", [existing]);
                return;
            }

            if (store.Runs(conversation.ID).LastOrDefault()is { Stage: not RunStage.Completed })
                throw new AgentException("上次 live 任务未正常结束；不会自动重放或编辑，请检查已保存图片。");
            AssetRecord reference;
            if (options.Value("--reference")is { } file)
                reference = store.SaveImage(ReadFile(file, DecodedImage.MaximumBytes), conversation.ID, AssetSource.Imported);
            else
                reference = all.LastOrDefault() ?? throw new AgentException("--live-edit 需要已有保存图片或 --reference FILE。");
            var api = await LiveClient(true, ct);
            var text = options.Value("--edit-prompt") ?? "请编辑这张参考图：保持构图、小屋和山体不变，把天空改成柔和的黄昏粉紫色，湖面保留安静的反光。";
            var outcome = await new AgentEngine(store, api).Submit(new(conversation.ID, text, selection, reference.ID), ct: ct);
            Record("live-edit", $"Reference {reference.ID}; exact model {selection.Model}; result lineage {outcome.Assets.FirstOrDefault()?.ParentAssetID ?? "none"}", outcome.Run.Stage.ToString().ToLowerInvariant(), outcome.Assets);
            if (outcome.Run.Stage != RunStage.Completed || outcome.Assets.FirstOrDefault()?.ParentAssetID != reference.ID)
                throw new AgentException(outcome.Run.Error ?? "Planner did not perform the requested edit");
        }
    }

    async Task RunRegion(CancellationToken ct)
    {
        var conversation = Conversation(options.LiveRegion ? "Live regional validation" : "Isolated regional validation");
        var previous = store.Runs(conversation.ID);
        if (previous.Count > 0)
        {
            var assets = store.Assets(conversation.ID).Where(a => a.Source == AssetSource.Edited).ToArray();
            if (previous[^1].Stage == RunStage.Completed && assets.Length > 0)
            {
                Record(options.LiveRegion ? "live-region" : "region", "Existing completed regional result retained; no HTTP request or image replay", "retained", assets);
                return;
            }

            throw new AgentException("此输出目录已有尝试过的局部任务。请检查已保存或 recovery 图片；不会重放。");
        }

        var selection = options.Selection(true);
        AssetRecord reference;
        if (options.Value("--reference")is { } file)
            reference = store.SaveImage(ReadFile(file, DecodedImage.MaximumBytes), conversation.ID, AssetSource.Imported);
        else if (options.LiveRegion)
            throw new AgentException("--live-region 需要 --reference FILE；不会生成新的底图。");
        else
        {
            var rgba = new byte[96 * 64 * 4];
            for (int y = 0; y < 64; y++)
                for (int x = 0; x < 96; x++)
                {
                    int i = (y * 96 + x) * 4;
                    rgba[i] = (byte)(x * 2);
                    rgba[i + 1] = (byte)(y * 3);
                    rgba[i + 2] = (byte)((x + y) % 256);
                    rgba[i + 3] = 255;
                }

            reference = store.SaveImage(new PixelImage(96, 64, rgba).PngData(), conversation.ID, AssetSource.Imported);
        }

        var original = File.ReadAllBytes(store.AssetPath(reference));
        var image = PixelImage.Decode(original);
        var region = new RegionSelection(image.Width, image.Height);
        if (options.Value("--region-rect")is { } rect)
        {
            var parts = rect.Split(',');
            var values = parts.Select(p => double.TryParse(p, NumberStyles.Float, CultureInfo.InvariantCulture, out double value) ? value : double.NaN).ToArray();
            if (values.Length != 4 || values.Any(v => !double.IsFinite(v)) || values[2] <= 0 || values[3] <= 0)
                throw new AgentException("--region-rect 必须是按正规化原图像素表示的 x,y,width,height。");
            region.AddRectangle(new(values[0], values[1]), new(values[0] + values[2], values[1] + values[3]));
        }
        else
            region.AddRectangle(new(image.Width * .4, image.Height * .3), new(image.Width * .6, image.Height * .5));
        var snapshot = new RegionEditSnapshot(image, region);
        AppPaths.WriteAtomic(Path.Combine(options.Output, "region-crop.png"), snapshot.ImagePNG);
        AppPaths.WriteAtomic(Path.Combine(options.Output, "region-mask.png"), snapshot.MaskPNG);
        IHTTPTransport target;
        if (options.LiveRegion)
        {
            _ = await LiveClient(false, ct);
            target = liveTransport ?? ownedTransport!;
        }
        else
            target = new OfflineRegionDiagnosticTransport(reference.ID, selection);
        var audit = new RegionalDiagnosticAudit(target, snapshot, selection);
        var api = options.LiveRegion ? new APIClient(client!.Endpoint.String, secret!, transport: audit) : new APIClient("https://offline.invalid", "offline-region-diagnostic", transport: audit);
        var instruction = options.Value("--edit-prompt") ?? "将选中的部分改成柔和的蓝色，保持周围构图与其他内容。";
        var outcome = await new AgentEngine(store, api).Submit(new(conversation.ID, instruction, selection, reference.ID, new(reference.ID, region)), ct: ct);
        Record(options.LiveRegion ? "live-region-request" : "region-request", $"Pinned source {reference.ID}; model {selection.Model}; ROI {snapshot.ROI.Width}×{snapshot.ROI.Height}; alpha PNG mask {snapshot.MaskPNG.Length} bytes; run {outcome.Run.ID}", outcome.Run.Stage.ToString().ToLowerInvariant(), outcome.Assets);
        if (outcome.Run.Stage != RunStage.Completed || outcome.Assets.FirstOrDefault()is not { } asset || asset.ParentAssetID != reference.ID)
            throw new AgentException(outcome.Run.Error ?? "Regional plan did not complete");
        var result = PixelImage.Decode(File.ReadAllBytes(store.AssetPath(asset)));
        if (result.Width != image.Width || result.Height != image.Height || !File.ReadAllBytes(store.AssetPath(reference)).AsSpan().SequenceEqual(original) || !result.ICC.AsSpan().SequenceEqual(image.ICC))
            throw new AgentException("Source size, original bytes, ICC or lineage changed");
        int outside = 0, changed = 0;
        for (int i = 0; i < snapshot.Coverage.Length; i++)
        {
            bool equal = image.RGBA.AsSpan(i * 4, 4).SequenceEqual(result.RGBA.AsSpan(i * 4, 4));
            if (snapshot.Coverage[i] == 0)
            {
                if (!equal)
                    throw new AgentException($"Outside-selection pixel changed at {i}");
                outside++;
            }
            else if (!equal)
                changed++;
        }

        if (audit.Plans != 1 || audit.Images != 1 || !audit.ValidMultipart || store.RecoveryPath(outcome.Run) == null)
            throw new AgentException("Unexpected request count, multipart or missing returned patch recovery");
        Record(options.LiveRegion ? "live-region-preservation" : "region-preservation", $"One plan and one masked edit; matching image/mask multipart verified; full result {result.Width}×{result.Height}; {outside} outside pixels exactly equal; {changed} selected pixels changed; original ICC and raw returned patch retained", images: [reference, asset]);
    }
}

sealed class RegionalDiagnosticAudit(IHTTPTransport target, RegionEditSnapshot snapshot, ImageSelection selection) : IHTTPTransport
{
    public int Plans { get; private set; }
    public int Images { get; private set; }
    public bool ValidMultipart { get; private set; }

    public async Task StreamAsync(HttpRequestMessage request, Action<HTTPStreamEvent> receive, CancellationToken ct)
    {
        if (!request.RequestUri!.AbsolutePath.EndsWith("/responses", StringComparison.Ordinal) || ++Plans != 1)
            throw new AgentException("Unexpected extra planning request");
        await target.StreamAsync(request, receive, ct);
    }

    public async Task<HTTPResponse> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        if (request.RequestUri!.AbsolutePath.EndsWith("/images/edits", StringComparison.Ordinal))
        {
            if (++Images != 1 || request.Content == null || request.Content.Headers.ContentType?.MediaType != "multipart/form-data")
                throw new AgentException("Unexpected duplicate image request or missing multipart");
            var bytes = await request.Content.ReadAsByteArrayAsync(ct);
            var text = Encoding.UTF8.GetString(bytes);
            ValidMultipart = bytes.AsSpan().IndexOf(snapshot.ImagePNG) >= 0 && bytes.AsSpan().IndexOf(snapshot.MaskPNG) >= 0 && Regex.IsMatch(text, "name=\"?mask\"?[;\\r\\n]") && text.Contains("mask.png", StringComparison.Ordinal) && text.Contains(selection.Model, StringComparison.Ordinal);
            if (!ValidMultipart)
                throw new AgentException("Regional request missing exact crop/mask/model");
        }
        else if (request.Method != HttpMethod.Get || request.Headers.Authorization != null)
            throw new AgentException("Unexpected diagnostic endpoint; no request sent");
        return await target.SendAsync(request, ct);
    }
}

sealed class OfflineRegionDiagnosticTransport(string reference, ImageSelection selection) : IHTTPTransport
{
    public Task StreamAsync(HttpRequestMessage request, Action<HTTPStreamEvent> receive, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var arguments = JsonSerializer.Serialize(new { action = "edit", prompt = "Edit only the transparent masked pixels with a soft blue color; preserve the surrounding context.", model = selection.Model, size = "auto", quality = selection.Quality, reference_image_id = reference, reply_text = "选区已修改。" });
        var body = JsonSerializer.Serialize(new { status = "completed", output = new[] { new { type = "function_call", id = "region_item", name = "prepare_image_request", call_id = "region_diagnostic", arguments } } });
        receive(new(200, "application/json"));
        receive(new(Bytes: Encoding.UTF8.GetBytes(body)));
        return Task.CompletedTask;
    }

    public Task<HTTPResponse> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (!request.RequestUri!.AbsolutePath.EndsWith("/images/edits", StringComparison.Ordinal))
            throw new AgentException("Unexpected offline diagnostic endpoint");
        var rgba = Enumerable.Range(0, 45).SelectMany(_ => new byte[] { 220, 30, 90, 255 }).ToArray();
        var patch = new PixelImage(9, 5, rgba).PngData();
        return Task.FromResult(new HTTPResponse(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { data = new[] { new { b64_json = Convert.ToBase64String(patch) } } })), 200));
    }
}
