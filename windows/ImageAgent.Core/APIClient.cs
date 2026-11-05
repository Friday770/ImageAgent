using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ImageAgent.Core;

public record HTTPResponse(byte[] Data, int Status);
public record HTTPStreamEvent(int? Status = null, string? ContentType = null, byte[]? Bytes = null);
public interface IHTTPTransport
{
    Task<HTTPResponse> SendAsync(HttpRequestMessage request, CancellationToken ct);
    Task StreamAsync(HttpRequestMessage request, Action<HTTPStreamEvent> receive, CancellationToken ct);
}

public sealed class HttpClientTransport : IHTTPTransport, IDisposable
{
    readonly HttpClient client = new(new SocketsHttpHandler { AllowAutoRedirect = false, UseCookies = false })
    {
        Timeout = TimeSpan.FromSeconds(420)
    };
    public async Task<HTTPResponse> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        using var r = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
        using var stream = await r.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
        using var o = new MemoryStream();
        var bytes = new byte[8192];
        int n;
        while ((n = await stream.ReadAsync(bytes, ct).ConfigureAwait(false)) > 0)
        {
            if (o.Length + n > 145L * 1024 * 1024)
                throw new AgentException("响应超过大小上限。");
            o.Write(bytes, 0, n);
        }

        return new(o.ToArray(), (int)r.StatusCode);
    }

    public async Task StreamAsync(HttpRequestMessage request, Action<HTTPStreamEvent> receive, CancellationToken ct)
    {
        using var r = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
        receive(new((int)r.StatusCode, r.Content.Headers.ContentType?.MediaType));
        using var stream = await r.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
        var bytes = new byte[4096];
        int n;
        while ((n = await stream.ReadAsync(bytes, ct).ConfigureAwait(false)) > 0)
            receive(new(Bytes: bytes.AsSpan(0, n).ToArray()));
    }

    public void Dispose() => client.Dispose();
}

public sealed class APIClient
{
    public ServiceEndpoint Endpoint
    {
        get;
    }
    public string SelectedPlannerModel
    {
        get;
    }

    readonly string key;
    readonly IHTTPTransport transport;
    public APIClient(string baseURL, string apiKey, string plannerModel = PlannerModel.Default, IHTTPTransport? transport = null)
    {
        key = apiKey.Trim();
        if (key.Length == 0 || key.Contains('\n') || key.Contains('\r'))
            throw new AgentException("请输入有效的 API Key。");
        ValidateCredentialFreeEndpoint(baseURL);
        Endpoint = new(baseURL);
        ValidateCredentialFreeEndpoint(Endpoint.String);
        SelectedPlannerModel = PlannerModel.Validate(plannerModel);
        if (ContainsCredential(SelectedPlannerModel))
            throw new AgentException("规划模型 ID 不能包含 API 凭据。");
        this.transport = transport ?? new HttpClientTransport();
    }

    void ValidateCredentialFreeEndpoint(string address)
    {
        if (address.Contains(key, StringComparison.Ordinal) || Uri.UnescapeDataString(address).Contains(key, StringComparison.Ordinal))
            throw new AgentException("API 地址不能包含 API 凭据。");
    }

    bool ContainsCredential(string id) => id.Contains(key, StringComparison.Ordinal) || Regex.IsMatch(id, "(?<![\\p{L}\\p{N}_-])(?:sk-[A-Za-z0-9_-]{6,}(?![\\p{L}\\p{N}_-])|(?i:Bearer)\\s+[^\\s\"'<>]+)");
    public string Sanitize(string text)
    {
        var s = text.Replace(key, "[已隐藏]", StringComparison.Ordinal);
        s = Regex.Replace(s, "(?i)Bearer\\s+[^\\s\"'<>]+", "Bearer [已隐藏]");
        return Regex.Replace(s, "sk-[A-Za-z0-9_-]{6,}", "[已隐藏]");
    }

    public string SafeDescription(Exception e) => TextElements.Prefix(Sanitize(e.Message), 800);
    public string StreamingPreview(string s)
    {
        var visible = Sanitize(s);
        foreach (var token in new[]
        {
            key,
            "Bearer",
            "sk-"
        }

        )
        {
            var comparison = token == key ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase;
            for (int i = Math.Min(token.Length - 1, visible.Length); i > 0; i--)
                if (visible.EndsWith(token[..i], comparison))
                {
                    visible = visible[..^i];
                    break;
                }
        }

        visible = Sanitize(visible);
        visible = Regex.Replace(visible, "(?i)Bearer\\s+[^\\s\"'<>]*", "Bearer [已隐藏]");
        return Regex.Replace(visible, "(?i)sk-[A-Za-z0-9_-]*", "[已隐藏]");
    }

    HttpRequestMessage Request(string path, HttpMethod? method = null)
    {
        var r = new HttpRequestMessage(method ?? HttpMethod.Post, Endpoint.Url(path));
        r.Headers.Authorization = new("Bearer", key);
        r.Headers.Accept.Add(new("application/json"));
        return r;
    }

    async Task<byte[]> Send(HttpRequestMessage r, CancellationToken ct, int timeout = 360)
    {
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(ct);
        limit.CancelAfter(TimeSpan.FromSeconds(timeout));
        try
        {
            var response = await transport.SendAsync(r, limit.Token).ConfigureAwait(false);
            if (response.Status is >= 200 and < 300)
                return response.Data;
            string detail = "服务请求失败";
            try
            {
                var j = SwiftJson.Parse(Encoding.UTF8.GetString(response.Data));
                detail = j.Get("error").Str("message") ?? j.Str("message") ?? detail;
            }
            catch (JsonException)
            {
            }

            var hint = response.Status switch
            {
                401 or 403 => "请检查此服务的 API Key 和访问权限。",
                429 => "服务限流或额度不足，请稍后手动重试。",
                404 => "请检查 API 地址及所选模型是否可用。",
                _ => "请求未自动重试。"
            };
            throw new AgentException($"HTTP {response.Status}：{TextElements.Prefix(Sanitize(detail), 800)}\n{hint}");
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested && limit.IsCancellationRequested)
        {
            throw new AgentException("网络请求超时；请求未自动重试。");
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (AgentException)
        {
            throw;
        }
        catch (Exception e)
        {
            throw new AgentException("网络请求失败：" + SafeDescription(e) + "。请求未自动重试。");
        }
    }

    public async Task<string[]> ValidateConnection(CancellationToken ct = default)
    {
        using var r = Request("models", HttpMethod.Get);
        var e = SwiftJson.Parse(Encoding.UTF8.GetString(await Send(r, ct, 30).ConfigureAwait(false)));
        if (e.Get("data").ValueKind != JsonValueKind.Array)
            throw new AgentException("模型列表格式无效，请检查服务地址。");
        return e.Get("data").Array().Select(v => v.Str("id")).Where(id => !string.IsNullOrEmpty(id) && id == id.Trim() && TextElements.Count(id) <= 200 && !id.Any(char.IsControl) && !ContainsCredential(id)).Cast<string>().ToArray();
    }

    public static object[] Tools(ImageSelection s)
    {
        var properties = new Dictionary<string, object>
        {
            {
                "action",
                new
                {
                    type = "string",
                    @enum = new[]
                    {
                        "generate",
                        "edit",
                        "reply"
                    }
                }
            },
            {
                "prompt",
                new
                {
                    type = "string"
                }
            },
            {
                "model",
                new
                {
                    type = "string",
                    @enum = new[]
                    {
                        s.Model
                    }
                }
            },
            {
                "size",
                new
                {
                    type = "string",
                    @enum = new[]
                    {
                        s.Size
                    }
                }
            },
            {
                "quality",
                new
                {
                    type = "string",
                    @enum = new[]
                    {
                        s.Quality
                    }
                }
            },
            {
                "reference_image_id",
                new
                {
                    type = new[]
                    {
                        "string",
                        "null"
                    }
                }
            },
            {
                "reply_text",
                new
                {
                    type = "string"
                }
            }
        };
        return [new
        {
            type = "function",
            name = "prepare_image_request",
            strict = true,
            description = "只规划图片任务或普通讨论，不生成图片。App 校验后执行固定操作。",
            parameters = new
            {
                type = "object",
                properties,
                required = new[]
                {
                    "action",
                    "prompt",
                    "model",
                    "size",
                    "quality",
                    "reference_image_id",
                    "reply_text"
                },
                additionalProperties = false
            }
        }

        ];
    }

    public async Task<ResponseResult> Respond(object[] input, ImageSelection selection, Action<string>? preview = null, CancellationToken ct = default)
    {
        using var r = Request("responses");
        var body = new Dictionary<string, object>
        {
            {
                "model",
                SelectedPlannerModel
            },
            {
                "store",
                false
            },
            {
                "input",
                input
            },
            {
                "tools",
                Tools(selection)
            },
            {
                "parallel_tool_calls",
                false
            },
            {
                "tool_choice",
                new
                {
                    type = "function",
                    name = "prepare_image_request"
                }
            },
            {
                "max_output_tokens",
                4096
            },
            {
                "stream",
                true
            }
        };
        if (SelectedPlannerModel == PlannerModel.Default)
            body["reasoning"] = new
            {
                effort = "low"
            };
        r.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");
        r.Headers.Accept.Clear();
        r.Headers.Accept.ParseAdd("text/event-stream, application/json");
        var decoder = new ResponsesStreamDecoder();
        int? status = null;
        var errorBytes = new List<byte>();
        string published = "";
        void Publish(string s)
        {
            if (s.Length > 0 && s != published)
            {
                published = s;
                preview?.Invoke(s);
            }
        }

        using var limit = CancellationTokenSource.CreateLinkedTokenSource(ct);
        limit.CancelAfter(TimeSpan.FromSeconds(120));
        try
        {
            await transport.StreamAsync(r, e =>
            {
                if (e.Status != null)
                {
                    if (status != null)
                        throw new AgentException("重复 HTTP 响应头。");
                    status = e.Status;
                    return;
                }

                if (status == null)
                    throw new AgentException("缺少 HTTP 响应头。");
                if (e.Bytes == null)
                    return;
                if (status is < 200 or >= 300)
                {
                    errorBytes.AddRange(e.Bytes.Take(Math.Max(0, 65536 - errorBytes.Count)));
                    return;
                }

                foreach (var s in decoder.Append(e.Bytes))
                    Publish(StreamingPreview(s));
            }, limit.Token).ConfigureAwait(false);
            if (status == null)
                throw new AgentException("服务未返回 HTTP 响应。");
            if (status is < 200 or >= 300)
            {
                var detail = "服务请求失败";
                try
                {
                    var j = SwiftJson.Parse(Encoding.UTF8.GetString(errorBytes.ToArray()));
                    detail = j.Get("error").Str("message") ?? j.Str("message") ?? detail;
                }
                catch (JsonException)
                {
                }

                throw new AgentException($"HTTP {status}：{Sanitize(detail)}。请求未自动重试。");
            }

            var result = decoder.Finish();
            foreach (var s in decoder.FinalPreviews)
                Publish(Sanitize(s));
            return result;
        }
        catch (Exception e)
        {
            var cancelled = ct.IsCancellationRequested || e is OperationCanceledException && !limit.IsCancellationRequested;
            var partial = decoder.Partial;
            if (partial.NativeOutputs.Length > 0)
                throw new ResponseStreamException(partial, cancelled, cancelled ? "规划流已取消；已收到的图片会保留。" : "规划流未完成：" + SafeDescription(e) + "。请求未自动重试。");
            if (cancelled)
                throw new OperationCanceledException(ct);
            throw new AgentException("规划流未完成：" + SafeDescription(e) + "。请求未自动重试。");
        }
    }

    public async Task<DecodedImage> Generate(string prompt, ImageSelection s, CancellationToken ct = default)
    {
        using var r = Request("images/generations");
        r.Content = new StringContent(JsonSerializer.Serialize(new
        {
            model = s.Model,
            prompt,
            size = s.Size,
            quality = s.Quality,
            n = 1
        }), Encoding.UTF8, "application/json");
        return await DecodeResponse(await Send(r, ct).ConfigureAwait(false), ct).ConfigureAwait(false);
    }

    public async Task<DecodedImage> Edit(string prompt, ImageSelection s, byte[] reference, byte[]? mask = null, CancellationToken ct = default)
    {
        var image = new DecodedImage(reference);
        if (mask != null)
        {
            var m = new DecodedImage(mask);
            if (m.MediaType != "image/png" || m.Width != image.Width || m.Height != image.Height || mask.Length >= 4 * 1024 * 1024 || !HasAlpha(mask))
                throw new AgentException("编辑遮罩必须是小于 4MB、与参考图同尺寸且带 alpha 的 PNG。");
        }

        using var form = new MultipartFormDataContent("ImageAgent-" + Guid.NewGuid());
        foreach (var (k, v) in new[]
        {
            ("model", s.Model),
            ("prompt", prompt),
            ("size", s.Size),
            ("quality", s.Quality),
            ("n", "1")
        }

        )
            form.Add(new StringContent(v), k);
        var data = new ByteArrayContent(reference);
        data.Headers.ContentType = new(image.MediaType);
        form.Add(data, "image", "reference." + image.Extension);
        if (mask != null)
        {
            var m = new ByteArrayContent(mask);
            m.Headers.ContentType = new("image/png");
            form.Add(m, "mask", "mask.png");
        }

        using var r = Request("images/edits");
        r.Content = form;
        return await DecodeResponse(await Send(r, ct).ConfigureAwait(false), ct).ConfigureAwait(false);
    }

    static bool HasAlpha(byte[] png)
    {
        using var c = SkiaSharp.SKCodec.Create(new SkiaSharp.SKMemoryStream(png));
        return c != null && c.Info.AlphaType != SkiaSharp.SKAlphaType.Opaque;
    }

    async Task<DecodedImage> DecodeResponse(byte[] bytes, CancellationToken ct)
    {
        var e = SwiftJson.Parse(Encoding.UTF8.GetString(bytes));
        var data = e.Get("data").Array();
        if (data.Length == 0)
            throw new AgentException("图片服务未返回图片数据。");
        if (data[0].Str("b64_json") is { } b)
        {
            try
            {
                return new(Convert.FromBase64String(b));
            }
            catch (FormatException)
            {
                throw new AgentException("图片服务返回的 Base64 数据无效。");
            }
        }

        if (data[0].Str("url") is { } address && Uri.TryCreate(address, UriKind.Absolute, out var u) && u.Scheme == "https" && u.Host.Length > 0 && u.UserInfo.Length == 0)
        {
            using var r = new HttpRequestMessage(HttpMethod.Get, u);
            return new(await Send(r, ct, 120).ConfigureAwait(false));
        }

        throw new AgentException("图片服务未返回有效 Base64 或 HTTPS 图片地址。");
    }
}
