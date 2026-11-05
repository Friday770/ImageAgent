using System.Text;
using System.Text.Json;

namespace ImageAgent.Core;
public record ToolCall(string Name, string CallID, string Arguments);
public record ResponseResult(JsonElement[] Output, string? Status = null, string? FailureDetail = null)
{
    public static ResponseResult Decode(string s)
    {
        var e = SwiftJson.Parse(s);
        if (e.Get("output").ValueKind != JsonValueKind.Array)
            throw new AgentException("规划模型未返回有效的 Responses output。");
        return new(e.Get("output").Array(), e.Str("status"), e.Get("incomplete_details").Str("reason") ?? e.Get("error").Str("message"));
    }

    public ToolCall[] ToolCalls => Output.Where(e => e.Str("type") == "function_call").Select(e => new ToolCall(e.Str("name") ?? "", e.Str("call_id") ?? "", e.Str("arguments") ?? "")).ToArray();
    public JsonElement[] NativeOutputs => Output.Where(e => e.Str("type") == "image_generation_call").ToArray();

    public (List<DecodedImage> Images, List<string> Failures) RecoverImages()
    {
        var images = new List<DecodedImage>();
        var errors = new List<string>();
        foreach (var e in NativeOutputs)
        {
            try
            {
                var bytes = NativeBytes(e);
                if (bytes == null)
                    throw new AgentException("内置图片未包含有效字节。");
                images.Add(new(bytes));
            }
            catch (Exception x)when (x is AgentException or FormatException)
            {
                errors.Add("内置图片输出无法恢复：" + x.Message);
            }
        }

        return (images, errors);
    }

    public static byte[]? NativeBytes(JsonElement e)
    {
        var s = e.Str("result");
        if (string.IsNullOrWhiteSpace(s))
            return null;
        if (s.StartsWith("data:image/", StringComparison.Ordinal) && s.IndexOf(',')is var index && index >= 0)
            s = s[(index + 1)..];
        try
        {
            return Convert.FromBase64String(s);
        }
        catch (FormatException)
        {
            return null;
        }
    }
}

public sealed class ResponseStreamException(ResponseResult partial, bool cancelled, string message) : Exception(message)
{
    public ResponseResult Partial { get; } = partial;
    public bool WasCancelled { get; } = cancelled;
}

public sealed class ResponsesStreamDecoder
{
    const int OrdinaryLimit = 262144, NativeLimit = 145 * 1024 * 1024, StreamLimit = 384 * 1024 * 1024;
    enum Format
    {
        Unknown,
        Json,
        Sse
    }

    Format format;
    long total;
    readonly List<byte> line = [], eventData = [], json = [];
    string? eventName;
    ResponseResult? terminal;
    readonly List<JsonElement> native = [];
    readonly Dictionary<int, Item> items = [];
    bool done;
    string last = "";
    sealed class Item(string id, string kind, string name, string callID)
    {
        public string ID = id, Kind = kind, Name = name, CallID = callID, Arguments = "";
        public bool Done;
        public PromptScanner Scanner = new();
    }

    public List<string> FinalPreviews { get; } = [];

    static AgentException Invalid(string s) => new("规划响应流无效（" + s + "）；未执行图片请求。");
    public ResponseResult Partial
    {
        get
        {
            var output = new List<JsonElement>();
            var buffered = System.Array.Empty<JsonElement>();
            if (format == Format.Json && terminal == null)
            {
                try
                {
                    buffered = ResponseResult.Decode(Utf8(json)).NativeOutputs;
                }
                catch (Exception e)when (e is AgentException or JsonException or DecoderFallbackException)
                {
                }
            }

            foreach (var e in (terminal?.Output ?? []).Concat(native).Concat(buffered))
            {
                if (e.Str("type") != "image_generation_call" || !output.Any(v => Equivalent(e, v)))
                    output.Add(e);
            }

            return new(output.ToArray(), terminal?.Status, terminal?.FailureDetail);
        }
    }

    static string Utf8(List<byte> bytes) => new UTF8Encoding(false, true).GetString(bytes.ToArray());
    public List<string> Append(ReadOnlySpan<byte> bytes)
    {
        total += bytes.Length;
        if (total > StreamLimit)
            throw Invalid("响应超过大小上限");
        var p = new List<string>();
        foreach (byte b in bytes)
        {
            if (format == Format.Unknown)
            {
                if (b is 9 or 10 or 13 or 32)
                    continue;
                format = b is 123 or 91 ? Format.Json : Format.Sse;
            }

            if (format == Format.Json)
            {
                if (json.Count >= NativeLimit)
                    throw Invalid("JSON 响应过大");
                json.Add(b);
            }
            else if (b == 10)
                p.AddRange(ConsumeLine());
            else
            {
                if (line.Count + eventData.Count >= NativeLimit)
                    throw Invalid("事件超过大小上限");
                line.Add(b);
            }
        }

        return p;
    }

    public ResponseResult Finish()
    {
        FinalPreviews.Clear();
        if (format == Format.Json)
        {
            if (terminal == null)
            {
                var result = ResponseResult.Decode(Utf8(json));
                Capture(result.Output);
                terminal = result;
                if (result.NativeOutputs.Length == 0 && json.Count > OrdinaryLimit)
                    throw Invalid("普通 JSON 响应过大");
            }
        }
        else
        {
            if (line.Count > 0)
                FinalPreviews.AddRange(ConsumeLine());
            if (eventData.Count > 0)
                FinalPreviews.AddRange(ConsumeEvent());
        }

        if (terminal?.Status != "completed")
            throw Invalid(terminal?.FailureDetail ?? terminal?.Status ?? "未收到完整的 completed 响应");
        FinalPreviews.AddRange(FromFinal(terminal, true));
        return Partial;
    }

    List<string> ConsumeLine()
    {
        if (line.Count > 0 && line[^1] == 13)
            line.RemoveAt(line.Count - 1);
        try
        {
            if (line.Count == 0)
                return ConsumeEvent();
            var s = Utf8(line);
            if (s.StartsWith(':'))
                return[];
            var i = s.IndexOf(':');
            var field = i < 0 ? s : s[..i];
            var value = i < 0 ? "" : s[(i + 1)..];
            if (value.StartsWith(' '))
                value = value[1..];
            switch (field)
            {
                case "data":
                    if (eventData.Count + Encoding.UTF8.GetByteCount(value) + 1 > NativeLimit)
                        throw Invalid("事件过大");
                    if (eventData.Count > 0)
                        eventData.Add(10);
                    eventData.AddRange(Encoding.UTF8.GetBytes(value));
                    break;
                case "event":
                    eventName = value;
                    break;
                case "id":
                case "retry":
                    break;
                default:
                    throw Invalid("未知 SSE 字段");
            }

            return[];
        }
        finally
        {
            line.Clear();
        }
    }

    List<string> ConsumeEvent()
    {
        try
        {
            if (eventData.Count == 0)
                return[];
            var s = Utf8(eventData);
            if (s == "[DONE]")
            {
                done = true;
                return[];
            }

            if (done)
                throw Invalid("DONE 后仍有响应事件");
            var e = SwiftJson.Parse(s);
            var type = e.Str("type") ?? throw Invalid("缺少事件类型");
            if (eventName != null && eventName != type)
                throw Invalid("事件类型不一致");
            bool hasNative = e.Get("item").Str("type") == "image_generation_call" || e.Get("response").Get("output").Array().Any(v => v.Str("type") == "image_generation_call");
            if (eventData.Count > OrdinaryLimit && !hasNative)
                throw Invalid("普通事件过大");
            if (terminal != null)
                throw Invalid("终态后仍有响应事件");
            switch (type)
            {
                case "response.output_item.added":
                case "response.output_item.done":
                {
                    var item = e.Get("item");
                    var index = Index(e);
                    var kind = item.Str("type") ?? throw Invalid("缺少条目类型");
                    if (kind == "image_generation_call")
                        Capture([item]);
                    var id = item.Str("id") ?? "";
                    if (id.Length == 0 || TextElements.Count(id) >= 256 || items.Count >= 64 && !items.ContainsKey(index))
                        throw Invalid("输出条目标识无效");
                    var name = item.Str("name") ?? "";
                    var call = item.Str("call_id") ?? "";
                    if (items.TryGetValue(index, out var old))
                    {
                        if (old.ID != id || old.Kind != kind || old.Name != name || old.CallID != call)
                            throw Invalid("输出条目标识改变");
                    }
                    else
                    {
                        if (items.Values.Any(v => v.ID == id))
                            throw Invalid("输出条目标识重复");
                        items[index] = new(id, kind, name, call);
                    }

                    var args = item.Str("arguments");
                    return kind == "function_call" && !string.IsNullOrEmpty(args) ? Update(args, index, type.EndsWith(".done", StringComparison.Ordinal), true) : [];
                }

                case "response.function_call_arguments.delta":
                case "response.function_call_arguments.done":
                {
                    var index = Index(e);
                    if (!items.TryGetValue(index, out var item) || item.ID != e.Str("item_id") || item.Kind != "function_call")
                        throw Invalid("函数参数不属于已知条目");
                    if (item.Name != "prepare_image_request")
                        return[];
                    bool complete = type.EndsWith(".done", StringComparison.Ordinal);
                    return Update(e.Str(complete ? "arguments" : "delta") ?? throw Invalid("缺少函数参数片段"), index, complete, complete);
                }

                case "response.completed":
                case "response.failed":
                case "response.incomplete":
                {
                    var r = e.Get("response");
                    if (r.Get("output").ValueKind != JsonValueKind.Array)
                        throw Invalid("终态缺少完整响应");
                    Capture(r.Get("output").Array());
                    terminal = new(r.Get("output").Array(), r.Str("status"), r.Get("incomplete_details").Str("reason") ?? r.Get("error").Str("message"));
                    if (terminal.Status != type[9..])
                        throw Invalid("终态与响应状态不一致");
                    return terminal.Status == "completed" ? FromFinal(terminal) : [];
                }

                case "error":
                    throw Invalid(e.Str("message") ?? "服务返回错误事件");
                default:
                    return[];
            }
        }
        finally
        {
            eventData.Clear();
            eventName = null;
        }
    }

    static int Index(JsonElement e)
    {
        var v = e.Get("output_index");
        if (v.ValueKind != JsonValueKind.Number || !v.TryGetDouble(out double i) || !double.IsFinite(i) || i < 0 || i >= 64 || Math.Truncate(i) != i)
            throw Invalid("输出索引无效");
        return (int)i;
    }

    List<string> Update(string fragment, int index, bool complete, bool replacement)
    {
        var item = items[index];
        if (item.Done && !(replacement && fragment == item.Arguments))
            throw Invalid("完整参数后仍有片段");
        string add;
        if (replacement)
        {
            if (item.Arguments.Length > 0 && fragment != item.Arguments)
                throw Invalid("完整参数与增量不一致");
            add = item.Arguments.Length == 0 ? fragment : "";
        }
        else
            add = fragment;
        if (Encoding.UTF8.GetByteCount(item.Arguments) + Encoding.UTF8.GetByteCount(add) > 200000)
            throw Invalid("函数参数过大");
        item.Arguments += add;
        item.Done = complete;
        if (item.Name == "prepare_image_request")
            item.Scanner.Append(add);
        return Changed(item.Scanner.Prompt);
    }

    List<string> FromFinal(ResponseResult r, bool force = false)
    {
        if (r.ToolCalls.Length != 1 || r.ToolCalls[0].Name != "prepare_image_request")
            return[];
        foreach (var pair in items.Where(p => p.Value.Kind == "function_call"))
        {
            var i = pair.Key;
            var t = pair.Value;
            if (i >= r.Output.Length)
                throw Invalid("完整响应缺少函数条目");
            var e = r.Output[i];
            if (e.Str("type") != t.Kind || e.Str("id") != t.ID || e.Str("name") != t.Name || e.Str("call_id") != t.CallID || (t.Arguments.Length > 0 && e.Str("arguments") != t.Arguments))
                throw Invalid("完整响应与函数增量不一致");
        }

        var scanner = new PromptScanner();
        if (Encoding.UTF8.GetByteCount(r.ToolCalls[0].Arguments) > 200000)
            throw Invalid("函数参数过大");
        scanner.Append(r.ToolCalls[0].Arguments);
        return force ? (scanner.Prompt.Length == 0 ? [] : [scanner.Prompt]) : Changed(scanner.Prompt);
    }

    List<string> Changed(string s)
    {
        if (s.Length == 0 || s == last)
            return[];
        last = s;
        return[s];
    }

    void Capture(IEnumerable<JsonElement> outputs)
    {
        foreach (var e in outputs.Where(e => e.Str("type") == "image_generation_call"))
        {
            if (native.Any(v => Equivalent(e, v)))
                continue;
            var id = e.Str("id");
            var i = native.FindIndex(v => v.Str("id") == id);
            if (id != null && i >= 0)
            {
                if (new ResponseResult([native[i]]).RecoverImages().Images.Count == 0)
                {
                    native[i] = e;
                    continue;
                }

                if (new ResponseResult([e]).RecoverImages().Images.Count == 0)
                    continue;
            }

            native.Add(e.Clone());
        }
    }

    static bool Equivalent(JsonElement a, JsonElement b)
    {
        if (b.Str("type") != "image_generation_call")
            return false;
        if (a.Str("id") == b.Str("id") && a.Str("result") == b.Str("result"))
            return true;
        var x = ResponseResult.NativeBytes(a);
        var y = ResponseResult.NativeBytes(b);
        return x != null && y != null && x.AsSpan().SequenceEqual(y);
    }
}

public sealed class PromptScanner
{
    readonly Stack<char> stack = [];
    readonly HashSet<string> keys = [];
    bool keyExpected, valueExpected;
    string? key;
    enum Role
    {
        None,
        Key,
        Prompt,
        Ignored
    }

    Role role;
    readonly StringBuilder text = new();
    int escape;
    string digits = "";
    char high;
    public string Prompt { get; private set; } = "";

    public void Append(string s)
    {
        foreach (char c in s)
        {
            if (role != Role.None)
            {
                if (StringChar(c))
                {
                    if (role == Role.Prompt)
                        Prompt = text.ToString();
                    if (role == Role.Key)
                    {
                        if (!keys.Add(text.ToString()))
                            throw new AgentException("重复的顶层参数。");
                        key = text.ToString();
                        keyExpected = false;
                    }

                    role = Role.None;
                    valueExpected = false;
                }

                continue;
            }

            if (char.IsWhiteSpace(c))
                continue;
            if (c == '"')
            {
                role = stack.Count == 1 && keyExpected ? Role.Key : stack.Count == 1 && valueExpected && key == "prompt" ? Role.Prompt : Role.Ignored;
                text.Clear();
                escape = 0;
            }
            else if (c is '{' or '[')
            {
                if (stack.Count == 0 && c != '{')
                    throw new AgentException("函数参数不是对象。");
                if (valueExpected && key == "prompt" && stack.Count == 1)
                    throw new AgentException("prompt 不是字符串。");
                stack.Push(c);
                if (stack.Count == 1)
                    keyExpected = true;
            }
            else if (c is '}' or ']')
            {
                if (stack.Count == 0 || !((stack.Pop(), c)is ('{', '}') or ('[', ']')))
                    throw new AgentException("函数参数括号不匹配。");
            }
            else if (c == ':' && stack.Count == 1)
                valueExpected = true;
            else if (c == ',' && stack.Count == 1)
            {
                keyExpected = true;
                valueExpected = false;
                key = null;
            }
            else if (valueExpected && key == "prompt" && stack.Count == 1)
                throw new AgentException("prompt 不是字符串。");
        }

        if (role == Role.Prompt)
            Prompt = text.ToString();
        if (Encoding.UTF8.GetByteCount(Prompt) > 128000 || TextElements.Count(Prompt) > 32000)
            throw new AgentException("提示词超过长度上限。");
    }

    bool StringChar(char c)
    {
        switch (escape)
        {
            case 0:
                if (c == '"')
                    return true;
                if (c == '\\')
                    escape = 1;
                else
                {
                    if (c < 32)
                        throw new AgentException("JSON 字符串含控制字符。");
                    text.Append(c);
                }

                break;
            case 1:
                escape = 0;
                switch (c)
                {
                    case '"':
                    case '\\':
                    case '/':
                        text.Append(c);
                        break;
                    case 'n':
                        text.Append('\n');
                        break;
                    case 'r':
                        text.Append('\r');
                        break;
                    case 't':
                        text.Append('\t');
                        break;
                    case 'b':
                        text.Append('\b');
                        break;
                    case 'f':
                        text.Append('\f');
                        break;
                    case 'u':
                        escape = 2;
                        digits = "";
                        break;
                    default:
                        throw new AgentException("JSON 转义无效。");
                }

                break;
            case 2:
            case 5:
                if (!Uri.IsHexDigit(c))
                    throw new AgentException("Unicode 转义无效。");
                digits += c;
                if (digits.Length == 4)
                {
                    char v = (char)Convert.ToInt32(digits, 16);
                    if (escape == 5)
                    {
                        if (!char.IsLowSurrogate(v))
                            throw new AgentException("Unicode 代理对无效。");
                        text.Append(high);
                        text.Append(v);
                        escape = 0;
                    }
                    else if (char.IsHighSurrogate(v))
                    {
                        high = v;
                        escape = 3;
                    }
                    else
                    {
                        if (char.IsLowSurrogate(v))
                            throw new AgentException("Unicode 代理对无效。");
                        text.Append(v);
                        escape = 0;
                    }
                }

                break;
            case 3:
                if (c != '\\')
                    throw new AgentException("缺少 Unicode 低代理项。");
                escape = 4;
                break;
            case 4:
                if (c != 'u')
                    throw new AgentException("缺少 Unicode 低代理项。");
                escape = 5;
                digits = "";
                break;
        }

        if (text.Length > 200000)
            throw new AgentException("JSON 字符串过大。");
        return false;
    }
}
