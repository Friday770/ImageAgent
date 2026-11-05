import Foundation

public struct MemoryEntry: Equatable, Sendable {
    public let role: MessageRole
    public let text: String
}
public struct MemoryContext: Sendable {
    public let entries: [MemoryEntry]
    public let assets: [AssetRecord]
}

public struct MemoryBuilder: Sendable {
    private let store: SQLiteStore
    private let clock: @Sendable () -> Date
    public init(store: SQLiteStore, clock: @escaping @Sendable () -> Date = { Date() }) { self.store = store; self.clock = clock }
    public func build(conversationID: String, policy: MemoryPolicy = .init(), explicitReferenceID: String? = nil) throws -> MemoryContext {
        guard let conversation = try store.conversation(conversationID) else { throw ImageAgentError.invalidInput("会话不存在。") }
        let now = clock()
        let cutoff = now.addingTimeInterval(-Double(policy.hours) * 3600)
        let eligible = try store.messages(in: conversationID).filter {
            $0.createdAt >= cutoff && $0.createdAt <= now && (conversation.memoryResetAt == nil || $0.createdAt > conversation.memoryResetAt!)
        }
        var turns: [[MessageRecord]] = []
        for message in eligible {
            if message.role == .user { turns.append([message]) }
            else if !turns.isEmpty { turns[turns.count - 1].append(message) }
        }
        let selected = turns.suffix(policy.turns).flatMap { $0 }
        var remaining = policy.maxCharacters
        var entries: [MemoryEntry] = []
        var retained: [MessageRecord] = []
        for message in selected.reversed() where remaining > 0 {
            var text = message.text
            if let prompt = message.detailedPrompt, !prompt.isEmpty { text += "\n[上次详细提示词] \(prompt)" }
            if !message.assetIDs.isEmpty { text += "\n[图片 ID] \(message.assetIDs.joined(separator: ", "))" }
            text = String(text.suffix(remaining))
            remaining -= text.count
            entries.insert(.init(role: message.role, text: text), at: 0)
            retained.append(message)
        }
        let referencedIDs = Set(retained.flatMap(\.assetIDs))
        var assets = try store.assets(in: conversationID).filter {
            referencedIDs.contains($0.id) && $0.createdAt >= cutoff && $0.createdAt <= now && (conversation.memoryResetAt == nil || $0.createdAt > conversation.memoryResetAt!)
        }
        if let explicitReferenceID {
            guard let asset = try store.asset(explicitReferenceID), asset.conversationID == conversationID,
                  FileManager.default.fileExists(atPath: try store.assetURL(asset).path) else { throw ImageAgentError.invalidInput("参考图片不存在或不属于当前会话。") }
            if !assets.contains(where: { $0.id == asset.id }) { assets.append(asset) }
        }
        return MemoryContext(entries: entries, assets: assets)
    }
}
