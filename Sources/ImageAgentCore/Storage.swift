import Foundation
import CSQLite
import ImageIO
import UniformTypeIdentifiers

public enum ImageAgentError: LocalizedError, Sendable {
    case invalidInput(String), storage(String), invalidImage(String), credential(String), busy
    public var errorDescription: String? {
        switch self {
        case .invalidInput(let s), .storage(let s), .invalidImage(let s), .credential(let s): return s
        case .busy: return "此会话已有任务正在运行。"
        }
    }
}

public struct AppPaths: Sendable {
    public let root: URL
    public var database: URL { root.appendingPathComponent("app.sqlite") }
    public var assets: URL { root.appendingPathComponent("assets", isDirectory: true) }
    public var exports: URL { root.appendingPathComponent("exports", isDirectory: true) }
    public init(root: URL? = nil) throws {
        self.root = (root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ImageAgent", isDirectory: true)).standardizedFileURL
        for directory in [self.root, assets, exports] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }
}

public struct DecodedImage: Sendable {
    public let data: Data
    public let width: Int
    public let height: Int
    public let mediaType: String
    public let fileExtension: String
    public init(data: Data) throws {
        guard !data.isEmpty, data.count <= 100 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= 150_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              let typeName = CGImageSourceGetType(source) as String?, let type = UTType(typeName), type.conforms(to: .image) else {
            throw ImageAgentError.invalidImage("返回内容无法解码为有效图片。未保存无效文件，也不会自动重新生成。")
        }
        self.data = data; self.width = image.width; self.height = image.height
        self.mediaType = type.preferredMIMEType ?? "application/octet-stream"
        self.fileExtension = type.preferredFilenameExtension ?? "img"
    }
}

/// All SQL access is serialized; records use typed JSON payloads and relational ownership keys.
public final class SQLiteStore: @unchecked Sendable {
    public let paths: AppPaths
    private var database: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(paths: AppPaths) throws {
        self.paths = paths
        guard sqlite3_open_v2(paths.database.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw ImageAgentError.storage("无法打开本地数据库。")
        }
        do {
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA busy_timeout = 5000")
            try execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, payload TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS conversations (id TEXT PRIMARY KEY, created_at REAL NOT NULL, updated_at REAL NOT NULL, payload TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS messages (id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE, created_at REAL NOT NULL, payload TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS runs (id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE, created_at REAL NOT NULL, payload TEXT NOT NULL, UNIQUE(id, conversation_id))")
            try execute("CREATE TABLE IF NOT EXISTS assets (id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE, parent_asset_id TEXT, run_id TEXT, created_at REAL NOT NULL, payload TEXT NOT NULL, UNIQUE(id, conversation_id), FOREIGN KEY(parent_asset_id, conversation_id) REFERENCES assets(id, conversation_id), FOREIGN KEY(run_id, conversation_id) REFERENCES runs(id, conversation_id))")
            try execute("CREATE INDEX IF NOT EXISTS messages_conversation_time ON messages(conversation_id, created_at)")
            try execute("CREATE INDEX IF NOT EXISTS assets_conversation_time ON assets(conversation_id, created_at)")
            try secureDatabaseFiles()
        } catch { sqlite3_close(database); database = nil; throw error }
    }
    deinit { sqlite3_close(database) }

    private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    private func prepare(_ sql: String, _ bindings: [String?]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        for (index, value) in bindings.enumerated() {
            let status: Int32
            if let value { status = sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) }
            else { status = sqlite3_bind_null(statement, Int32(index + 1)) }
            if status != SQLITE_OK { sqlite3_finalize(statement); throw databaseError() }
        }
        return statement
    }
    private func databaseError() -> ImageAgentError { .storage("本地数据库操作失败：\(String(cString: sqlite3_errmsg(database)))") }
    private func execute(_ sql: String, _ bindings: [String?] = []) throws {
        try locked {
            let statement = try prepare(sql, bindings); defer { sqlite3_finalize(statement) }
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE || result == SQLITE_ROW else { throw databaseError() }
        }
    }
    private func rows<T: Decodable>(_ sql: String, _ bindings: [String?] = [], as type: T.Type = T.self) throws -> [T] {
        try locked {
            let statement = try prepare(sql, bindings); defer { sqlite3_finalize(statement) }
            var values: [T] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return values }
                guard result == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw databaseError() }
                values.append(try decoder.decode(T.self, from: Data(String(cString: text).utf8)))
            }
        }
    }
    private func json<T: Encodable>(_ value: T) throws -> String { try locked { String(decoding: try encoder.encode(value), as: UTF8.self) } }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try locked {
            try execute("BEGIN IMMEDIATE")
            do { let result = try body(); try execute("COMMIT"); return result }
            catch { try? execute("ROLLBACK"); throw error }
        }
    }
    private func secureDatabaseFiles() throws {
        for path in [paths.database.path, paths.database.path + "-wal", paths.database.path + "-shm"] where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }
    public func settings() throws -> AppSettings { try rows("SELECT payload FROM settings WHERE key = 'app'", as: AppSettings.self).first ?? AppSettings() }
    public func saveSettings(_ settings: AppSettings) throws {
        try transaction {
            try secureDatabaseFiles()
            try execute("INSERT INTO settings(key,payload) VALUES('app',?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload", [json(settings)])
        }
    }
    @discardableResult public func createConversation(title: String = "新会话", now: Date = Date()) throws -> Conversation {
        let conversation = Conversation(title: title, createdAt: now)
        try saveConversation(conversation); return conversation
    }
    public func saveConversation(_ conversation: Conversation) throws {
        try execute("INSERT INTO conversations(id,created_at,updated_at,payload) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET updated_at=excluded.updated_at,payload=excluded.payload", [conversation.id, String(conversation.createdAt.timeIntervalSince1970), String(conversation.updatedAt.timeIntervalSince1970), json(conversation)])
    }
    public func conversations() throws -> [Conversation] { try rows("SELECT payload FROM conversations ORDER BY updated_at DESC, id") }
    public func conversation(_ id: String) throws -> Conversation? { try rows("SELECT payload FROM conversations WHERE id=?", [id], as: Conversation.self).first }
    public func deleteConversation(_ id: String) throws {
        try locked {
            guard try conversation(id) != nil else { return }
            let ownedRuns = try runs(in: id)
            let allowedRunID = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
            let recoveryDirectories = try ownedRuns.map { run -> URL in
                guard !run.id.isEmpty, run.id.unicodeScalars.allSatisfy(allowedRunID.contains) else { throw ImageAgentError.storage("恢复目录标识无效。") }
                return paths.root.appendingPathComponent("recovery", isDirectory: true).appendingPathComponent(run.id, isDirectory: true)
            }
            try execute("DELETE FROM conversations WHERE id=?", [id])
            let directory = paths.assets.appendingPathComponent(id, isDirectory: true)
            for url in [directory] + recoveryDirectories where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
    public func resetMemory(_ id: String, at date: Date = Date()) throws {
        guard var conversation = try conversation(id) else { throw ImageAgentError.invalidInput("会话不存在。") }
        conversation.memoryResetAt = date; try saveConversation(conversation)
    }
    public func addMessage(_ message: MessageRecord) throws {
        try transaction {
            for id in message.assetIDs {
                guard let asset = try asset(id), asset.conversationID == message.conversationID else { throw ImageAgentError.invalidInput("图片不属于当前会话。") }
            }
            try execute("INSERT INTO messages(id,conversation_id,created_at,payload) VALUES(?,?,?,?)", [message.id, message.conversationID, String(message.createdAt.timeIntervalSince1970), json(message)])
            if var conversation = try conversation(message.conversationID) {
                conversation.updatedAt = message.createdAt
                if conversation.title == "新会话", message.role == .user { conversation.title = String(message.text.prefix(30)) }
                try saveConversation(conversation)
            }
        }
    }
    public func messages(in id: String) throws -> [MessageRecord] { try rows("SELECT payload FROM messages WHERE conversation_id=? ORDER BY created_at, rowid", [id]) }
    public func saveRun(_ run: RunRecord) throws {
        try execute("INSERT INTO runs(id,conversation_id,created_at,payload) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", [run.id, run.conversationID, String(run.createdAt.timeIntervalSince1970), json(run)])
    }
    public func runs(in id: String) throws -> [RunRecord] { try rows("SELECT payload FROM runs WHERE conversation_id=? ORDER BY created_at, rowid", [id]) }
    public func run(_ id: String) throws -> RunRecord? { try rows("SELECT payload FROM runs WHERE id=?", [id], as: RunRecord.self).first }
    public func assets(in id: String) throws -> [AssetRecord] { try rows("SELECT payload FROM assets WHERE conversation_id=? ORDER BY created_at, rowid", [id]) }
    public func asset(_ id: String) throws -> AssetRecord? { try rows("SELECT payload FROM assets WHERE id=?", [id], as: AssetRecord.self).first }
    public func assetURL(_ asset: AssetRecord) throws -> URL { try assetURL(relativePath: asset.relativePath) }
    public func assetURL(relativePath: String) throws -> URL {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard parts.count == 3, parts[0] == "assets", parts[1] != ".", parts[1] != "..", parts[2] != ".", parts[2] != "..",
              parts.dropFirst().allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { throw ImageAgentError.invalidInput("无效的本地图片路径。") }
        let url = paths.root.appendingPathComponent(relativePath).standardizedFileURL
        guard url.resolvingSymlinksInPath().path.hasPrefix(paths.assets.resolvingSymlinksInPath().path + "/") else { throw ImageAgentError.invalidInput("图片路径超出了数据目录。") }
        return url
    }
    @discardableResult public func saveImage(_ data: Data, conversationID: String, parentAssetID: String? = nil, source: AssetSource, prompt: String = "", selection: ImageSelection? = nil, modelVerified: Bool? = nil, run: RunRecord? = nil, now: Date = Date()) throws -> AssetRecord {
        try locked {
            guard try conversation(conversationID) != nil else { throw ImageAgentError.invalidInput("会话不存在。") }
            if let parentAssetID {
                guard let parent = try asset(parentAssetID), parent.conversationID == conversationID else { throw ImageAgentError.invalidInput("参考图片不属于当前会话。") }
            }
            let image = try DecodedImage(data: data)
            let id = UUID().uuidString.lowercased()
            let relativePath = "assets/\(conversationID)/\(id).\(image.fileExtension)"
            let destination = try assetURL(relativePath: relativePath)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            let asset = AssetRecord(id: id, conversationID: conversationID, relativePath: relativePath, mediaType: image.mediaType, width: image.width, height: image.height, parentAssetID: parentAssetID, runID: run?.id, source: source, prompt: prompt, model: selection?.model.rawValue, modelVerified: modelVerified ?? (selection == nil ? nil : true), requestedSize: selection?.size.rawValue, createdAt: now)
            do {
                try transaction {
                    try execute("INSERT INTO assets(id,conversation_id,parent_asset_id,run_id,created_at,payload) VALUES(?,?,?,?,?,?)", [asset.id, conversationID, parentAssetID, run?.id, String(now.timeIntervalSince1970), json(asset)])
                    if var run {
                        guard run.conversationID == conversationID else { throw ImageAgentError.invalidInput("任务会话不匹配。") }
                        run.resultAssetIDs.append(asset.id); run.stage = .finalizing; run.updatedAt = now
                        try saveRun(run)
                    }
                }
            } catch { try? FileManager.default.removeItem(at: destination); throw error }
            return asset
        }
    }
    /// Commit known response bytes before any composition or database finalization. This path is never used as an asset.
    public func saveRegionPatch(_ data: Data, run: RunRecord, sourceAssetID: String, snapshot: RegionEditSnapshot, name: String = "patch", modelVerified: Bool = true) throws -> String {
        let decoded = try DecodedImage(data: data)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !run.id.isEmpty, run.id.unicodeScalars.allSatisfy(allowed.contains), !name.isEmpty, name.unicodeScalars.allSatisfy(allowed.contains) else { throw ImageAgentError.storage("恢复目录标识无效。") }
        let root = paths.root.appendingPathComponent("recovery", isDirectory: true)
        let directory = root.appendingPathComponent(run.id, isDirectory: true)
        guard directory.resolvingSymlinksInPath().path.hasPrefix(paths.root.resolvingSymlinksInPath().path + "/") else { throw ImageAgentError.storage("恢复目录超出数据目录。") }
        for url in [root, directory] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        let patchName = "\(name).\(decoded.fileExtension)"
        func write(_ bytes: Data, _ name: String) throws {
            let url = directory.appendingPathComponent(name)
            try bytes.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        // First durable write is the expensive response. Additional recovery metadata must not precede it.
        try write(data, patchName)
        struct Recovery: Encodable {
            let runID: String; let conversationID: String; let sourceAssetID: String
            let width: Int; let height: Int; let roi: PixelRect; let modelVerified: Bool
        }
        try write(snapshot.maskPNG, "mask.png")
        try write(JSONEncoder().encode(Recovery(runID: run.id, conversationID: run.conversationID, sourceAssetID: sourceAssetID,
                                               width: snapshot.base.width, height: snapshot.base.height, roi: snapshot.roi, modelVerified: modelVerified)), "region.json")
        return "recovery/\(run.id)/\(patchName)"
    }

    private func discoverRegionRecovery(_ run: RunRecord) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !run.id.isEmpty, run.id.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        let directory = paths.root.appendingPathComponent("recovery/\(run.id)", isDirectory: true)
        guard directory.resolvingSymlinksInPath().path.hasPrefix(paths.root.resolvingSymlinksInPath().path + "/recovery/"),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return nil }
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = file.lastPathComponent
            guard name.hasPrefix("patch.") || name.hasPrefix("native-"),
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 100 * 1024 * 1024,
                  let bytes = try? Data(contentsOf: file), (try? DecodedImage(data: bytes)) != nil else { continue }
            return "recovery/\(run.id)/\(name)"
        }
        return nil
    }

    public func recoveryURL(_ run: RunRecord) throws -> URL? {
        guard let relative = run.recoveryRelativePath else { return nil }
        let url = paths.root.appendingPathComponent(relative).standardizedFileURL
        let recovery = paths.root.resolvingSymlinksInPath().appendingPathComponent("recovery").path + "/"
        guard url.resolvingSymlinksInPath().path.hasPrefix(recovery), FileManager.default.fileExists(atPath: url.path) else { throw ImageAgentError.storage("已保留的局部结果文件不可用。") }
        return url
    }

    public func recoverInterruptedRuns(now: Date = Date()) throws {
        let records: [RunRecord] = try rows("SELECT payload FROM runs")
        for var run in records where !run.stage.isTerminal {
            if run.recoveryRelativePath == nil { run.recoveryRelativePath = discoverRegionRecovery(run) }
            run.stage = .interrupted; run.updatedAt = now
            run.error = "应用退出时任务尚未完成。远端请求状态未知；不会自动重试。"
            let recoveryNotice = run.recoveryRelativePath == nil ? "" : " 已返回的局部结果保存在数据目录 recovery/\(run.id)，可手动恢复。"
            run.error! += recoveryNotice
            let history = try messages(in: run.conversationID)
            if run.resultAssetIDs.isEmpty {
                let noticeID = "interrupted-\(run.id)"
                if !history.contains(where: { $0.id == noticeID }) {
                    try addMessage(.init(id: noticeID, conversationID: run.conversationID, role: .assistant, text: "上次任务已中断。远端请求状态未知；不会自动重试。" + recoveryNotice, detailedPrompt: run.detailedPrompt, createdAt: now))
                }
            } else if !history.contains(where: { !$0.assetIDs.isEmpty && $0.assetIDs == run.resultAssetIDs && $0.role == .assistant }) {
                try addMessage(.init(conversationID: run.conversationID, role: .assistant, text: "上次任务已中断。以下图片已经保存在本地。", assetIDs: run.resultAssetIDs, detailedPrompt: run.detailedPrompt, createdAt: now))
            }
            // Save the notice first so a crash cannot leave a terminal run with no visible status.
            try saveRun(run)
        }
    }
}
