using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ImageAgent.Core;
public sealed class AgentException(string message) : Exception(message);
public static class TextElements
{
    public static int Count(string s) => StringInfo.ParseCombiningCharacters(s).Length;
    public static string Prefix(string s, int n)
    {
        var p = StringInfo.ParseCombiningCharacters(s);
        return n >= p.Length ? s : s[..p[Math.Max(0, n)]];
    }

    public static string Suffix(string s, int n)
    {
        var p = StringInfo.ParseCombiningCharacters(s);
        return n >= p.Length ? s : s[p[p.Length - Math.Max(0, n)]..];
    }
}

public static class SwiftJson
{
    public static readonly JsonSerializerOptions Options = Create();
    static JsonSerializerOptions Create()
    {
        var o = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
        };
        o.Converters.Add(new SwiftDateConverter());
        o.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase));
        return o;
    }

    public static string Encode<T>(T v) => JsonSerializer.Serialize(v, Options);
    public static T Decode<T>(string s) => JsonSerializer.Deserialize<T>(s, Options) ?? throw new AgentException("本地记录无效。");
    public static JsonElement Parse(string s)
    {
        using var d = JsonDocument.Parse(s, new JsonDocumentOptions { MaxDepth = 64 });
        Check(d.RootElement);
        return d.RootElement.Clone();
    }

    static void Check(JsonElement e)
    {
        if (e.ValueKind == JsonValueKind.Object)
        {
            var seen = new HashSet<string>();
            foreach (var p in e.EnumerateObject())
            {
                if (!seen.Add(p.Name))
                    throw new AgentException("JSON 含重复字段。");
                Check(p.Value);
            }
        }
        else if (e.ValueKind == JsonValueKind.Array)
            foreach (var a in e.EnumerateArray())
                Check(a);
    }
}

public sealed class SwiftDateConverter : JsonConverter<DateTimeOffset>
{
    static readonly DateTimeOffset Epoch = new(2001, 1, 1, 0, 0, 0, TimeSpan.Zero);
    public override DateTimeOffset Read(ref Utf8JsonReader r, Type t, JsonSerializerOptions o) => Epoch.AddSeconds(r.GetDouble());
    public override void Write(Utf8JsonWriter w, DateTimeOffset v, JsonSerializerOptions o) => w.WriteNumberValue((v - Epoch).TotalSeconds);
}

public static class ImageModels
{
    public static readonly string[] All = ["gpt-image-2", "gpt-image-2.5-flare", "gpt-image-2.5", "gpt-image-2.5-sunburst"];
    public static readonly string[] Sizes = ["auto", "1024x1024", "1536x1024", "1024x1536"];
    public static readonly string[] Qualities = ["auto", "low", "medium", "high"];
}

public static class PlannerModel
{
    public const string Default = "gpt-6.1-sol";
    public static string Validate(string input)
    {
        var s = input.Trim();
        if (s.Length == 0 || TextElements.Count(s) > 200 || input.Any(char.IsControl) || ImageModels.All.Contains(s))
            throw new AgentException("请输入有效的文字规划模型 ID（1–200 个字符，不能包含控制字符或使用图片模型）。");
        return s;
    }
}

public record ImageSelection
{
    public string Model { get; init; } = "gpt-image-2";
    public string Size { get; init; } = "1024x1024";
    public string Quality { get; init; } = "auto";

    public void Validate()
    {
        if (!ImageModels.All.Contains(Model) || !ImageModels.Sizes.Contains(Size) || !ImageModels.Qualities.Contains(Quality))
            throw new AgentException("图片模型、尺寸或质量无效。");
    }
}

public record MemoryPolicy
{
    int hours = 24, turns = 12, maxCharacters = 24000;
    public int Hours { get => hours; init => hours = Math.Clamp(value, 1, 720); }
    public int Turns { get => turns; init => turns = Math.Clamp(value, 1, 100); }
    public int MaxCharacters { get => maxCharacters; init => maxCharacters = Math.Clamp(value, 256, 100000); }
}

public record AppSettings
{
    public string Endpoint { get; init; } = "https://api.example.com/v1";
    public string PlannerModel { get; init; } = Core.PlannerModel.Default;
    public ImageSelection Selection { get; init; } = new();
    public MemoryPolicy Memory { get; init; } = new();
}

public record Conversation
{
    public string ID { get; init; } = Guid.NewGuid().ToString();
    public string Title { get; set; } = "新会话";
    public DateTimeOffset CreatedAt { get; init; } = DateTimeOffset.UtcNow;
    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset? MemoryResetAt { get; set; }
}

public enum MessageRole
{
    User,
    Assistant
}

public record MessageRecord
{
    public string ID { get; init; } = Guid.NewGuid().ToString();
    public string ConversationID { get; init; } = "";
    public MessageRole Role { get; init; }
    public string Text { get; init; } = "";
    public string[] AssetIDs { get; init; } = [];
    public string? DetailedPrompt { get; init; }
    public string? RunID { get; init; }
    public DateTimeOffset CreatedAt { get; init; } = DateTimeOffset.UtcNow;
}

public enum AssetSource
{
    Generated,
    Edited,
    Imported
}

public record AssetRecord
{
    public string ID { get; init; } = Guid.NewGuid().ToString();
    public string ConversationID { get; init; } = "";
    public string RelativePath { get; init; } = "";
    public string MediaType { get; init; } = "";
    public int Width { get; init; }
    public int Height { get; init; }
    public string? ParentAssetID { get; init; }
    public string? RunID { get; init; }
    public AssetSource Source { get; init; }
    public string Prompt { get; init; } = "";
    public string? Model { get; init; }
    public bool? ModelVerified { get; init; }
    public string? RequestedSize { get; init; }
    public DateTimeOffset CreatedAt { get; init; } = DateTimeOffset.UtcNow;

    [JsonIgnore]
    public string? DimensionWarning => RequestedSize is not null and not "auto" && RequestedSize != $"{Width}x{Height}" ? $"请求尺寸 {RequestedSize}，服务实际返回 {Width}×{Height}。已保留原图。" : null;

    [JsonIgnore]
    public string? ModelWarning => ModelVerified == false ? "服务返回了未预期的内置图片输出，实际图片模型和提示词未验证。已保留现有图片，没有额外调用图片接口。" : null;
}

public enum RunStage
{
    Planning,
    Generating,
    Editing,
    Saving,
    Finalizing,
    Completed,
    Failed,
    Cancelled,
    Interrupted
}

public static class Stages
{
    public static bool IsTerminal(this RunStage s) => s is RunStage.Completed or RunStage.Failed or RunStage.Cancelled or RunStage.Interrupted;
    public static int Order(this RunStage s) => s switch
    {
        RunStage.Planning => 0,
        RunStage.Generating or RunStage.Editing => 1,
        RunStage.Saving => 2,
        RunStage.Finalizing => 3,
        _ => 4
    };
    public static string Label(this RunStage s) => s switch
    {
        RunStage.Planning => "正在理解需求、整理提示词…",
        RunStage.Generating => "正在生成图片…",
        RunStage.Editing => "正在编辑参考图片…",
        RunStage.Saving => "正在验证并保存图片…",
        RunStage.Finalizing => "图片已保存，正在整理回复…",
        RunStage.Completed => "已完成",
        RunStage.Cancelled => "已取消；不会自动重试",
        RunStage.Interrupted => "任务已中断；不会自动重试",
        _ => "任务未完成"
    };
}

public record RunRecord
{
    public string ID { get; init; } = Guid.NewGuid().ToString();
    public string ConversationID { get; init; } = "";
    public RunStage Stage { get; set; }
    public string Request { get; init; } = "";
    public string? DetailedPrompt { get; set; }
    public ImageSelection Selection { get; init; } = new();
    public string? PlannerModel { get; init; }
    public string[] ResultAssetIDs { get; set; } = [];
    public string? Error { get; set; }
    public string? RecoveryRelativePath { get; set; }
    public RegionEditRequest? RegionEdit { get; init; }
    public DateTimeOffset CreatedAt { get; init; } = DateTimeOffset.UtcNow;
    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.UtcNow;
}

public record AgentRequest(string ConversationID, string Text, ImageSelection Selection, string? ReferenceAssetID = null, RegionEditRequest? RegionEdit = null);
public record RunOutcome(RunRecord Run, MessageRecord Message, IReadOnlyList<AssetRecord> Assets);
public record PlanningPreview(string ConversationID, string RunID, string Text);
public static class JsonExtensions
{
    public static string? Str(this JsonElement e, string key) => e.ValueKind == JsonValueKind.Object && e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
    public static JsonElement Get(this JsonElement e, string key) => e.ValueKind == JsonValueKind.Object && e.TryGetProperty(key, out var v) ? v : default;
    public static JsonElement[] Array(this JsonElement e) => e.ValueKind == JsonValueKind.Array ? e.EnumerateArray().Select(v => v.Clone()).ToArray() : [];
}
