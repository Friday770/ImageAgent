using ImageAgent.Core;
using System.Text;
using System.Text.Json;
using Xunit;

namespace ImageAgent.Tests;
public sealed class PrivateStore : IDisposable
{
    public string Root { get; } = Path.Combine(Path.GetTempPath(), "ImageAgentTest-" + Guid.NewGuid());
    public SQLiteStore Store { get; }

    public PrivateStore()
    {
        Store = new(new(Root));
    }

    public void Dispose()
    {
        Store.Dispose();
        Directory.Delete(Root, true);
    }
}

public static class Fixture
{
    public static readonly string Root = Path.Combine(AppContext.BaseDirectory, "ParityFixtures");
    public static byte[] PNG => File.ReadAllBytes(Path.Combine(Root, "reference.png"));
    public static JsonElement Manifest => SwiftJson.Parse(File.ReadAllText(Path.Combine(Root, "manifest.json")));

    public static string Plan(ImageSelection? s = null, string action = "generate", string? reference = null, string prompt = "清晨的湖泊 🌄", string reply = "完成")
    {
        s ??= new();
        return JsonSerializer.Serialize(new { action, prompt, model = s.Model, size = s.Size, quality = s.Quality, reference_image_id = reference, reply_text = reply });
    }

    public static JsonElement Call(string arguments, string id = "item", string call = "call") => SwiftJson.Parse(JsonSerializer.Serialize(new { type = "function_call", id, name = "prepare_image_request", call_id = call, arguments }));
    public static byte[] Event(string type, object fields)
    {
        var d = JsonSerializer.SerializeToElement(fields).EnumerateObject().ToDictionary(p => p.Name, p => (object)p.Value);
        d["type"] = type;
        return Encoding.UTF8.GetBytes("event: " + type + "\r\ndata: " + JsonSerializer.Serialize(d) + "\r\n\r\n");
    }

    public static string Completed(string args) => JsonSerializer.Serialize(new { status = "completed", output = new[] { Call(args) } });
}

public class ModelStorageTests
{
    [Fact]
    public void SwiftDateEpochAndAcronymsAreCompatible()
    {
        var m = SwiftJson.Decode<MessageRecord>("{\"id\":\"m\",\"conversationID\":\"c\",\"role\":\"user\",\"text\":\"原话\",\"assetIDs\":[],\"createdAt\":0}");
        Assert.Equal(new DateTimeOffset(2001, 1, 1, 0, 0, 0, TimeSpan.Zero), m.CreatedAt);
        Assert.Contains("\"conversationID\":\"c\"", SwiftJson.Encode(m));
        Assert.Equal(PlannerModel.Default, SwiftJson.Decode<AppSettings>("{\"endpoint\":\"https://example.com/v1\",\"selection\":{},\"memory\":{}}").PlannerModel);
    }

    [Theory]
    [InlineData("HTTPS://EXAMPLE.COM/", "https://example.com/v1")]
    [InlineData("http://localhost:8371/api/v1/", "http://localhost:8371/api/v1")]
    [InlineData("https://host/path", "https://host/path/v1")]
    public void EndpointNormalizesOnce(string input, string expected) => Assert.Equal(expected, new ServiceEndpoint(input).String);
    [Theory]
    [InlineData("http://example.com")]
    [InlineData("https://u:p@example.com")]
    [InlineData("https://example.com?key=a")]
    [InlineData("https://example.com/#frag")]
    [InlineData("https://host/v1/v1")]
    [InlineData("https://host/a/../b")]
    public void EndpointRejectsUnsafe(string input) => Assert.Throws<AgentException>(() => new ServiceEndpoint(input));
    [Theory]
    [InlineData("gpt-image-2")]
    [InlineData("gpt-image-2.5")]
    [InlineData("gpt-image-2.5-flare")]
    [InlineData("gpt-image-2.5-sunburst")]
    [InlineData("a\nb")]
    public void PlannerExcludesExactImageModelsAndControls(string value) => Assert.Throws<AgentException>(() => PlannerModel.Validate(value));
    [Fact]
    public void PlannerAllowsUnknownTextIDs() => Assert.Equal("my-image-planner", PlannerModel.Validate(" my-image-planner "));
    [Fact]
    public void SQLiteReopenPreservesSwiftPayloadOwnershipAndCascade()
    {
        string root = Path.Combine(Path.GetTempPath(), "ImageAgentTest-" + Guid.NewGuid());
        string id, path;
        try
        {
            using (var s = new SQLiteStore(new(root)))
            {
                var c = s.CreateConversation();
                id = c.ID;
                var a = s.SaveImage(Fixture.PNG, id, AssetSource.Imported);
                path = s.AssetPath(a);
                s.AddMessage(new() { ConversationID = id, Role = MessageRole.User, Text = "  精确原话\n", AssetIDs = [a.ID] });
                var other = s.CreateConversation();
                Assert.Throws<AgentException>(() => s.AddMessage(new() { ConversationID = other.ID, AssetIDs = [a.ID] }));
            }

            using (var s = new SQLiteStore(new(root)))
            {
                Assert.Equal("  精确原话\n", s.Messages(id)[0].Text);
                Assert.True(File.Exists(path));
                s.DeleteConversation(id);
                Assert.False(File.Exists(path));
                Assert.Empty(s.Messages(id));
                Assert.Single(s.Conversations());
            }
        }
        finally
        {
            Directory.Delete(root, true);
        }
    }

    [Fact]
    public void SuppliedDataRootDirectoryLinkIsRejectedBeforeCreatingAnyChildData()
    {
        using var data = new PrivateStore();
        var target = Path.Combine(data.Root, "target");
        var link = Path.Combine(data.Root, "linked-root");
        Directory.CreateDirectory(target);
        DirectoryLinks.Create(link, target);
        try
        {
            Assert.Throws<AgentException>(() => new AppPaths(link));
            Assert.Empty(Directory.EnumerateFileSystemEntries(target));
        }
        finally
        {
            Directory.Delete(link);
        }
    }

    [Theory]
    [InlineData("assets/../escape.png")]
    [InlineData("assets/x/../../escape")]
    [InlineData("/assets/x/a.png")]
    [InlineData("assets/x/evil\\a")]
    public void LocalPathsRejectTraversal(string path)
    {
        using var p = new PrivateStore();
        Assert.Throws<AgentException>(() => p.Store.Paths.SafeFile(path, "assets"));
    }

    [Fact]
    public void LocalPathsRejectDirectoryLinkEscapes()
    {
        using var p = new PrivateStore();
        var outside = Path.Combine(Path.GetTempPath(), "ImageAgentOutside-" + Guid.NewGuid());
        Directory.CreateDirectory(outside);
        try
        {
            DirectoryLinks.Create(Path.Combine(p.Root, "assets", "linked"), outside);
            Assert.Throws<AgentException>(() => p.Store.Paths.SafeFile("assets/linked/a.png", "assets"));
        }
        finally
        {
            Directory.Delete(outside);
        }
    }

    [Fact]
    public void MemoryUsesGraphemesTurnsResetAndExplicitOldReference()
    {
        using var p = new PrivateStore();
        var s = p.Store;
        var now = DateTimeOffset.UtcNow;
        var c = s.CreateConversation(now: now.AddDays(-4));
        var a = s.SaveImage(Fixture.PNG, c.ID, AssetSource.Imported, now: now.AddDays(-3));
        var family = "👩‍👩‍👧‍👦";
        s.AddMessage(new() { ConversationID = c.ID, Role = MessageRole.User, Text = string.Concat(Enumerable.Repeat(family, 300)), CreatedAt = now.AddHours(-1) });
        s.AddMessage(new() { ConversationID = c.ID, Role = MessageRole.Assistant, Text = "future", CreatedAt = now.AddSeconds(1) });
        var m = new MemoryBuilder(s, () => now).Build(c.ID, new() { MaxCharacters = 256 }, a.ID);
        Assert.Equal(256, TextElements.Count(m.Entries[0].Text));
        Assert.Single(m.Assets);
        s.ResetMemory(c.ID, now);
        Assert.Empty(new MemoryBuilder(s, () => now).Build(c.ID, new()).Entries);
        Assert.Equal(2, s.Messages(c.ID).Count);
    }

    [Theory]
    [InlineData("asset")]
    [InlineData("run")]
    public void FailedImageRegistrationRemovesOnlyItsNewAssetFileAndKeepsRawRecovery(string faultStage)
    {
        using var data = new PrivateStore();
        var store = data.Store;
        var conversation = store.CreateConversation();
        var original = store.SaveImage(Fixture.PNG, conversation.ID, AssetSource.Imported);
        var unrelatedConversation = store.CreateConversation();
        var unrelated = store.SaveImage(Fixture.PNG, unrelatedConversation.ID, AssetSource.Imported);
        var run = new RunRecord
        {
            ConversationID = conversation.ID,
            Stage = RunStage.Saving
        };
        store.SaveRun(run);
        run.RecoveryRelativePath = store.SaveRawImage(Fixture.PNG, run);
        store.SaveRun(run);
        var before = Directory.EnumerateFiles(store.Paths.Assets, "*", SearchOption.AllDirectories).Order(StringComparer.Ordinal).ToArray();
        bool sawNewFile = false;
        store.BeforeWrite = stage =>
        {
            if (stage != faultStage)
                return;
            var added = Directory.EnumerateFiles(store.Paths.Assets, "*", SearchOption.AllDirectories).Except(before).ToArray();
            var file = Assert.Single(added);
            Assert.Equal(Fixture.PNG, File.ReadAllBytes(file));
            sawNewFile = true;
            throw new IOException("injected registration failure");
        };
        var failure = Assert.Throws<IOException>(() => store.SaveImage(Fixture.PNG, conversation.ID, AssetSource.Edited, original.ID, run: run));
        store.BeforeWrite = null;
        Assert.Equal("injected registration failure", failure.Message);
        Assert.True(sawNewFile);
        Assert.Equal(before, Directory.EnumerateFiles(store.Paths.Assets, "*", SearchOption.AllDirectories).Order(StringComparer.Ordinal).ToArray());
        Assert.Single(store.Assets(conversation.ID));
        Assert.Single(store.Assets(unrelatedConversation.ID));
        Assert.Equal(Fixture.PNG, File.ReadAllBytes(store.AssetPath(original)));
        Assert.Equal(Fixture.PNG, File.ReadAllBytes(store.AssetPath(unrelated)));
        Assert.Equal(Fixture.PNG, File.ReadAllBytes(store.RecoveryPath(run)!));
        Assert.Empty(store.Run(run.ID)!.ResultAssetIDs);
        Assert.Equal(RunStage.Saving, store.Run(run.ID)!.Stage);
    }

    [Fact]
    public void InterruptedRecoveryIsByteFirstAndIdempotent()
    {
        using var p = new PrivateStore();
        var s = p.Store;
        var c = s.CreateConversation();
        var r = new RunRecord
        {
            ConversationID = c.ID,
            DetailedPrompt = "validated"
        };
        s.SaveRun(r);
        s.BeforeWrite = stage =>
        {
            if (stage == "recoveryMetadata")
                throw new IOException("fault after bytes");
        };
        Assert.Throws<IOException>(() => s.SaveReceivedImage(Fixture.PNG, r));
        s.BeforeWrite = null;
        s.RecoverInterruptedRuns();
        s.RecoverInterruptedRuns();
        Assert.Equal(RunStage.Interrupted, s.Run(r.ID)!.Stage);
        Assert.Single(s.Messages(c.ID));
        Assert.Equal("validated", s.Messages(c.ID)[0].DetailedPrompt);
        Assert.Equal(Fixture.PNG, File.ReadAllBytes(s.RecoveryPath(s.Run(r.ID)!)!));
    }
}

public class ImageParityTests
{
    [Fact]
    public void EverySwiftGoldenCoverageROIMaskCompositeAndOutsideByteMatches()
    {
        var m = Fixture.Manifest;
        int w = m.GetProperty("width").GetInt32(), h = m.GetProperty("height").GetInt32();
        var bytes = Convert.FromBase64String(m.Str("sourceRGBA")!);
        var image = new PixelImage(w, h, bytes);
        foreach (var c in m.Get("cases").Array())
        {
            var selection = SwiftJson.Decode<RegionSelection>(c.Get("selection").GetRawText());
            var coverage = selection.Coverage();
            Assert.Equal(Convert.FromBase64String(c.Str("coverage")!), coverage);
            Assert.Equal(c.GetProperty("selectedPixels").GetInt32(), coverage.Count(v => v > 0));
            if (c.Get("roi").ValueKind == JsonValueKind.Undefined)
            {
                Assert.True(selection.IsEmpty);
                continue;
            }

            var snapshot = new RegionEditSnapshot(image, selection);
            Assert.Equal(SwiftJson.Decode<PixelRect>(c.Get("roi").GetRawText()), snapshot.ROI);
            var mask = PixelImage.Decode(snapshot.MaskPNG);
            for (int y = 0; y < mask.Height; y++)
                for (int x = 0; x < mask.Width; x++)
                    Assert.Equal(255 - coverage[(y + snapshot.ROI.Y) * w + x + snapshot.ROI.X], mask.RGBA[(y * mask.Width + x) * 4 + 3]);
            var patch = new PixelImage(snapshot.ROI.Width, snapshot.ROI.Height, Enumerable.Range(0, snapshot.ROI.Width * snapshot.ROI.Height).SelectMany(_ => new byte[] { 60, 160, 100, 255 }).ToArray(), image.ICC);
            var composed = snapshot.Composite(patch);
            Assert.Equal(Convert.FromBase64String(c.Str("compositeRGBA")!), composed.RGBA);
            for (int i = 0; i < coverage.Length; i++)
                if (coverage[i] == 0)
                    Assert.Equal(bytes.AsSpan(i * 4, 4).ToArray(), composed.RGBA.AsSpan(i * 4, 4).ToArray());
        }
    }

    [Fact]
    public void ClippedPenAndReverseRectangleAreCanonical()
    {
        var s = new RegionSelection(30, 20);
        s.AddRectangle(new(20, 17), new(1.2, 3.4));
        var rect = s.Marks.Single();
        Assert.Equal(new ImagePoint(1.2, 3.4), rect.Points[0]);
        s.Clear();
        s.AddPen([new(-10, -10), new(15, 2), new(40, 40), new(-5, 15)]);
        Assert.All(s.Marks.Single().Points, p => Assert.InRange(p.X, 0, 30));
        s.Undo();
        s.AddPen([new(0, 0), new(4, 4), new(8, 8)]);
        Assert.True(s.IsEmpty);
    }

    [Fact]
    public void P3ICCAndAlphaSurvivePNGAndRegionalRoundtrip()
    {
        var profile = File.ReadAllBytes(Path.Combine(Fixture.Root, "display-p3.icc"));
        var image = PixelImage.Decode(File.ReadAllBytes(Path.Combine(Fixture.Root, "display-p3.png")));
        Assert.Equal(profile, image.ICC);
        var round = PixelImage.Decode(image.PngData());
        Assert.Equal(image.ICC, round.ICC);
        Assert.Equal(image.RGBA, round.RGBA);
        var alpha = PixelImage.Decode(File.ReadAllBytes(Path.Combine(Fixture.Root, "transparent.png")));
        var selection = new RegionSelection(alpha.Width, alpha.Height);
        selection.AddRectangle(new(10, 10), new(20, 20));
        var snapshot = new RegionEditSnapshot(alpha, selection);
        var result = PixelImage.Decode(snapshot.Composite(image).PngData());
        for (int i = 0; i < snapshot.Coverage.Length; i++)
            if (snapshot.Coverage[i] == 0)
                Assert.Equal(alpha.RGBA.AsSpan(i * 4, 4).ToArray(), result.RGBA.AsSpan(i * 4, 4).ToArray());
    }

    [Theory]
    [InlineData("jpeg")]
    [InlineData("webp")]
    public void EmbeddedRGBProfileIsPreservedByteForByteAcrossFormats(string format)
    {
        var profile = File.ReadAllBytes(Path.Combine(Fixture.Root, "display-p3.icc"));
        using var b = new SkiaSharp.SKBitmap(3, 2);
        b.Erase(SkiaSharp.SKColors.Coral);
        using var image = SkiaSharp.SKImage.FromBitmap(b);
        using var encoded = image.Encode(format == "jpeg" ? SkiaSharp.SKEncodedImageFormat.Jpeg : SkiaSharp.SKEncodedImageFormat.Webp, 100);
        var raw = encoded.ToArray();
        byte[] bytes;
        if (format == "jpeg")
        {
            using var o = new MemoryStream();
            o.Write(raw, 0, 2);
            o.Write(new byte[] { 255, 226 });
            int size = profile.Length + 16;
            o.WriteByte((byte)(size >> 8));
            o.WriteByte((byte)size);
            o.Write("ICC_PROFILE\0"u8);
            o.WriteByte(1);
            o.WriteByte(1);
            o.Write(profile);
            o.Write(raw, 2, raw.Length - 2);
            bytes = o.ToArray();
        }
        else
        {
            using var payload = new MemoryStream();
            payload.Write("WEBP"u8);
            payload.Write("VP8X"u8);
            payload.Write(new byte[] { 10, 0, 0, 0, 32, 0, 0, 0, 2, 0, 0, 1, 0, 0 });
            payload.Write("ICCP"u8);
            payload.Write(BitConverter.GetBytes(profile.Length));
            payload.Write(profile);
            if (profile.Length % 2 != 0)
                payload.WriteByte(0);
            payload.Write(raw, 12, raw.Length - 12);
            using var o = new MemoryStream();
            o.Write("RIFF"u8);
            o.Write(BitConverter.GetBytes((int)payload.Length));
            o.Write(payload.ToArray());
            bytes = o.ToArray();
        }

        var decoded = PixelImage.Decode(bytes);
        Assert.Equal(profile, decoded.ICC);
        var round = PixelImage.Decode(decoded.PngData());
        Assert.Equal(profile, round.ICC);
        Assert.Equal(decoded.RGBA, round.RGBA);
    }

    [Fact]
    public void AllSwiftEXIFOrientationsPreserveP3AndPixels()
    {
        var m = SwiftJson.Parse(File.ReadAllText(Path.Combine(Fixture.Root, "orientation-manifest.json")));
        foreach (var c in m.Array())
        {
            var image = PixelImage.Decode(File.ReadAllBytes(Path.Combine(Fixture.Root, c.Str("file")!)));
            Assert.Equal(c.GetProperty("width").GetInt32(), image.Width);
            Assert.Equal(c.GetProperty("height").GetInt32(), image.Height);
            Assert.Equal(Convert.FromBase64String(c.Str("rgba")!), image.RGBA);
            Assert.Equal(File.ReadAllBytes(Path.Combine(Fixture.Root, "display-p3.icc")), image.ICC);
        }
    }

    [Fact]
    public void TruncatedPNGsAndInvalidSelectionsAreRejected()
    {
        Assert.Throws<AgentException>(() => new DecodedImage(Fixture.PNG[..^12]));
        Assert.Throws<AgentException>(() => SwiftJson.Decode<RegionSelection>("{\"width\":10,\"height\":10,\"marks\":[{\"rectangle\":{\"_0\":{\"x\":9,\"y\":1},\"_1\":{\"x\":1,\"y\":2}}}]}"));
    }
}

public class StreamingTests
{
    [Theory]
    [InlineData("0.0")]
    [InlineData("0e0")]
    public void IntegralNumericSSEIndexesMatchSwiftNumberSemantics(string index)
    {
        var decoder = new ResponsesStreamDecoder();
        var added = "data: {\"type\":\"response.output_item.added\",\"output_index\":" + index + ",\"item\":" + Fixture.Call("").GetRawText() + "}\n\n";
        decoder.Append(Encoding.UTF8.GetBytes(added));
        var args = Fixture.Plan();
        decoder.Append(Fixture.Event("response.completed", new { response = SwiftJson.Parse(Fixture.Completed(args)) }));
        Assert.Equal(args, decoder.Finish().ToolCalls.Single().Arguments);
    }

    [Fact]
    public void FragmentedUTF8EscapesCRLFDeliverPromptBeforeCompleted()
    {
        var args = Fixture.Plan(prompt: "你\n好 🌄");
        var d = new ResponsesStreamDecoder();
        var events = new List<byte[]>
        {
            Fixture.Event("response.output_item.added", new { output_index = 0, item = Fixture.Call("") })
        };
        foreach (char ch in args)
            events.Add(Fixture.Event("response.function_call_arguments.delta", new { output_index = 0, item_id = "item", delta = ch.ToString() }));
        var previews = new List<string>();
        foreach (var b in events.SelectMany(e => e))
            previews.AddRange(d.Append(new[] { b }));
        Assert.Contains("你\n好 🌄", previews);
        Assert.Throws<AgentException>(() => d.Finish());
        d.Append(Fixture.Event("response.completed", new { response = SwiftJson.Parse(Fixture.Completed(args)) }));
        Assert.Equal(args, d.Finish().ToolCalls.Single().Arguments);
    }

    [Theory]
    [InlineData("data: [DONE]\n\n")]
    [InlineData("data: {\"type\":\"response.function_call_arguments.done\",\"output_index\":0,\"item_id\":\"item\",\"arguments\":\"{}\"}\n\n")]
    public void DoneAndArgumentsDoneNeverAuthorizeImages(string data)
    {
        var d = new ResponsesStreamDecoder();
        Assert.Throws<AgentException>(() =>
        {
            d.Append(Encoding.UTF8.GetBytes(data));
            d.Finish();
        });
    }

    [Fact]
    public void IdentityMutationAndDuplicateArgumentsRejected()
    {
        var d = new ResponsesStreamDecoder();
        d.Append(Fixture.Event("response.output_item.added", new { output_index = 0, item = Fixture.Call("") }));
        Assert.Throws<AgentException>(() => d.Append(Fixture.Event("response.output_item.done", new { output_index = 0, item = Fixture.Call("{}", "foreign") })));
        var scanner = new PromptScanner();
        Assert.Throws<AgentException>(() => scanner.Append("{\"prompt\":\"a\",\"prompt\":\"b\"}"));
    }

    [Fact]
    public void CompletedNestedStatusAndFinalArgumentsMustAgree()
    {
        var args = Fixture.Plan();
        var d = new ResponsesStreamDecoder();
        d.Append(Fixture.Event("response.output_item.added", new { output_index = 0, item = Fixture.Call(args) }));
        Assert.Throws<AgentException>(() => d.Append(Fixture.Event("response.completed", new { response = SwiftJson.Parse(Fixture.Completed(Fixture.Plan(prompt: "different"))) })));
        var second = new ResponsesStreamDecoder();
        Assert.Throws<AgentException>(() => second.Append(Fixture.Event("response.completed", new { response = new { status = "incomplete", output = new[] { Fixture.Call(args) } } })));
    }

    [Theory]
    [InlineData("message")]
    [InlineData("reasoning")]
    [InlineData(null)]
    public void FinalObservedFunctionCannotBecomeAnotherTypeWhileTheOnlyFunctionMovesIndex(string? finalType)
    {
        var observedArguments = Fixture.Plan(prompt: "observed prompt");
        var movedArguments = Fixture.Plan(prompt: "unobserved replacement prompt");
        var decoder = new ResponsesStreamDecoder();
        decoder.Append(Fixture.Event("response.output_item.added", new { output_index = 0, item = Fixture.Call(observedArguments) }));
        var nonFunction = JsonSerializer.SerializeToElement(new { type = finalType, id = "item", name = "prepare_image_request", call_id = "call", arguments = observedArguments });
        var movedFunction = Fixture.Call(movedArguments, "moved_item", "moved_call");
        var final = new ResponseResult([nonFunction, movedFunction], "completed");
        Assert.Single(final.ToolCalls);
        Assert.Equal(movedArguments, final.ToolCalls[0].Arguments);
        var completed = Fixture.Event("response.completed", new { response = new { status = "completed", output = final.Output } });
        Assert.Throws<AgentException>(() =>
        {
            decoder.Append(completed);
            decoder.Finish();
        });
    }

    [Fact]
    public void NativeDedupPreservesSameIDDifferentBytesAndFullJsonRecovery()
    {
        var one = Fixture.PNG;
        var two = PixelImage.Decode(one).Resize(24, 24, PixelImage.Decode(one).ICC).PngData();
        var output = new[]
        {
            new
            {
                type = "image_generation_call",
                id = "same",
                result = Convert.ToBase64String(one)
            },
            new
            {
                type = "image_generation_call",
                id = "same",
                result = Convert.ToBase64String(two)
            },
            new
            {
                type = "image_generation_call",
                id = "other",
                result = Convert.ToBase64String(one)
            }
        };
        var d = new ResponsesStreamDecoder();
        d.Append(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { status = "completed", output })));
        Assert.Equal(2, d.Partial.NativeOutputs.Length);
        Assert.Equal(2, d.Finish().RecoverImages().Images.Count);
    }

    [Fact]
    public void CrossFragmentCredentialSuffixesStayHidden()
    {
        var c = new APIClient("https://offline.invalid", "test-secret-123");
        var input = "hello test-secret-123 Bearer sensitive sk-abcdefghi";
        for (int i = 1; i <= input.Length; i++)
        {
            var preview = c.StreamingPreview(input[..i]);
            Assert.DoesNotContain("test-secret", preview);
            Assert.DoesNotContain("sensitive", preview);
            Assert.DoesNotContain("abcdefghi", preview);
        }

        Assert.Equal("hello [已隐藏]", c.Sanitize("hello test-secret-123"));
    }
}

public sealed class ClipboardEncodingTests
{
    [Fact]
    public void NativeBitmapAndSingleFrameGifNormalizeToPNG()
    {
        var bmp = new byte[58];
        bmp[0] = (byte)'B';
        bmp[1] = (byte)'M';
        BitConverter.GetBytes(58).CopyTo(bmp, 2);
        BitConverter.GetBytes(54).CopyTo(bmp, 10);
        BitConverter.GetBytes(40).CopyTo(bmp, 14);
        BitConverter.GetBytes(1).CopyTo(bmp, 18);
        BitConverter.GetBytes(1).CopyTo(bmp, 22);
        bmp[26] = 1;
        bmp[28] = 24;
        bmp[55] = 255;
        var png = DecodedImage.ClipboardBytes(bmp);
        Assert.Equal("image/png", new DecodedImage(png).MediaType);
        Assert.Equal(new byte[] { 0, 255, 0, 255 }, PixelImage.Decode(png).RGBA);
        var gif = Convert.FromBase64String("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7");
        Assert.Equal("image/png", new DecodedImage(DecodedImage.ClipboardBytes(gif)).MediaType);
        var animated = gif[..^1].Concat(gif[19..^1]).Append((byte)59).ToArray();
        Assert.Throws<AgentException>(() => DecodedImage.ClipboardBytes(animated));
    }
}
