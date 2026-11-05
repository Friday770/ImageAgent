namespace ImageAgent.Core;

public record ComposerDraft(string Text = "", string? ReferenceID = null);
public record EditorTarget(string ConversationID, string AssetID);
public enum EditorTool
{
    Pan,
    Pen,
    Rectangle
}

public record EditorDraft(RegionSelection Selection, string Prompt, EditorTool Tool = EditorTool.Pen);
public record WorkspaceSession(Guid ID, EditorTarget Target);
public record PromptState(string ConversationID, string RunID, string Text, string Status);
public sealed class WorkspaceState
{
    public SQLiteStore Store
    {
        get;
    }

    readonly ICredentialStore credentials;
    readonly IHTTPTransport transport;
    AgentEngine? engine;
    CancellationTokenSource? submission;
    readonly Dictionary<string, ComposerDraft> drafts = [];
    readonly Dictionary<EditorTarget, EditorDraft> editorDrafts = [];
    readonly Dictionary<EditorTarget, RunRecord> failures = [];
    bool accepted;
    Guid? submissionID;
    readonly Action<Action> dispatch;
    public event Action? Changed;
    void Notify() => Changed?.Invoke();
    public AppSettings Settings
    {
        get; private set;
    }
    public List<Conversation> Conversations { get; private set; } = [];
    public List<MessageRecord> Messages { get; private set; } = [];
    public List<AssetRecord> Assets { get; private set; } = [];
    public List<RunRecord> Runs { get; private set; } = [];
    public string? SelectedID
    {
        get; private set;
    }
    public string Draft { get; set; } = "";
    public string? ReferenceID
    {
        get; set;
    }
    public string? Error
    {
        get; set;
    }
    public string? ConnectionError
    {
        get; private set;
    }
    public string ConnectionNote { get; private set; } = "";
    public bool HasConnection
    {
        get; private set;
    }
    public bool IsConnecting
    {
        get; private set;
    }
    public bool IsBusy
    {
        get; private set;
    }
    public bool IsCancelling
    {
        get; private set;
    }
    public string? ActiveConversationID
    {
        get; private set;
    }
    public RunRecord? ActiveRun
    {
        get; private set;
    }
    public PromptState? PlanningPrompt
    {
        get; private set;
    }
    public WorkspaceSession? Workspace
    {
        get; private set;
    }
    public EditorTarget? FailedEditorTarget
    {
        get; private set;
    }
    public bool CanSend => Workspace == null && HasConnection && !IsBusy && !IsConnecting && SelectedID != null && !string.IsNullOrWhiteSpace(Draft);

    public WorkspaceState(SQLiteStore store, ICredentialStore credentials, IHTTPTransport transport, Action<Action>? dispatcher = null)
    {
        Store = store;
        this.credentials = credentials;
        this.transport = transport;
        dispatch = dispatcher ?? (a => a());
        Settings = store.Settings();
        store.RecoverInterruptedRuns();
        Refresh();
    }

    public void Refresh()
    {
        Conversations = Store.Conversations();
        if (SelectedID == null || Conversations.All(c => c.ID != SelectedID))
            Select(Conversations.FirstOrDefault()?.ID, false);
        if (SelectedID is { } id)
        {
            Messages = Store.Messages(id);
            Assets = Store.Assets(id);
            Runs = Store.Runs(id);
        }
        else
        {
            Messages = [];
            Assets = [];
            Runs = [];
        }

        Notify();
    }

    public void Select(string? id, bool refresh = true, bool allowWorkspace = false)
    {
        if (Workspace != null && id != SelectedID && !allowWorkspace)
            return;
        if (id == SelectedID)
            return;
        if (SelectedID != null)
            drafts[SelectedID] = new(Draft, ReferenceID);
        SelectedID = id;
        var d = id == null ? null : drafts.GetValueOrDefault(id);
        Draft = d?.Text ?? "";
        ReferenceID = d?.ReferenceID;
        if (refresh)
            Refresh();
    }

    public void NewConversation()
    {
        if (Workspace != null)
            return;
        var c = Store.CreateConversation();
        Select(c.ID);
    }

    public void DeleteConversation(string id)
    {
        if (Workspace != null || IsBusy && ActiveConversationID == id)
            throw new AgentException("活动来源会话无法删除。");
        Store.DeleteConversation(id);
        drafts.Remove(id);
        foreach (var t in editorDrafts.Keys.Where(t => t.ConversationID == id).ToArray())
            editorDrafts.Remove(t);
        foreach (var t in failures.Keys.Where(t => t.ConversationID == id).ToArray())
            failures.Remove(t);
        if (FailedEditorTarget?.ConversationID == id)
            FailedEditorTarget = null;
        Refresh();
    }

    public async Task RestoreConnection()
    {
        if (IsConnecting)
            return;
        IsConnecting = true;
        Notify();
        try
        {
            var endpoint = new ServiceEndpoint(Settings.Endpoint);
            var key = await Task.Run(() => credentials.Key(endpoint.String));
            if (key != null)
            {
                engine = new(Store, new APIClient(endpoint.String, key, Settings.PlannerModel, transport));
                HasConnection = true;
                ConnectionNote = "已恢复保存的连接";
                if (Conversations.Count == 0)
                    NewConversation();
            }
        }
        catch (Exception e)
        {
            Error = "无法恢复已保存的连接：" + e.Message;
            ConnectionError = Error;
        }
        finally
        {
            IsConnecting = false;
            Notify();
        }
    }

    public async Task<bool> SaveConnection(string address, string input, string planner, CancellationToken ct = default)
    {
        if (IsBusy || IsConnecting)
        {
            ConnectionError = "请等待当前任务或连接操作完成，再保存 API 设置。";
            Notify();
            return false;
        }

        IsConnecting = true;
        ConnectionError = null;
        Error = null;
        ConnectionNote = "正在验证并保存连接…";
        Notify();
        APIClient? candidate = null;
        try
        {
            var endpoint = new ServiceEndpoint(address);
            var p = PlannerModel.Validate(planner);
            var entered = input.Trim();
            var old = await Task.Run(() => credentials.Key(endpoint.String), ct);
            ct.ThrowIfCancellationRequested();
            if (old != null && p.Contains(old, StringComparison.Ordinal))
                throw new AgentException("规划模型 ID 不能包含 API 凭据。");
            var key = entered.Length == 0 ? old : entered;
            if (key == null)
                throw new AgentException("请输入此服务的 API Key；空白只会复用这个地址自己保存的 Key。");
            candidate = new(address, key, p, transport);
            var models = await candidate.ValidateConnection(ct);
            ct.ThrowIfCancellationRequested();
            bool writes = entered.Length > 0 && entered != old;
            if (writes)
                await Task.Run(() => credentials.Save(key, endpoint.String), ct);
            try
            {
                ct.ThrowIfCancellationRequested();
                var next = Settings with
                {
                    Endpoint = endpoint.String,
                    PlannerModel = p
                };
                Store.SaveSettings(next);
                Settings = next;
            }
            catch
            {
                if (writes)
                {
                    try
                    {
                        await Task.Run(() =>
                        {
                            if (old == null)
                                credentials.Delete(endpoint.String);
                            else
                                credentials.Save(old, endpoint.String);
                        });
                    }
                    catch
                    {
                        throw new AgentException("API 设置未切换；恢复候选地址的系统凭据失败。请在系统允许访问后重新保存该地址。原连接和历史仍保留。");
                    }
                }

                throw;
            }

            engine = new(Store, candidate);
            HasConnection = true;
            ConnectionNote = $"连接已保存 · {models.Length} 个可见模型";
            if (Conversations.Count == 0)
                NewConversation();
            return true;
        }
        catch (Exception e)
        {
            ConnectionError = candidate?.SafeDescription(e) ?? e.Message.Replace(input.Length == 0 ? "\0" : input, "[已隐藏]", StringComparison.Ordinal);
            Error = ConnectionError;
            ConnectionNote = "";
            return false;
        }
        finally
        {
            IsConnecting = false;
            Notify();
        }
    }

    public async Task<string?> SavedKey(string address)
    {
        var ep = new ServiceEndpoint(address).String;
        if (ep != Settings.Endpoint)
            return null;
        var key = await Task.Run(() => credentials.Key(ep));
        return ep == Settings.Endpoint ? key : null;
    }

    public async Task<string[]> PlannerModels(string address, string input, CancellationToken ct = default)
    {
        if (IsBusy || IsConnecting)
            throw new AgentException("请等待任务或连接保存完成。");
        var ep = new ServiceEndpoint(address);
        var key = string.IsNullOrWhiteSpace(input) ? await Task.Run(() => credentials.Key(ep.String), ct) : input.Trim();
        ct.ThrowIfCancellationRequested();
        if (IsBusy || IsConnecting)
            throw new AgentException("请等待任务或连接保存完成。");
        if (key == null)
            throw new AgentException("请输入此服务的 API Key 后刷新模型列表。");
        var client = new APIClient(ep.String, key, transport: transport);
        return await client.ValidateConnection(ct);
    }

    public async Task Disconnect()
    {
        if (IsBusy || IsConnecting)
            return;
        IsConnecting = true;
        Notify();
        try
        {
            await Task.Run(() => credentials.Delete(new ServiceEndpoint(Settings.Endpoint).String));
            HasConnection = false;
            engine = null;
            ConnectionError = null;
            ConnectionNote = "";
        }
        catch (Exception e)
        {
            ConnectionError = e.Message;
        }
        finally
        {
            IsConnecting = false;
            Notify();
        }
    }

    public void SetSelection(ImageSelection selection)
    {
        selection.Validate();
        var next = Settings with
        {
            Selection = selection
        };
        Store.SaveSettings(next);
        Settings = next;
        Notify();
    }

    public void SetMemory(MemoryPolicy policy)
    {
        var next = Settings with
        {
            Memory = policy
        };
        Store.SaveSettings(next);
        Settings = next;
        Notify();
    }

    public void ResetMemory()
    {
        if (Workspace != null || IsBusy || SelectedID == null)
            return;
        Store.ResetMemory(SelectedID);
        Refresh();
    }

    public bool ImportReference(byte[] bytes)
    {
        if (IsBusy || IsConnecting || Workspace != null || SelectedID == null)
            return Fail("请先等待当前任务或连接保存完成，并关闭图片工作区，再添加参考图。");
        if (ReferenceID != null)
            return Fail("已有未发送的参考图。请先发送或移除该附件，再添加图片。");
        try
        {
            var data = DecodedImage.ClipboardBytes(bytes);
            var a = Store.SaveImage(data, SelectedID, AssetSource.Imported);
            ReferenceID = a.ID;
            Error = null;
            Refresh();
            return true;
        }
        catch (Exception e)
        {
            return Fail(e.Message);
        }
    }

    public bool UseReference(AssetRecord a)
    {
        if (IsBusy || IsConnecting)
            return Fail("请等待当前任务或连接保存完成，再选择参考图。");
        try
        {
            _ = EditorAsset(a.ID, a.ConversationID);
            var existing = SelectedID == a.ConversationID ? ReferenceID : drafts.GetValueOrDefault(a.ConversationID)?.ReferenceID;
            if (existing != null && existing != a.ID)
                throw new AgentException("来源会话已有另一张未发送的参考图。请先发送或移除该附件，再添加评论。");
            if (Workspace != null && Workspace.Target != new EditorTarget(a.ConversationID, a.ID))
                throw new AgentException("图片工作区已切换，请在当前图片中添加评论。");
            Select(a.ConversationID, allowWorkspace: true);
            ReferenceID = a.ID;
            Error = null;
            Notify();
            return true;
        }
        catch (Exception e)
        {
            return Fail(e.Message);
        }
    }

    bool Fail(string s)
    {
        Error = s;
        Notify();
        return false;
    }

    public AssetRecord EditorAsset(string id, string conversationID)
    {
        var a = Store.Asset(id);
        if (Store.Conversation(conversationID) == null || a == null || a.ConversationID != conversationID)
            throw new AgentException("原图片或原会话已删除，或图片不属于该会话。");
        if (!File.Exists(Store.AssetPath(a)))
            throw new AgentException("原始图片文件不可用。");
        return a;
    }

    public bool OpenWorkspace(AssetRecord a)
    {
        try
        {
            _ = EditorAsset(a.ID, a.ConversationID);
            Workspace = new(Guid.NewGuid(), new(a.ConversationID, a.ID));
            Notify();
            return true;
        }
        catch (Exception e)
        {
            return Fail(e.Message);
        }
    }

    public void CloseWorkspace(Guid? id = null)
    {
        if (id != null && Workspace?.ID != id)
            return;
        Workspace = null;
        Notify();
    }

    public EditorDraft? GetEditorDraft(EditorTarget target) => editorDrafts.GetValueOrDefault(target);
    public RunRecord? GetEditorFailure(EditorTarget t) => failures.GetValueOrDefault(t);
    public void RetainEditorDraft(EditorTarget target, EditorDraft draft, Guid session)
    {
        if (Workspace?.ID != session || Workspace.Target != target)
            return;
        editorDrafts[target] = draft with
        {
            Selection = draft.Selection.Clone()
        };
    }

    public void ReopenFailedEditor()
    {
        if (FailedEditorTarget is { } t)
        {
            try
            {
                OpenWorkspace(EditorAsset(t.AssetID, t.ConversationID));
            }
            catch (Exception e)
            {
                Fail(e.Message);
            }
        }
    }

    Guid Begin(string id)
    {
        var token = Guid.NewGuid();
        submissionID = token;
        accepted = false;
        IsBusy = true;
        IsCancelling = false;
        ActiveConversationID = id;
        ActiveRun = null;
        PlanningPrompt = null;
        submission = new();
        Notify();
        return token;
    }

    void Progress(RunRecord run, Guid id, Action? onAccepted = null)
    {
        if (submissionID != id || ActiveConversationID != run.ConversationID)
            return;
        if (ActiveRun is { } old && (old.ID != run.ID || old.Stage.IsTerminal() || run.Stage.Order() < old.Stage.Order()))
            return;
        ActiveRun = run;
        if (run.Stage.IsTerminal())
        {
            if (run.DetailedPrompt != null || run.Stage == RunStage.Completed)
                PlanningPrompt = null;
            else if (PlanningPrompt?.RunID == run.ID)
                PlanningPrompt = PlanningPrompt with
                {
                    Status = "unfinished"
                };
        }
        else if (!string.IsNullOrEmpty(run.DetailedPrompt))
            PlanningPrompt = new(run.ConversationID, run.ID, run.DetailedPrompt, "validated");
        if (!accepted)
        {
            accepted = true;
            onAccepted?.Invoke();
        }

        Refresh();
    }

    void Preview(PlanningPreview p, Guid id)
    {
        if (submissionID != id || ActiveConversationID != p.ConversationID || ActiveRun?.ID != p.RunID || ActiveRun.Stage != RunStage.Planning || IsCancelling || p.Text.Length == 0 || TextElements.Count(p.Text) > 32000)
            return;
        PlanningPrompt = new(p.ConversationID, p.RunID, p.Text, "planning");
        Notify();
    }

    void Finish(Guid id)
    {
        if (submissionID != id)
            return;
        if (PlanningPrompt?.Status == "planning")
            PlanningPrompt = PlanningPrompt with
            {
                Status = "unfinished"
            };
        submissionID = null;
        IsBusy = false;
        IsCancelling = false;
        ActiveConversationID = null;
        submission?.Dispose();
        submission = null;
        Refresh();
    }

    public void Cancel()
    {
        if (!IsBusy)
            return;
        IsCancelling = true;
        submission?.Cancel();
        Notify();
    }

    public async Task<RunOutcome?> Send()
    {
        if (!CanSend || SelectedID == null || engine == null)
            return null;
        if (TextElements.Count(Draft.Trim()) > 8000)
        {
            Fail("请输入 1–8000 字的需求。");
            return null;
        }

        var request = new AgentRequest(SelectedID, Draft, Settings.Selection, ReferenceID);
        Draft = "";
        ReferenceID = null;
        Error = null;
        var id = Begin(request.ConversationID);
        try
        {
            var result = await engine.Submit(request, Settings.Memory, r => dispatch(() => Progress(r, id)), p => dispatch(() => Preview(p, id)), submission!.Token);
            Progress(result.Run, id);
            return result;
        }
        catch (Exception e)
        {
            if (submissionID != id)
                return null;
            var d = SelectedID == request.ConversationID ? new ComposerDraft(Draft, ReferenceID) : drafts.GetValueOrDefault(request.ConversationID);
            if ((d == null || d.Text.Length == 0) && d?.ReferenceID == null)
            {
                if (SelectedID == request.ConversationID)
                {
                    Draft = request.Text;
                    ReferenceID = request.ReferenceAssetID;
                }
                else
                    drafts[request.ConversationID] = new(request.Text, request.ReferenceAssetID);
            }

            Fail(e.Message);
            return null;
        }
        finally
        {
            Finish(id);
        }
    }

    public async Task<RunOutcome?> SubmitRegion(Guid session, EditorDraft draft)
    {
        var workspace = Workspace;
        if (workspace?.ID != session)
            return null;
        if (engine == null || !HasConnection || IsBusy || IsConnecting)
        {
            Fail("请先连接服务，并等待当前任务完成。");
            return null;
        }

        if (string.IsNullOrWhiteSpace(draft.Prompt) || TextElements.Count(draft.Prompt.Trim()) > 8000 || draft.Selection.IsEmpty)
        {
            Fail("请选择区域，并输入 1–8000 字的修改要求。");
            return null;
        }

        var target = workspace.Target;
        _ = EditorAsset(target.AssetID, target.ConversationID);
        var snapshot = draft with
        {
            Selection = draft.Selection.Clone()
        };
        editorDrafts[target] = snapshot;
        var request = new AgentRequest(target.ConversationID, draft.Prompt, Settings.Selection, target.AssetID, new(target.AssetID, snapshot.Selection));
        var id = Begin(target.ConversationID);
        void Accepted()
        {
            if (Workspace?.ID == session)
                CloseWorkspace(session);
            if (Workspace == null)
                Select(target.ConversationID);
            Refresh();
        }

        try
        {
            var result = await engine.Submit(request, Settings.Memory, r => dispatch(() => Progress(r, id, Accepted)), p => dispatch(() => Preview(p, id)), submission!.Token);
            Progress(result.Run, id, Accepted);
            if (result.Run.Stage == RunStage.Completed)
            {
                if (editorDrafts.GetValueOrDefault(target) == snapshot)
                    editorDrafts.Remove(target);
                failures.Remove(target);
                if (FailedEditorTarget == target)
                    FailedEditorTarget = null;
            }
            else
            {
                FailedEditorTarget = target;
                failures[target] = result.Run;
                Error = result.Run.Error;
            }

            return result;
        }
        catch (Exception e)
        {
            Error = e.Message;
            if (accepted)
            {
                FailedEditorTarget = target;
                if (ActiveRun != null)
                    failures[target] = ActiveRun with
                    {
                        Error = e.Message
                    };
            }

            Notify();
            return null;
        }
        finally
        {
            Finish(id);
        }
    }

    RunRecord? CancelledRun(MessageRecord m)
    {
        if (m.Role != MessageRole.User || Store.Conversation(m.ConversationID) == null || m.AssetIDs.Length > 1)
            return null;
        var history = Store.Messages(m.ConversationID);
        var normalized = SwiftJson.Encode(SwiftJson.Decode<MessageRecord>(SwiftJson.Encode(m)));
        if (!history.Any(x => SwiftJson.Encode(x) == normalized))
            return null;
        RunRecord? r;
        if (m.RunID != null)
        {
            r = Store.Run(m.RunID);
            if (r?.ConversationID != m.ConversationID || history.Count(x => x.Role == MessageRole.User && x.RunID == m.RunID) != 1)
                return null;
        }
        else
        {
            var matches = Store.Runs(m.ConversationID).Where(r => r.CreatedAt == m.CreatedAt && r.Request == m.Text).ToArray();
            if (matches.Length != 1 || history.Count(x => x.Role == MessageRole.User && x.CreatedAt == m.CreatedAt && x.Text == m.Text) != 1)
                return null;
            r = matches[0];
            if (m.AssetIDs.Length > 0 && r.RegionEdit == null)
                return null;
        }

        if (r?.Stage != RunStage.Cancelled)
            return null;
        foreach (var id in m.AssetIDs)
            _ = EditorAsset(id, m.ConversationID);
        if (r.RegionEdit != null && !m.AssetIDs.SequenceEqual(new[] { r.RegionEdit.AssetID }))
            return null;
        return r;
    }

    public bool CanReturnToEdit(MessageRecord m)
    {
        if (IsBusy || IsCancelling || IsConnecting || Workspace != null)
            return false;
        try
        {
            return CancelledRun(m) != null;
        }
        catch (AgentException)
        {
            return false;
        }
    }

    public bool ReturnToEdit(MessageRecord m)
    {
        if (IsBusy || IsCancelling || IsConnecting || Workspace != null)
            return Fail("请等待当前任务取消完成，并关闭图片工作区，再返回编辑。");
        try
        {
            var r = CancelledRun(m) ?? throw new AgentException("只有准确关联且已取消的任务可以返回编辑；旧的图片任务可能缺少原选区。");
            var saved = SelectedID == m.ConversationID ? new ComposerDraft(Draft, ReferenceID) : drafts.GetValueOrDefault(m.ConversationID);
            var reference = m.AssetIDs.FirstOrDefault();
            if (saved != null && (saved.Text.Length > 0 && saved.Text != m.Text || saved.ReferenceID != null && saved.ReferenceID != reference))
                throw new AgentException("来源会话已有不同的未发送草稿或参考图。请先处理该草稿。");
            foreach (var id in m.AssetIDs)
                _ = PixelImage.Decode(File.ReadAllBytes(Store.AssetPath(EditorAsset(id, m.ConversationID))));
            if (r.RegionEdit is { } region)
            {
                var a = EditorAsset(region.AssetID, m.ConversationID);
                var pixels = PixelImage.Decode(File.ReadAllBytes(Store.AssetPath(a)));
                if (region.Selection.Width != pixels.Width || region.Selection.Height != pixels.Height || region.Selection.IsEmpty)
                    throw new AgentException("原选区与图片不匹配，不能改为整张图片编辑。");
                var t = new EditorTarget(m.ConversationID, a.ID);
                if (editorDrafts.GetValueOrDefault(t) is { } d && (d.Prompt.Length > 0 || !d.Selection.IsEmpty) && (d.Prompt != m.Text || SwiftJson.Encode(d.Selection) != SwiftJson.Encode(region.Selection)))
                    throw new AgentException("这张图片已有不同的编辑草稿。");
                editorDrafts[t] = new(region.Selection.Clone(), m.Text);
                Select(m.ConversationID);
                OpenWorkspace(a);
            }
            else
            {
                Select(m.ConversationID);
                Draft = m.Text;
                ReferenceID = reference;
            }

            Error = null;
            Notify();
            return true;
        }
        catch (Exception e)
        {
            return Fail(e.Message);
        }
    }
}

public sealed class ConnectionDraft
{
    readonly WorkspaceState app;
    long revision, requestID;
    bool closed;
    CancellationTokenSource? fetch;
    public event Action? Changed;
    string address, key = "";
    public string Address
    {
        get => address;
        set
        {
            if (address == value)
                return;
            address = value;
            Key = "";
            Revealed = false;
            Invalidate();
        }
    }

    public string Key
    {
        get => key;
        set
        {
            if (key == value)
                return;
            key = value;
            revision++;
            Invalidate();
        }
    }

    public bool Revealed
    {
        get; set;
    }
    public string Value
    {
        get; set;
    }
    public string? Error
    {
        get; private set;
    }
    public bool IsLoading
    {
        get; private set;
    }
    public string[] Suggestions { get; private set; } = [];

    public ConnectionDraft(WorkspaceState app)
    {
        this.app = app;
        address = app.Settings.Endpoint;
        Value = app.Settings.PlannerModel;
    }

    public string[] Options => closed ? [] : new[]
    {
        app.Settings.PlannerModel,
        PlannerModel.Default,
        Value
    }.Concat(Suggestions).Where(v =>
    {
        try
        {
            return PlannerModel.Validate(v) == v && (Key.Length == 0 || !v.Contains(Key, StringComparison.Ordinal));
        }
        catch (AgentException)
        {
            return false;
        }
    }).Distinct().ToArray();

    void Invalidate()
    {
        requestID++;
        fetch?.Cancel();
        fetch?.Dispose();
        fetch = null;
        Suggestions = [];
        Error = null;
        IsLoading = false;
        Changed?.Invoke();
    }

    public async Task LoadKey()
    {
        var a = Address;
        var r = revision;
        try
        {
            var saved = await app.SavedKey(a);
            if (!closed && Address == a && revision == r)
            {
                Key = saved ?? "";
                Revealed = false;
                Changed?.Invoke();
            }
        }
        catch (Exception e)
        {
            if (!closed && Address == a && revision == r)
            {
                Error = e.Message;
                Changed?.Invoke();
            }
        }
    }

    public async Task Refresh()
    {
        if (closed)
            return;
        Invalidate();
        var id = requestID;
        var a = Address;
        var k = Key;
        fetch = new();
        IsLoading = true;
        Changed?.Invoke();
        try
        {
            var ids = await app.PlannerModels(a, k, fetch.Token);
            if (!closed && id == requestID && a == Address && k == Key)
                Suggestions = ids;
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception e)
        {
            if (!closed && id == requestID)
                Error = e.Message;
        }
        finally
        {
            if (id == requestID)
            {
                IsLoading = false;
                Changed?.Invoke();
            }
        }
    }

    public async Task Reset()
    {
        Invalidate();
        Address = app.Settings.Endpoint;
        Key = "";
        Revealed = false;
        Value = app.Settings.PlannerModel;
        await LoadKey();
    }

    public void Close()
    {
        closed = true;
        Invalidate();
        key = "";
        address = "";
        Revealed = false;
    }
}
