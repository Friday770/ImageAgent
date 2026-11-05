import Foundation
import Testing
import ImageAgentCore
@testable import ImageAgent

private struct FailingTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        .init(data: Data(#"{"error":{"message":"test planning failure"}}"#.utf8), statusCode: 500)
    }
}

@MainActor @Suite struct AppModelTests {
    private func fixture() throws -> (AppModel, SQLiteStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ImageAgentAppTests-\(UUID().uuidString)")
        let store = try SQLiteStore(paths: AppPaths(root: root))
        let conversation = try store.createConversation()
        let client = try APIClient(baseURL: "https://example.test", apiKey: "dummy-test-key", transport: FailingTransport())
        let model = AppModel(store: store, engine: AgentEngine(store: store, client: client))
        model.hasConnection = true; model.selectedID = conversation.id
        return (model, store, root)
    }
    private func waitUntilIdle(_ model: AppModel) async throws {
        for _ in 0..<1000 {
            if !model.isBusy { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Submission did not become idle")
    }
    @Test func overlongDraftIsRejectedBeforeClearingComposer() throws {
        let (model, _, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let draft = String(repeating: "画", count: 8001)
        model.draft = draft; model.referenceID = "kept-reference"
        model.send()
        #expect(model.draft == draft && model.referenceID == "kept-reference")
        #expect(!model.isBusy && model.error != nil)
    }
    @Test func thrownRejectionRestoresUntouchedDraftAndReference() async throws {
        let (model, store, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        model.draft = "保持人物，修改背景"; model.referenceID = "unknown-reference"
        model.send(); try await waitUntilIdle(model)
        #expect(model.draft == "保持人物，修改背景")
        #expect(model.referenceID == "unknown-reference")
        #expect(try store.messages(in: model.selectedID!).isEmpty)
    }
    @Test func thrownRejectionDoesNotOverwriteNewerComposerInput() async throws {
        let (model, _, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        model.draft = "rejected draft"; model.referenceID = "unknown-reference"; model.send()
        model.draft = "newer draft"; model.referenceID = "newer-reference"
        try await waitUntilIdle(model)
        #expect(model.draft == "newer draft" && model.referenceID == "newer-reference")
    }
    @Test func thrownRejectionDoesNotRestoreIntoAnotherConversation() async throws {
        let (model, store, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let origin = model.selectedID
        model.draft = "rejected draft"; model.referenceID = "unknown-reference"; model.send()
        model.selectedID = try store.createConversation().id; model.selectionChanged()
        try await waitUntilIdle(model)
        #expect(model.draft.isEmpty && model.referenceID == nil)
        model.selectedID = origin; model.selectionChanged()
        #expect(model.draft == "rejected draft" && model.referenceID == "unknown-reference")
    }
    @Test func persistedFailedOutcomeKeepsComposerCleared() async throws {
        let (model, store, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        model.draft = "a valid request"; model.send(); try await waitUntilIdle(model)
        #expect(model.draft.isEmpty && model.referenceID == nil)
        #expect(try store.messages(in: model.selectedID!).count == 2)
        #expect(try store.runs(in: model.selectedID!).first?.stage == .failed)
    }
    @Test func conversationDraftsAndAttachmentsSurviveSwitching() throws {
        let (model, store, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = model.selectedID!
        let second = try store.createConversation().id
        model.draft = "first unsent text"; model.referenceID = "first attachment"
        model.selectedID = second; model.selectionChanged()
        #expect(model.draft.isEmpty && model.referenceID == nil)
        model.draft = "second unsent text"; model.referenceID = "second attachment"
        model.selectedID = first; model.selectionChanged()
        #expect(model.draft == "first unsent text" && model.referenceID == "first attachment")
        model.selectedID = second; model.selectionChanged()
        #expect(model.draft == "second unsent text" && model.referenceID == "second attachment")
    }

}
