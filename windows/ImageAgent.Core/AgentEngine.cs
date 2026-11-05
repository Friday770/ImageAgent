using System.Text;
using System.Text.Json;

namespace ImageAgent.Core;
public interface IImageReplyFinalizer
{
    string Finalize(IReadOnlyList<AssetRecord> assets, string caption);
}

public sealed class LocalImageReplyFinalizer : IImageReplyFinalizer
{
    public string Finalize(IReadOnlyList<AssetRecord> assets, string caption)
    {
        if (assets.Count == 0)
            throw new AgentException("没有已保存的图片可供交付。");
        var s = assets[0].Source == AssetSource.Edited ? "图片已编辑并保存在本机。" : "图片已生成并保存在本机。";
        return caption.Trim().Length == 0 ? s : s + "\n\n" + caption.Trim();
    }
}

public sealed class AgentEngine(SQLiteStore store, APIClient client, Func<DateTimeOffset>? clock = null, IImageReplyFinalizer? finalizer = null)
{
    readonly HashSet<string> active = [];
    DateTimeOffset Now() => (clock ?? (() => DateTimeOffset.UtcNow))();
    public async Task<RunOutcome> Submit(AgentRequest original, MemoryPolicy? policy = null, Action<RunRecord>? progress = null, Action<PlanningPreview>? planningPreview = null, CancellationToken ct = default)
    {
        var selection = original.RegionEdit == null ? original.Selection : original.Selection with
        {
            Size = "auto"
        };
        selection.Validate();
        var immutableRegion = original.RegionEdit == null ? null : SwiftJson.Decode<RegionEditRequest>(SwiftJson.Encode(original.RegionEdit));
        var request = original with
        {
            Selection = selection,
            ReferenceAssetID = immutableRegion?.AssetID ?? original.ReferenceAssetID,
            RegionEdit = immutableRegion
        };
        if (original.RegionEdit != null && original.ReferenceAssetID != null && original.ReferenceAssetID != original.RegionEdit.AssetID)
            throw new AgentException("局部编辑目标与参考图片不一致。");
        lock (active)
        {
            if (!active.Add(request.ConversationID))
                throw new AgentException("此会话已有任务正在运行。");
        }

        try
        {
            return await Execute(request, policy ?? new(), progress ?? (_ =>
            {
            }), planningPreview ?? (_ =>
            {
            }), ct).ConfigureAwait(false);
        }
        finally
        {
            lock (active)
                active.Remove(request.ConversationID);
        }
    }

    async Task<RunOutcome> Execute(AgentRequest request, MemoryPolicy policy, Action<RunRecord> progress, Action<PlanningPreview> preview, CancellationToken ct)
    {
        var text = client.Sanitize(request.Text.Trim());
        if (text.Length == 0 || TextElements.Count(text) > 8000)
            throw new AgentException("请输入 1–8000 字的需求。");
        var context = new MemoryBuilder(store, Now).Build(request.ConversationID, policy, request.ReferenceAssetID);
        RegionEditSnapshot? snapshot = null;
        if (request.RegionEdit is { } region)
        {
            _ = SwiftJson.Decode<RegionEditRequest>(SwiftJson.Encode(region));
            var a = store.Asset(region.AssetID);
            if (a == null || a.ConversationID != request.ConversationID)
                throw new AgentException("要编辑的图片已删除，或不属于原会话。");
            snapshot = new(PixelImage.Decode(File.ReadAllBytes(store.AssetPath(a))), region.Selection);
        }

        var now = Now();
        var run = new RunRecord
        {
            ConversationID = request.ConversationID,
            Request = text,
            Selection = request.Selection,
            PlannerModel = client.SelectedPlannerModel,
            RegionEdit = request.RegionEdit,
            CreatedAt = now,
            UpdatedAt = now
        };
        store.AddMessage(new() { ConversationID = request.ConversationID, Role = MessageRole.User, Text = client.Sanitize(request.Text), AssetIDs = request.ReferenceAssetID == null ? [] : [request.ReferenceAssetID], RunID = run.ID, CreatedAt = now });
        store.SaveRun(run);
        progress(run with { });
        var saved = new List<AssetRecord>();
        bool planningCancelled = false;
        void SaveStage(RunStage stage)
        {
            run.Stage = stage;
            run.UpdatedAt = Now();
            store.SaveRun(run);
            progress(run with { });
        }

        void Recover(ResponseResult response)
        {
            var recovery = response.RecoverImages();
            for (int i = 0; i < recovery.Images.Count; i++)
            {
                var image = recovery.Images[i];
                string name = "native-" + (i + 1);
                run.RecoveryRelativePath = $"recovery/{run.ID}/{name}.{image.Extension}";
                store.SaveRawImage(image.Data, run, name);
            }

            if (recovery.Images.Count > 0)
                store.SaveRecoveryMetadata(run, snapshot, request.RegionEdit?.AssetID, false);
            foreach (var image in recovery.Images)
            {
                SaveStage(RunStage.Saving);
                var a = store.SaveImage(image.Data, request.ConversationID, AssetSource.Generated, request.ReferenceAssetID, selection: request.Selection, modelVerified: false, run: run, now: Now());
                saved.Add(a);
                run.ResultAssetIDs = [..saved.Select(a => a.ID)];
            }

            throw new AgentException("服务返回了未预期的内置图片工具输出，实际图片模型和提示词未验证。" + (snapshot == null ? "" : "此输出未完成局部合成，不是已完成的选区编辑。") + (saved.Count == 0 ? "没有可恢复的有效图片。" : "现有图片已保存。") + "未额外调用图片接口。\n" + string.Join("\n", recovery.Failures));
        }

        try
        {
            ct.ThrowIfCancellationRequested();
            ResponseResult response;
            try
            {
                response = await client.Respond(MakeInput(context, request, text), request.Selection, s => preview(new(request.ConversationID, run.ID, s)), ct).ConfigureAwait(false);
            }
            catch (ResponseStreamException failure)
            {
                planningCancelled = failure.WasCancelled;
                Recover(failure.Partial);
                throw;
            }

            if (response.NativeOutputs.Length > 0)
                Recover(response);
            ct.ThrowIfCancellationRequested();
            if (response.ToolCalls.Length != 1)
                throw new AgentException("规划模型必须返回一个 prepare_image_request 函数计划；未执行图片请求。");
            var plan = Validate(response.ToolCalls[0], request.Selection, context, request.RegionEdit?.AssetID);
            string finalText;
            if (plan.Action == "reply")
                finalText = plan.Reply;
            else
            {
                run.DetailedPrompt = plan.Prompt;
                SaveStage(plan.Action == "edit" ? RunStage.Editing : RunStage.Generating);
                ct.ThrowIfCancellationRequested();
                DecodedImage image;
                if (plan.Reference is { } reference)
                {
                    if (store.Asset(reference.ID)?.ConversationID != request.ConversationID || store.Conversation(request.ConversationID) == null)
                        throw new AgentException("要编辑的图片或原会话已删除；未执行图片请求。");
                    image = await client.Edit(plan.Prompt, request.Selection, snapshot?.ImagePNG ?? File.ReadAllBytes(store.AssetPath(reference)), snapshot?.MaskPNG, ct).ConfigureAwait(false);
                }
                else
                    image = await client.Generate(plan.Prompt, request.Selection, ct).ConfigureAwait(false);
                run.RecoveryRelativePath = $"recovery/{run.ID}/patch.{image.Extension}";
                store.SaveReceivedImage(image.Data, run, snapshot: snapshot, sourceAssetID: request.RegionEdit?.AssetID);
                SaveStage(RunStage.Saving);
                var bytes = snapshot == null ? image.Data : snapshot.Composite(PixelImage.Decode(image.Data)).PngData();
                var asset = store.SaveImage(bytes, request.ConversationID, plan.Reference == null ? AssetSource.Generated : AssetSource.Edited, plan.Reference?.ID, plan.Prompt, request.Selection, run: run, now: Now());
                saved.Add(asset);
                run.ResultAssetIDs = [asset.ID];
                SaveStage(RunStage.Finalizing);
                ct.ThrowIfCancellationRequested();
                finalText = (finalizer ?? new LocalImageReplyFinalizer()).Finalize(saved, plan.Reply);
            }

            run.Stage = RunStage.Completed;
            run.UpdatedAt = Now();
            store.SaveRun(run);
            var m = new MessageRecord
            {
                ConversationID = request.ConversationID,
                Role = MessageRole.Assistant,
                Text = client.Sanitize(finalText),
                AssetIDs = run.ResultAssetIDs,
                DetailedPrompt = run.DetailedPrompt,
                RunID = run.ID,
                CreatedAt = Now()
            };
            store.AddMessage(m);
            progress(run with { });
            return new(run, m, saved);
        }
        catch (Exception error)
        {
            bool cancelled = error is OperationCanceledException || ct.IsCancellationRequested || planningCancelled;
            run.Stage = cancelled ? RunStage.Cancelled : RunStage.Failed;
            run.UpdatedAt = Now();
            run.Error = cancelled ? "任务已取消。远端请求可能已执行；不会自动重试。" : client.SafeDescription(error);
            if (planningCancelled)
                run.Error += "\n已收到的内置图片模型和提示词未验证；有效字节已保留。";
            if (run.RecoveryRelativePath != null)
            {
                try
                {
                    if (store.RecoveryPath(run) != null)
                        run.Error += "\n已返回的图片已保留，可查看恢复文件；请勿重复提交本次请求。";
                }
                catch (AgentException)
                {
                }
            }

            if (saved.Count == 0)
                saved = store.Assets(request.ConversationID).Where(a => a.RunID == run.ID).ToList();
            run.ResultAssetIDs = [..saved.Select(a => a.ID)];
            store.SaveRun(run);
            var m = new MessageRecord
            {
                ConversationID = request.ConversationID,
                Role = MessageRole.Assistant,
                Text = (saved.Count == 0 ? "" : "图片已保存。" + (cancelled ? "后续回复已取消。" : "最终回复未完成。") + "\n") + run.Error,
                AssetIDs = run.ResultAssetIDs,
                DetailedPrompt = run.DetailedPrompt,
                RunID = run.ID,
                CreatedAt = Now()
            };
            store.AddMessage(m);
            progress(run with { });
            return new(run, m, saved);
        }
    }

    record Plan(string Action, string Prompt, AssetRecord? Reference, string Reply);
    Plan Validate(ToolCall call, ImageSelection selection, MemoryContext context, string? regionAssetID)
    {
        if (call.Name != "prepare_image_request" || call.CallID.Length == 0 || TextElements.Count(call.CallID) >= 256 || Encoding.UTF8.GetByteCount(call.Arguments) > 200000)
            throw new AgentException("规划模型未返回有效的 prepare_image_request 计划。");
        var e = SwiftJson.Parse(call.Arguments);
        var required = new[]
        {
            "action",
            "prompt",
            "model",
            "size",
            "quality",
            "reference_image_id",
            "reply_text"
        };
        if (e.ValueKind != JsonValueKind.Object || !e.EnumerateObject().Select(p => p.Name).Order().SequenceEqual(required.Order()))
            throw new AgentException("图片计划字段无效；未执行图片请求。");
        var action = e.Str("action");
        var prompt = e.Str("prompt");
        var reply = e.Str("reply_text");
        if (action is not ("generate" or "edit" or "reply") || prompt == null || TextElements.Count(prompt) > 32000 || Encoding.UTF8.GetByteCount(prompt) > 128000 || reply == null || TextElements.Count(reply) > 4000 || e.Str("model") != selection.Model || e.Str("size") != selection.Size || e.Str("quality") != selection.Quality)
            throw new AgentException("图片计划参数无效，或与所选模型、尺寸、质量不一致；未执行图片请求。");
        AssetRecord? reference = null;
        if (e.Str("reference_image_id")is { } id)
        {
            reference = context.Assets.FirstOrDefault(a => a.ID == id);
            if (reference == null || !File.Exists(store.AssetPath(reference)))
                throw new AgentException("计划引用了未知、过期或其他会话的图片；未执行编辑请求。");
        }
        else if (e.Get("reference_image_id").ValueKind != JsonValueKind.Null)
            throw new AgentException("参考图片参数必须是有效 ID 或 null。");
        if (regionAssetID != null && (action != "edit" || reference?.ID != regionAssetID))
            throw new AgentException("局部编辑计划必须编辑工作区对应的原图，不能更换目标或动作；未执行图片请求。");
        if (action == "generate" && reference != null || action == "edit" && reference == null || action != "reply" && string.IsNullOrWhiteSpace(prompt) || action == "reply" && (string.IsNullOrWhiteSpace(reply) || prompt.Length != 0))
            throw new AgentException("图片计划动作、参考或提示词无效；未执行图片请求。");
        return new(action, client.Sanitize(prompt), reference, client.Sanitize(reply));
    }

    object[] MakeInput(MemoryContext context, AgentRequest request, string text)
    {
        var refs = string.Join("\n", context.Assets.Select(a => $"{a.ID} ({a.Width}×{a.Height})"));
        var system = $"你仅是 ImageAgent 的文字规划器，不直接生成图片。必须且只能调用一次 prepare_image_request 函数，禁止使用 image_generation 或任何其他内置图片工具。\n理解自然语言需求与当前会话记忆后选择 action：新画面用 generate，修改已有作品/保留参考内容用 edit，普通讨论用 reply。App 负责校验计划、调用图片 API、保存图片和本地完成回复。\nmodel={request.Selection.Model}、size={request.Selection.Size}、quality={request.Selection.Quality} 必须原样传入，不得替换。\ngenerate/edit 的 prompt 必须是完整、明确、可直接执行的详细提示词，保留用户限制、主体特征和连续编辑意图。generate 的 reference_image_id=null；edit 必须使用下列有效 ID。reply 的 prompt 为空，reply_text 为完整讨论回复；图片任务的 reply_text 仅填写简短作品说明，完成保存后 App 才展示。\n主动选定的参考图：{request.ReferenceAssetID ?? "无；按上下文选择最近有效作品"}。\n有效参考图：\n{(refs.Length == 0 ? "无" : refs)}\n不得编造图片 ID、文件路径、模型名或命令。不使用服务器会话存储。用用户的语言回复。";
        if (request.RegionEdit is { } region)
            system += $"\n本次是固定目标的局部编辑。必须 action=edit，reference_image_id={region.AssetID}，禁止 generate/reply 或改用任何其他图片。App 只发送用户选区及少量周边的裁图与 alpha 遮罩；透明部分为允许修改区域，其他像素保留。请将用户修改要求扩写为裁图内的编辑提示词，并保持未选中的上下文一致。最终由 App 合成到完整原图。";
        var input = new List<object>
        {
            new
            {
                role = "system",
                content = system
            }
        };
        input.AddRange(context.Entries.Select(e => (object)new { role = e.Role == MessageRole.User ? "user" : "assistant", content = client.Sanitize(e.Text) }));
        input.Add(new { role = "user", content = text });
        return input.ToArray();
    }
}
