using Microsoft.Data.Sqlite;
using System.Text;
using System.Text.RegularExpressions;

namespace ImageAgent.Core;
public sealed class AppPaths
{
    public string Root { get; }
    public string Database => Path.Combine(Root, "app.sqlite");
    public string Assets => Path.Combine(Root, "assets");
    public string Exports => Path.Combine(Root, "exports");

    public AppPaths(string root)
    {
        if (!Path.IsPathFullyQualified(root))
            throw new AgentException("必须提供独立的绝对数据目录。");
        Root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
        if (Root == Path.GetPathRoot(Root))
            throw new AgentException("数据目录必须是专用子目录。");
        if ((Directory.Exists(Root) || File.Exists(Root)) && (File.GetAttributes(Root) & FileAttributes.ReparsePoint) != 0)
            throw new AgentException("数据目录不能是符号链接或重解析点。");
        SecureDirectory(Root);
        SecureDirectory(Assets);
        SecureDirectory(Exports);
    }

    public static void SecureDirectory(string path)
    {
        Directory.CreateDirectory(path);
        if (!OperatingSystem.IsWindows())
            File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
    }

    public static void WriteAtomic(string path, byte[] bytes)
    {
        var tmp = path + ".tmp-" + Guid.NewGuid();
        try
        {
            using (var f = new FileStream(tmp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            {
                f.Write(bytes);
                f.Flush(true);
            }

            if (!OperatingSystem.IsWindows())
                File.SetUnixFileMode(tmp, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            File.Move(tmp, path, true);
        }
        finally
        {
            if (File.Exists(tmp))
                File.Delete(tmp);
        }
    }

    public static bool SafeID(string s) => s.Length > 0 && s.All(c => char.IsLetterOrDigit(c) || c is '-' or '_');
    public string SafeFile(string relative, string category)
    {
        var p = relative.Split('/');
        if (p.Length != 3 || p[0] != category || p.Skip(1).Any(s => s.Length == 0 || s is "." or ".." || !s.All(c => char.IsLetterOrDigit(c) || c is '-' or '_' or '.')))
            throw new AgentException("无效的本地文件路径。");
        var path = Root;
        foreach (var item in p)
        {
            path = Path.Combine(path, item);
            if ((File.Exists(path) || Directory.Exists(path)) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                throw new AgentException("文件路径超出了数据目录。");
        }

        if (!Path.GetFullPath(path).StartsWith(Root + Path.DirectorySeparatorChar, StringComparison.Ordinal))
            throw new AgentException("文件路径超出了数据目录。");
        return path;
    }

    public string SafeDirectory(string category, string id)
    {
        if (!SafeID(id))
            throw new AgentException("目录标识无效。");
        return Path.GetDirectoryName(SafeFile($"{category}/{id}/marker", category))!;
    }
}

public sealed class SQLiteStore : IDisposable
{
    readonly SqliteConnection db;
    readonly object gate = new();
    public AppPaths Paths { get; }
    public Action<string>? BeforeWrite { get; set; }

    public SQLiteStore(AppPaths paths)
    {
        Paths = paths;
        db = new(new SqliteConnectionStringBuilder { DataSource = paths.Database, Mode = SqliteOpenMode.ReadWriteCreate, Pooling = false }.ToString());
        db.Open();
        Execute("PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;");
        Execute("CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,payload TEXT NOT NULL); CREATE TABLE IF NOT EXISTS conversations(id TEXT PRIMARY KEY,created_at REAL NOT NULL,updated_at REAL NOT NULL,payload TEXT NOT NULL); CREATE TABLE IF NOT EXISTS messages(id TEXT PRIMARY KEY,conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,created_at REAL NOT NULL,payload TEXT NOT NULL); CREATE TABLE IF NOT EXISTS runs(id TEXT PRIMARY KEY,conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,created_at REAL NOT NULL,payload TEXT NOT NULL,UNIQUE(id,conversation_id)); CREATE TABLE IF NOT EXISTS assets(id TEXT PRIMARY KEY,conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,parent_asset_id TEXT,run_id TEXT,created_at REAL NOT NULL,payload TEXT NOT NULL,UNIQUE(id,conversation_id),FOREIGN KEY(parent_asset_id,conversation_id) REFERENCES assets(id,conversation_id),FOREIGN KEY(run_id,conversation_id) REFERENCES runs(id,conversation_id)); CREATE INDEX IF NOT EXISTS messages_conversation_time ON messages(conversation_id,created_at); CREATE INDEX IF NOT EXISTS assets_conversation_time ON assets(conversation_id,created_at);");
        if (!OperatingSystem.IsWindows())
            foreach (var f in new[]
            {
                paths.Database,
                paths.Database + "-wal",
                paths.Database + "-shm"
            }

            )
                if (File.Exists(f))
                    File.SetUnixFileMode(f, UnixFileMode.UserRead | UnixFileMode.UserWrite);
    }

    void Execute(string sql, params object? [] v)
    {
        lock (gate)
        {
            using var c = db.CreateCommand();
            c.CommandText = sql;
            for (int i = 0; i < v.Length; i++)
                c.Parameters.AddWithValue("$" + i, v[i] ?? DBNull.Value);
            c.ExecuteNonQuery();
        }
    }

    List<T> Rows<T>(string sql, params object? [] v)
    {
        lock (gate)
        {
            using var c = db.CreateCommand();
            c.CommandText = sql;
            for (int i = 0; i < v.Length; i++)
                c.Parameters.AddWithValue("$" + i, v[i] ?? DBNull.Value);
            using var r = c.ExecuteReader();
            var a = new List<T>();
            while (r.Read())
                a.Add(SwiftJson.Decode<T>(r.GetString(0)));
            return a;
        }
    }

    void Transaction(Action a)
    {
        lock (gate)
        {
            Execute("BEGIN IMMEDIATE");
            try
            {
                a();
                Execute("COMMIT");
            }
            catch
            {
                Execute("ROLLBACK");
                throw;
            }
        }
    }

    static double Unix(DateTimeOffset d) => (d - DateTimeOffset.UnixEpoch).TotalSeconds;
    public AppSettings Settings() => Rows<AppSettings>("SELECT payload FROM settings WHERE key='app'").FirstOrDefault() ?? new();
    public void SaveSettings(AppSettings s)
    {
        BeforeWrite?.Invoke("settings");
        Transaction(() => Execute("INSERT INTO settings(key,payload) VALUES('app',$0) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload", SwiftJson.Encode(s)));
    }

    public Conversation CreateConversation(string title = "新会话", DateTimeOffset? now = null)
    {
        var t = now ?? DateTimeOffset.UtcNow;
        var c = new Conversation
        {
            Title = title,
            CreatedAt = t,
            UpdatedAt = t
        };
        SaveConversation(c);
        return c;
    }

    public void SaveConversation(Conversation c)
    {
        if (!AppPaths.SafeID(c.ID))
            throw new AgentException("会话标识无效。");
        Execute("INSERT INTO conversations(id,created_at,updated_at,payload) VALUES($0,$1,$2,$3) ON CONFLICT(id) DO UPDATE SET updated_at=excluded.updated_at,payload=excluded.payload", c.ID, Unix(c.CreatedAt), Unix(c.UpdatedAt), SwiftJson.Encode(c));
    }

    public List<Conversation> Conversations() => Rows<Conversation>("SELECT payload FROM conversations ORDER BY updated_at DESC,id");
    public Conversation? Conversation(string id) => Rows<Conversation>("SELECT payload FROM conversations WHERE id=$0", id).FirstOrDefault();
    public void DeleteConversation(string id)
    {
        lock (gate)
        {
            if (Conversation(id) == null)
                return;
            var dirs = Runs(id).Select(r => Paths.SafeDirectory("recovery", r.ID)).Prepend(Paths.SafeDirectory("assets", id)).ToArray();
            Execute("DELETE FROM conversations WHERE id=$0", id);
            foreach (var d in dirs)
                if (Directory.Exists(d))
                    Directory.Delete(d, true);
        }
    }

    public void ResetMemory(string id, DateTimeOffset? now = null)
    {
        var c = Conversation(id) ?? throw new AgentException("会话不存在。");
        c.MemoryResetAt = now ?? DateTimeOffset.UtcNow;
        SaveConversation(c);
    }

    public void AddMessage(MessageRecord m)
    {
        BeforeWrite?.Invoke("message");
        Transaction(() =>
        {
            foreach (var id in m.AssetIDs)
                if (Asset(id)?.ConversationID != m.ConversationID)
                    throw new AgentException("图片不属于当前会话。");
            Execute("INSERT INTO messages(id,conversation_id,created_at,payload) VALUES($0,$1,$2,$3)", m.ID, m.ConversationID, Unix(m.CreatedAt), SwiftJson.Encode(m));
            var c = Conversation(m.ConversationID) ?? throw new AgentException("会话不存在。");
            c.UpdatedAt = m.CreatedAt;
            if (c.Title == "新会话" && m.Role == MessageRole.User)
                c.Title = TextElements.Prefix(m.Text, 30);
            SaveConversation(c);
        });
    }

    public List<MessageRecord> Messages(string id) => Rows<MessageRecord>("SELECT payload FROM messages WHERE conversation_id=$0 ORDER BY created_at,rowid", id);
    public void SaveRun(RunRecord r)
    {
        BeforeWrite?.Invoke("run");
        Execute("INSERT INTO runs(id,conversation_id,created_at,payload) VALUES($0,$1,$2,$3) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", r.ID, r.ConversationID, Unix(r.CreatedAt), SwiftJson.Encode(r));
    }

    public List<RunRecord> Runs(string id) => Rows<RunRecord>("SELECT payload FROM runs WHERE conversation_id=$0 ORDER BY created_at,rowid", id);
    public RunRecord? Run(string id) => Rows<RunRecord>("SELECT payload FROM runs WHERE id=$0", id).FirstOrDefault();
    public List<AssetRecord> Assets(string id) => Rows<AssetRecord>("SELECT payload FROM assets WHERE conversation_id=$0 ORDER BY created_at,rowid", id);
    public AssetRecord? Asset(string id) => Rows<AssetRecord>("SELECT payload FROM assets WHERE id=$0", id).FirstOrDefault();
    public string AssetPath(AssetRecord a) => Paths.SafeFile(a.RelativePath, "assets");
    public AssetRecord SaveImage(byte[] bytes, string conversationID, AssetSource source, string? parentAssetID = null, string prompt = "", ImageSelection? selection = null, bool? modelVerified = null, RunRecord? run = null, DateTimeOffset? now = null)
    {
        lock (gate)
        {
            if (Conversation(conversationID) == null)
                throw new AgentException("会话不存在。");
            if (parentAssetID != null && Asset(parentAssetID)?.ConversationID != conversationID)
                throw new AgentException("参考图不属于当前会话。");
            var image = new DecodedImage(bytes);
            var id = Guid.NewGuid().ToString();
            var relative = $"assets/{conversationID}/{id}.{image.Extension}";
            var path = Paths.SafeFile(relative, "assets");
            AppPaths.SecureDirectory(Path.GetDirectoryName(path)!);
            BeforeWrite?.Invoke("imageBytes");
            AppPaths.WriteAtomic(path, bytes);
            var a = new AssetRecord
            {
                ID = id,
                ConversationID = conversationID,
                RelativePath = relative,
                MediaType = image.MediaType,
                Width = image.Width,
                Height = image.Height,
                Source = source,
                ParentAssetID = parentAssetID,
                RunID = run?.ID,
                Prompt = prompt,
                Model = selection?.Model,
                ModelVerified = modelVerified ?? (selection == null ? null : true),
                RequestedSize = selection?.Size,
                CreatedAt = now ?? DateTimeOffset.UtcNow
            };
            try
            {
                Transaction(() =>
                {
                    BeforeWrite?.Invoke("asset");
                    Execute("INSERT INTO assets(id,conversation_id,parent_asset_id,run_id,created_at,payload) VALUES($0,$1,$2,$3,$4,$5)", a.ID, conversationID, parentAssetID, run?.ID, Unix(a.CreatedAt), SwiftJson.Encode(a));
                    if (run != null)
                    {
                        if (run.ConversationID != conversationID)
                            throw new AgentException("任务会话不匹配。");
                        var update = run with
                        {
                            ResultAssetIDs = [..run.ResultAssetIDs, a.ID],
                            Stage = RunStage.Finalizing,
                            UpdatedAt = a.CreatedAt
                        };
                        SaveRun(update);
                    }
                });
            }
            catch
            {
                // The durable raw response is separate; only this unregistered asset is compensated.
                try
                {
                    File.Delete(path);
                }
                catch (IOException)
                {
                }
                catch (UnauthorizedAccessException)
                {
                }

                throw;
            }

            return a;
        }
    }

    public string SaveRawImage(byte[] data, RunRecord run, string name = "patch")
    {
        var decoded = new DecodedImage(data);
        if (!AppPaths.SafeID(name))
            throw new AgentException("恢复文件名无效。");
        var relative = $"recovery/{run.ID}/{name}.{decoded.Extension}";
        var file = Paths.SafeFile(relative, "recovery");
        AppPaths.SecureDirectory(Path.GetDirectoryName(file)!);
        BeforeWrite?.Invoke("rawBytes");
        AppPaths.WriteAtomic(file, data);
        return relative;
    }

    public void SaveRecoveryMetadata(RunRecord run, RegionEditSnapshot? snapshot = null, string? sourceAssetID = null, bool modelVerified = true)
    {
        BeforeWrite?.Invoke("recoveryMetadata");
        if (snapshot != null)
        {
            AppPaths.WriteAtomic(Paths.SafeFile($"recovery/{run.ID}/mask.png", "recovery"), snapshot.MaskPNG);
            AppPaths.WriteAtomic(Paths.SafeFile($"recovery/{run.ID}/original.png", "recovery"), snapshot.Base.PngData());
        }

        var meta = new
        {
            runID = run.ID,
            conversationID = run.ConversationID,
            sourceAssetID,
            width = snapshot?.Base.Width,
            height = snapshot?.Base.Height,
            roi = snapshot?.ROI,
            modelVerified
        };
        AppPaths.WriteAtomic(Paths.SafeFile($"recovery/{run.ID}/region.json", "recovery"), Encoding.UTF8.GetBytes(SwiftJson.Encode(meta)));
    }

    public string SaveReceivedImage(byte[] data, RunRecord run, string name = "patch", RegionEditSnapshot? snapshot = null, string? sourceAssetID = null, bool modelVerified = true)
    {
        var relative = SaveRawImage(data, run, name);
        SaveRecoveryMetadata(run, snapshot, sourceAssetID, modelVerified);
        return relative;
    }

    public string? RecoveryPath(RunRecord r)
    {
        if (r.RecoveryRelativePath == null)
            return null;
        var path = Paths.SafeFile(r.RecoveryRelativePath, "recovery");
        if (!File.Exists(path))
            throw new AgentException("已保留的结果文件不可用。");
        return path;
    }

    string? DiscoverRecovery(RunRecord r)
    {
        var dir = Paths.SafeDirectory("recovery", r.ID);
        if (!Directory.Exists(dir))
            return null;
        foreach (var file in Directory.EnumerateFiles(dir).Order(StringComparer.Ordinal))
        {
            var name = Path.GetFileName(file);
            if (!(name.StartsWith("patch.") || name.StartsWith("native-")) || new FileInfo(file).Length > DecodedImage.MaximumBytes)
                continue;
            try
            {
                var relative = $"recovery/{r.ID}/{name}";
                _ = new DecodedImage(File.ReadAllBytes(Paths.SafeFile(relative, "recovery")));
                return relative;
            }
            catch (AgentException)
            {
            }
        }

        return null;
    }

    public void RecoverInterruptedRuns(DateTimeOffset? now = null)
    {
        lock (gate)
        {
            foreach (var r in Rows<RunRecord>("SELECT payload FROM runs").Where(r => !r.Stage.IsTerminal()))
            {
                r.RecoveryRelativePath ??= DiscoverRecovery(r);
                r.Stage = RunStage.Interrupted;
                r.UpdatedAt = now ?? DateTimeOffset.UtcNow;
                r.Error = "应用退出时任务尚未完成。远端请求状态未知；不会自动重试。";
                var notice = r.RecoveryRelativePath == null ? "" : $" 已返回的结果保存在数据目录 recovery/{r.ID}，可手动恢复。";
                r.Error += notice;
                var history = Messages(r.ConversationID);
                var assets = Assets(r.ConversationID).Where(a => a.RunID == r.ID).Select(a => a.ID).ToArray();
                if (r.ResultAssetIDs.Length == 0)
                    r.ResultAssetIDs = assets;
                if (!history.Any(m => m.ID == "interrupted-" + r.ID || m.Role == MessageRole.Assistant && m.RunID == r.ID))
                    AddMessage(new() { ID = "interrupted-" + r.ID, ConversationID = r.ConversationID, Role = MessageRole.Assistant, Text = "上次任务已中断。远端请求状态未知；不会自动重试。" + notice, AssetIDs = r.ResultAssetIDs, DetailedPrompt = r.DetailedPrompt, RunID = r.ID, CreatedAt = r.UpdatedAt });
                SaveRun(r);
            }
        }
    }

    public void Dispose()
    {
        lock (gate)
            db.Dispose();
    }
}

public record MemoryEntry(MessageRole Role, string Text);
public record MemoryContext(IReadOnlyList<MemoryEntry> Entries, IReadOnlyList<AssetRecord> Assets);
public sealed class MemoryBuilder(SQLiteStore store, Func<DateTimeOffset>? clock = null)
{
    public MemoryContext Build(string conversationID, MemoryPolicy policy, string? explicitReferenceID = null)
    {
        var c = store.Conversation(conversationID) ?? throw new AgentException("会话不存在。");
        var now = (clock ?? (() => DateTimeOffset.UtcNow))();
        var cutoff = now.AddHours(-policy.Hours);
        bool Eligible(DateTimeOffset t) => t >= cutoff && t <= now && (c.MemoryResetAt == null || t > c.MemoryResetAt);
        var turns = new List<List<MessageRecord>>();
        foreach (var m in store.Messages(conversationID).Where(m => Eligible(m.CreatedAt)))
        {
            if (m.Role == MessageRole.User)
                turns.Add([m]);
            else if (turns.Count > 0)
                turns[^1].Add(m);
        }

        var entries = new List<MemoryEntry>();
        var ids = new HashSet<string>();
        var remaining = policy.MaxCharacters;
        foreach (var m in turns.TakeLast(policy.Turns).SelectMany(x => x).Reverse())
        {
            if (remaining <= 0)
                break;
            var text = m.Text;
            if (!string.IsNullOrEmpty(m.DetailedPrompt))
                text += "\n[上次详细提示词] " + m.DetailedPrompt;
            if (m.AssetIDs.Length > 0)
                text += "\n[图片 ID] " + string.Join(", ", m.AssetIDs);
            text = TextElements.Suffix(text, remaining);
            remaining -= TextElements.Count(text);
            entries.Insert(0, new(m.Role, text));
            ids.UnionWith(m.AssetIDs);
        }

        var assets = store.Assets(conversationID).Where(a => ids.Contains(a.ID) && Eligible(a.CreatedAt)).ToList();
        if (explicitReferenceID != null)
        {
            var a = store.Asset(explicitReferenceID);
            if (a == null || a.ConversationID != conversationID || !File.Exists(store.AssetPath(a)))
                throw new AgentException("参考图片不存在或不属于当前会话。");
            if (!assets.Any(x => x.ID == a.ID))
                assets.Add(a);
        }

        return new(entries, assets);
    }
}
