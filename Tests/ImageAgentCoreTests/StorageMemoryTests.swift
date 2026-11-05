import Foundation
import Testing
@testable import ImageAgentCore

func temporaryPaths() throws -> AppPaths {
    try AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("ImageAgentTests-\(UUID().uuidString)"))
}

@Suite struct StorageTests {
    @Test func reopenCascadeAndSecretFreeSettings() throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths)
        let first = try store.createConversation(title: "first")
        let second = try store.createConversation(title: "second")
        try store.addMessage(.init(conversationID: first.id, role: .user, text: "remember me"))
        try store.addMessage(.init(conversationID: second.id, role: .user, text: "isolated"))
        try store.saveSettings(.init())
        let reopened = try SQLiteStore(paths: paths)
        #expect(try reopened.messages(in: first.id).map(\.text) == ["remember me"])
        #expect(try reopened.messages(in: second.id).map(\.text) == ["isolated"])
        #expect(try reopened.settings().memory == MemoryPolicy())
        try reopened.deleteConversation(first.id)
        #expect(try reopened.messages(in: first.id).isEmpty)
        #expect(try reopened.conversations().count == 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: paths.database.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test(arguments: [RunStage.planning, .generating]) func recoversStaleRunWithoutReplaying(_ stage: RunStage) throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths)
        let conversation = try store.createConversation()
        let run = RunRecord(conversationID: conversation.id, stage: stage, request: "a blue bird")
        try store.saveRun(run)
        try store.recoverInterruptedRuns(now: Date(timeIntervalSince1970: 200))
        #expect(try store.runs(in: conversation.id).first?.stage == .interrupted)
        #expect(try store.runs(in: conversation.id).first?.updatedAt == Date(timeIntervalSince1970: 200))
        let notices = try store.messages(in: conversation.id)
        #expect(notices.count == 1)
        #expect(notices.first?.role == .assistant && notices.first?.assetIDs.isEmpty == true)
        #expect(notices.first?.text.contains("中断") == true)
        #expect(notices.first?.text.contains("远端请求状态未知") == true)
        #expect(notices.first?.text.contains("不会自动重试") == true)
        try store.recoverInterruptedRuns(now: Date(timeIntervalSince1970: 300))
        #expect(try store.messages(in: conversation.id) == notices)
        #expect(try store.runs(in: conversation.id).count == 1)
        #expect(try store.runs(in: conversation.id).first?.updatedAt == Date(timeIntervalSince1970: 200))
    }

    @Test func rejectsInvalidIDsAndCrossSessionParent() throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths)
        let one = try store.createConversation()
        let two = try store.createConversation()
        let asset = try store.saveImage(testPNG, conversationID: one.id, source: .imported)
        #expect(throws: (any Error).self) {
            try store.saveImage(testPNG, conversationID: two.id, parentAssetID: asset.id, source: .edited)
        }
        #expect(throws: (any Error).self) { try store.assetURL(relativePath: "../../outside.png") }
        #expect(try store.assets(in: one.id).count == 1)
        try store.deleteConversation(one.id)
        #expect(!FileManager.default.fileExists(atPath: paths.assets.appendingPathComponent(one.id).path))
    }
}

@Suite struct MemoryTests {
    @Test func boundedTurnsExpiryAndResetPersistAcrossRestart() throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths)
        let now = Date(timeIntervalSince1970: 200_000)
        let conversation = try store.createConversation(now: now.addingTimeInterval(-100_000))
        try store.addMessage(.init(conversationID: conversation.id, role: .user, text: "expired", createdAt: now.addingTimeInterval(-90_000)))
        for i in 0..<15 {
            let time = now.addingTimeInterval(Double(-1000 + i * 10))
            try store.addMessage(.init(conversationID: conversation.id, role: .user, text: "user \(i)", createdAt: time))
            try store.addMessage(.init(conversationID: conversation.id, role: .assistant, text: "answer \(i)", createdAt: time.addingTimeInterval(1)))
        }
        let memory = try MemoryBuilder(store: store, clock: { now }).build(conversationID: conversation.id)
        #expect(memory.entries.count == 24)
        #expect(memory.entries.first?.text == "user 3")
        #expect(!memory.entries.contains { $0.text == "expired" })
        try store.resetMemory(conversation.id, at: now)
        let reopened = try SQLiteStore(paths: paths)
        #expect(try MemoryBuilder(store: reopened, clock: { now }).build(conversationID: conversation.id).entries.isEmpty)
        #expect(try reopened.messages(in: conversation.id).count == 31)
    }

    @Test func explicitOldReferenceAndConversationIsolation() throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths)
        let now = Date(timeIntervalSince1970: 200_000)
        let a = try store.createConversation()
        let b = try store.createConversation()
        let image = try store.saveImage(testPNG, conversationID: a.id, source: .imported, now: now.addingTimeInterval(-100_000))
        let builder = MemoryBuilder(store: store, clock: { now })
        #expect(try builder.build(conversationID: a.id).assets.isEmpty)
        #expect(try builder.build(conversationID: a.id, explicitReferenceID: image.id).assets.map(\.id) == [image.id])
        #expect(throws: (any Error).self) { try builder.build(conversationID: b.id, explicitReferenceID: image.id) }
        try store.addMessage(.init(conversationID: a.id, role: .user, text: String(repeating: "x", count: 5000), createdAt: now))
        let bounded = try builder.build(conversationID: a.id, policy: .init(maxCharacters: 300))
        #expect(bounded.entries.reduce(0) { $0 + $1.text.count } <= 300)
    }
}

let testPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a0X8AAAAASUVORK5CYII=")!
