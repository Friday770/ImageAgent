import Foundation
import Testing
@testable import ImageAgentCore

private struct CancelledPlanningTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse { throw CancellationError() }
}

@Suite struct MessageBindingTests {
    @Test func identicalTextSubmissionsGetDistinctDurableRunBindingsAndExactUserText() async throws {
        let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths); let chat = try store.createConversation()
        let client = try APIClient(baseURL: "https://offline.invalid", apiKey: "dummy", transport: CancelledPlanningTransport())
        let engine = AgentEngine(store: store, client: client, clock: { Date(timeIntervalSince1970: 1234) })
        let original = "  两次相同的要求\n"
        let first = try await engine.submit(.init(conversationID: chat.id, text: original))
        let second = try await engine.submit(.init(conversationID: chat.id, text: original))
        let reopened = try SQLiteStore(paths: paths)
        let users = try reopened.messages(in: chat.id).filter { $0.role == .user }
        #expect(first.run.stage == .cancelled && second.run.stage == .cancelled)
        #expect(users.map(\.runID) == [first.run.id, second.run.id])
        #expect(users.allSatisfy { $0.text == original })
        #expect(first.message.runID == first.run.id && second.message.runID == second.run.id)
    }
    @Test func regionalRequestPersistsOriginalTargetAndVectorMaskAcrossRestart() async throws {
        let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths); let chat = try store.createConversation()
        let asset = try store.saveImage(testPNG, conversationID: chat.id, source: .imported)
        var selection = RegionSelection(width: 1, height: 1)
        selection.addRectangle(from: .init(x: 0, y: 0), to: .init(x: 1, y: 1))
        let region = RegionEditRequest(assetID: asset.id, selection: selection)
        let client = try APIClient(baseURL: "https://offline.invalid", apiKey: "dummy", transport: CancelledPlanningTransport())
        let outcome = try await AgentEngine(store: store, client: client).submit(.init(conversationID: chat.id, text: "只修改选区", regionEdit: region))
        let reopened = try SQLiteStore(paths: paths)
        #expect(try reopened.run(outcome.run.id)?.regionEdit == region)
        #expect(try reopened.messages(in: chat.id).first?.assetIDs == [asset.id])
    }
    @Test func optionalRecordAdditionsDecodeLegacyPayloads() throws {
        let message = Data(#"{"id":"m","conversationID":"c","role":"user","text":"old","assetIDs":[],"createdAt":0}"#.utf8)
        let run = Data(#"{"id":"r","conversationID":"c","stage":"cancelled","request":"old","selection":{"model":"gpt-image-2","size":"auto","quality":"high"},"resultAssetIDs":[],"createdAt":0,"updatedAt":0}"#.utf8)
        #expect(try JSONDecoder().decode(MessageRecord.self, from: message).runID == nil)
        #expect(try JSONDecoder().decode(RunRecord.self, from: run).regionEdit == nil)
    }
    @Test func decodedRegionRejectsInvalidDimensionsAndOutOfBoundsVectorMarks() throws {
        let invalid = [
            #"{"width":-1,"height":2,"marks":[]}"#,
            #"{"width":1000000,"height":1000000,"marks":[]}"#,
            #"{"width":4,"height":3,"marks":[{"rectangle":{"_0":{"x":-1,"y":0},"_1":{"x":2,"y":2}}}]}"#,
            #"{"width":4,"height":3,"marks":[{"pen":{"_0":[{"x":0,"y":0}]}}]}"#
        ]
        for json in invalid { #expect(throws: (any Error).self) { try JSONDecoder().decode(RegionSelection.self, from: Data(json.utf8)) } }
        var valid = RegionSelection(width: 20, height: 10)
        valid.addPen(points: [.init(x: 1, y: 1), .init(x: 18, y: 2), .init(x: 8, y: 9)])
        let roundtrip = try JSONDecoder().decode(RegionSelection.self, from: JSONEncoder().encode(valid))
        #expect(roundtrip == valid && roundtrip.coverage() == valid.coverage())
    }
    @Test func unpersistableRegionalContextIsRejectedBeforeCreatingHistory() async throws {
        let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths); let chat = try store.createConversation()
        let asset = try store.saveImage(testPNG, conversationID: chat.id, source: .imported)
        var selection = RegionSelection(width: 1, height: 1)
        for _ in 0..<4097 { selection.addRectangle(from: .init(x: 0, y: 0), to: .init(x: 1, y: 1)) }
        let client = try APIClient(baseURL: "https://offline.invalid", apiKey: "dummy", transport: CancelledPlanningTransport())
        let engine = AgentEngine(store: store, client: client)
        await #expect(throws: (any Error).self) {
            _ = try await engine.submit(.init(conversationID: chat.id, text: "过量选区必须在接受前拒绝", regionEdit: .init(assetID: asset.id, selection: selection)))
        }
        #expect(try store.messages(in: chat.id).isEmpty)
    }

}
