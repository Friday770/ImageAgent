import Foundation
import AppKit
import Testing
import ImageAgentCore
@testable import ImageAgent

private let editorPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a0X8AAAAASUVORK5CYII=")!
private actor EditorTransport: HTTPTransport {
    let reference: String
    let failing: Bool
    var requests: [URLRequest] = []
    private var holdPlanning = false
    private var planningContinuation: CheckedContinuation<Void, Never>?
    func holdNextPlanning() { holdPlanning = true }
    func releasePlanning() { holdPlanning = false; planningContinuation?.resume(); planningContinuation = nil }
    init(reference: String, failing: Bool = false) { self.reference = reference; self.failing = failing }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        if failing { return .init(data: Data("{\"error\":{\"message\":\"offline failure\"}}".utf8), statusCode: 500) }
        if request.url?.path == "/v1/responses" {
            if holdPlanning { await withCheckedContinuation { planningContinuation = $0 } }
            let args: [String: JSONValue] = ["action": .string("edit"), "prompt": .string("Change selected region"), "model": .string("gpt-image-2.5-flare"), "size": .string("auto"), "quality": .string("high"), "reference_image_id": .string(reference), "reply_text": .string("Done")]
            let json: JSONValue = .object(["status": .string("completed"), "output": .array([.object(["type": .string("function_call"), "name": .string("prepare_image_request"), "call_id": .string("call_1"), "arguments": .string(try JSONValue.object(args).encodedString())])])])
            return .init(data: try JSONEncoder().encode(json), statusCode: 200)
        }
        return .init(data: Data("{\"data\":[{\"b64_json\":\"\(editorPNG.base64EncodedString())\"}]}".utf8), statusCode: 200)
    }
}

@MainActor @Suite struct ImageEditorTests {
    @Test func annotationAndEraseUseTheFilledPenTool() throws {
        let (app, _, a, _, _, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let editor = ImageEditorModel(app: app, target: .init(conversationID: a.conversationID, assetID: a.id)); editor.load()
        editor.annotate()
        #expect(editor.tool.rawValue == "pen" && editor.tool.title == "钢笔圈选")
        editor.tool = .rectangle
        #expect(editor.tool.title == "方框")
        editor.erase()
        #expect(editor.tool.rawValue == "pen" && !app.isBusy)
    }

    private func fixture(failing: Bool = false) throws -> (AppModel, SQLiteStore, AssetRecord, AssetRecord, EditorTransport, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ImageEditorTests-\(UUID().uuidString)")
        let store = try SQLiteStore(paths: AppPaths(root: root))
        let first = try store.createConversation(); let second = try store.createConversation()
        let a = try store.saveImage(editorPNG, conversationID: first.id, source: .imported)
        let b = try store.saveImage(editorPNG, conversationID: second.id, source: .imported)
        let transport = EditorTransport(reference: a.id, failing: failing)
        let engine = AgentEngine(store: store, client: try APIClient(baseURL: "https://example.test", apiKey: "dummy-test-key", transport: transport))
        let app = AppModel(store: store, engine: engine)
        app.hasConnection = true; app.settings.selection = .init(model: .flare, size: .landscape, quality: .high)
        app.selectedID = first.id; app.refresh()
        return (app, store, a, b, transport, root)
    }
    private func wait(_ app: AppModel) async throws {
        for _ in 0..<1000 { if !app.isBusy { return }; try await Task.sleep(for: .milliseconds(1)) }
        Issue.record("Editor task did not finish")
    }
    private func select(_ editor: ImageEditorModel) {
        editor.selection.addRectangle(from: .init(x: 0, y: 0), to: .init(x: 1, y: 1))
        editor.prompt = "Change selected color"
    }
    @Test func acceptedEditorKeepsImmutableSourceWhileResultsGoToChat() async throws {
        let (app, store, a, b, transport, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = ImageEditorModel(app: app, target: .init(conversationID: a.conversationID, assetID: a.id)); first.load()
        let second = ImageEditorModel(app: app, target: .init(conversationID: b.conversationID, assetID: b.id)); second.load()
        select(first); select(second)
        app.selectedID = b.conversationID; app.selectionChanged()
        #expect(app.asset(a.id)?.id == a.id)
        first.submit()
        #expect(app.isBusy && app.activeConversationID == a.conversationID)
        app.deleteConversation(a.conversationID)
        #expect(try store.conversation(a.conversationID) != nil)
        try await wait(app)
        #expect(first.lastRun?.stage == .completed)
        #expect(first.currentAsset?.id == a.id)
        #expect(!first.selection.isEmpty && !first.prompt.isEmpty)
        #expect(second.currentAsset?.id == b.id && !second.selection.isEmpty && !second.prompt.isEmpty)
        #expect(app.settings.selection.size == .landscape)
        #expect(try store.assets(in: a.conversationID).count == 2)
        #expect(try store.assets(in: b.conversationID).count == 1)
        #expect(await transport.requests.count == 2)
    }
    @Test func failedEditKeepsPromptSelectionAndSource() async throws {
        let (app, _, a, _, transport, root) = try fixture(failing: true); defer { try? FileManager.default.removeItem(at: root) }
        let editor = ImageEditorModel(app: app, target: .init(conversationID: a.conversationID, assetID: a.id)); editor.load(); select(editor)
        let selection = editor.selection; let prompt = editor.prompt
        editor.submit(); try await wait(app)
        #expect(editor.lastRun?.stage == .failed && editor.error != nil)
        #expect(editor.selection == selection && editor.prompt == prompt && editor.currentAsset?.id == a.id)
        #expect(await transport.requests.count == 1)
    }
    @Test func referenceActionFromOtherWindowReturnsToItsOriginConversation() throws {
        let (app, _, a, b, _, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        app.selectedID = b.conversationID; app.selectionChanged()
        app.useReference(a); app.selectionChanged()
        #expect(app.selectedID == a.conversationID)
        #expect(app.referenceID == a.id && app.selectedReference?.id == a.id)
    }

    @Test func missingAndForeignWindowTargetsAreRejectedClearly() throws {
        let (app, store, a, b, _, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let foreign = ImageEditorModel(app: app, target: .init(conversationID: a.conversationID, assetID: b.id)); foreign.load()
        #expect(foreign.image == nil && foreign.error != nil)
        try store.deleteConversation(a.conversationID)
        let deleted = ImageEditorModel(app: app, target: .init(conversationID: a.conversationID, assetID: a.id)); deleted.load()
        #expect(deleted.image == nil && deleted.error != nil)
    }
    @Test func referenceActionPreservesOtherConversationDraftAndRejectsAttachmentReplacement() throws {
        let (app, store, a, b, _, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        app.draft = "origin draft"
        app.selectedID = b.conversationID; app.selectionChanged()
        app.draft = "other draft"; app.referenceID = b.id
        app.useReference(a)
        #expect(app.draft == "origin draft" && app.referenceID == a.id)
        app.selectedID = b.conversationID; app.selectionChanged()
        #expect(app.draft == "other draft" && app.referenceID == b.id)
        let another = try store.saveImage(editorPNG, conversationID: b.conversationID, source: .imported)
        app.useReference(another)
        #expect(app.referenceID == b.id && app.draft == "other draft")
        #expect(app.error != nil)
    }

    @Test(arguments: [EditorTool.pen, .rectangle]) func workspaceSessionsRestoreOnlyTheirOwnDraftAndSelection(tool: EditorTool) throws {
        let (app, _, a, b, _, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(app.openImageWorkspace(a))
        let firstSession = app.imageWorkspace!
        let first = ImageEditorModel(app: app, target: firstSession.target, sessionID: firstSession.id)
        first.load(); select(first); first.tool = tool
        first.selection.addPen(points: [.init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1)])
        let selection = first.selection
        app.closeImageWorkspace()
        #expect(app.openImageWorkspace(b))
        let other = ImageEditorModel(app: app, target: app.imageWorkspace!.target, sessionID: app.imageWorkspace!.id)
        other.load()
        #expect(other.prompt.isEmpty && other.selection.isEmpty && other.currentAsset?.id == b.id)
        app.closeImageWorkspace()
        #expect(app.openImageWorkspace(a))
        let reopened = app.imageWorkspace!
        #expect(reopened.id != firstSession.id)
        let restored = ImageEditorModel(app: app, target: reopened.target, sessionID: reopened.id); restored.load()
        #expect(restored.prompt == first.prompt && restored.selection == selection)
        #expect(restored.tool == tool && restored.selection.outlines.count == 2)
        app.closeImageWorkspace(sessionID: firstSession.id)
        #expect(app.imageWorkspace?.id == reopened.id)
        restored.selection.undo()
        app.closeImageWorkspace(); app.openImageWorkspace(a)
        let afterUndo = ImageEditorModel(app: app, target: app.imageWorkspace!.target, sessionID: app.imageWorkspace!.id); afterUndo.load()
        #expect(afterUndo.tool == tool && afterUndo.selection.outlines.count == 1)
        afterUndo.selection.clear()
        app.closeImageWorkspace(); app.openImageWorkspace(a)
        let afterClear = ImageEditorModel(app: app, target: app.imageWorkspace!.target, sessionID: app.imageWorkspace!.id); afterClear.load()
        #expect(afterClear.selection.isEmpty && afterClear.selection.outlines.isEmpty && !afterClear.selection.canUndo)
    }
    @Test func overlayBlocksChatSubmissionAndRejectsInvalidEditWithoutDismissal() async throws {
        let (app, store, a, _, transport, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        app.draft = "unrelated unsent composer"
        app.openImageWorkspace(a)
        let session = app.imageWorkspace!
        #expect(!app.canSend)
        app.send()
        #expect(!app.isBusy && app.draft == "unrelated unsent composer")
        let editor = ImageEditorModel(app: app, target: session.target, sessionID: session.id); editor.load()
        editor.prompt = "kept instruction"; editor.submit()
        #expect(app.imageWorkspace?.id == session.id && editor.error != nil && !editor.isSubmitting)
        #expect(editor.prompt == "kept instruction" && editor.selection.isEmpty)
        #expect(try store.messages(in: a.conversationID).isEmpty)
        #expect(await transport.requests.isEmpty)
    }
    @Test func acceptedSubmissionDismissesToOriginOnceAndRetainsFailureForExplicitRecovery() async throws {
        let (app, store, a, b, transport, root) = try fixture(failing: true); defer { try? FileManager.default.removeItem(at: root) }
        app.draft = "source composer"
        app.selectedID = b.conversationID; app.selectionChanged(); app.draft = "other composer"; app.referenceID = b.id
        app.openImageWorkspace(a)
        let session = app.imageWorkspace!
        let editor = ImageEditorModel(app: app, target: session.target, sessionID: session.id); editor.load(); select(editor)
        editor.submit(); editor.submit()
        #expect(app.imageWorkspace?.id == session.id)
        let submissionID = app.activeSubmissionID!
        try await wait(app)
        #expect(app.imageWorkspace == nil && app.selectedID == a.conversationID)
        #expect(app.draft == "source composer" && app.referenceID == nil)
        #expect(try store.messages(in: a.conversationID).filter { $0.role == .user }.count == 1)
        #expect(await transport.requests.count == 1)
        #expect(app.failedEditorTarget == session.target)
        let finishedRun = editor.lastRun!
        app.receiveProgress(finishedRun, submissionID: submissionID, accepted: { app.openImageWorkspace(b) })
        #expect(app.imageWorkspace == nil && !app.isBusy && app.activeRun?.id == finishedRun.id)
        app.selectedID = b.conversationID; app.selectionChanged()
        #expect(app.draft == "other composer" && app.referenceID == b.id)
        app.reopenFailedEdit()
        let restored = ImageEditorModel(app: app, target: app.imageWorkspace!.target, sessionID: app.imageWorkspace!.id); restored.load()
        #expect(restored.prompt == editor.prompt && restored.selection == editor.selection)
        #expect(restored.lastRun?.id == finishedRun.id && restored.error != nil)
        #expect(!app.isBusy)
        #expect(await transport.requests.count == 1)
    }
    @Test func commentReturnsToSourceWithoutLosingDraftAndEraseRequiresConfirmation() throws {
        let (app, _, a, b, _, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        app.draft = "keep this text"
        app.selectedID = b.conversationID; app.selectionChanged(); app.draft = "other text"
        app.openImageWorkspace(a)
        let session = app.imageWorkspace!
        let editor = ImageEditorModel(app: app, target: session.target, sessionID: session.id); editor.load()
        editor.erase()
        #expect(editor.tool == .pen && !editor.prompt.isEmpty && !app.isBusy)
        editor.addComment()
        #expect(app.imageWorkspace == nil && app.selectedID == a.conversationID)
        #expect(app.draft == "keep this text" && app.referenceID == a.id)
        app.selectedID = b.conversationID; app.selectionChanged()
        #expect(app.draft == "other text")
    }

    @Test func closingAndReplacingOverlayDoesNotCancelTaskOrLetStaleCallbacksCloseNewSession() async throws {
        let (app, store, a, b, transport, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await transport.holdNextPlanning()
        app.openImageWorkspace(a)
        let session = app.imageWorkspace!
        let editor = ImageEditorModel(app: app, target: session.target, sessionID: session.id); editor.load(); select(editor)
        editor.submit()
        let firstSubmission = app.activeSubmissionID!
        app.closeImageWorkspace(); app.openImageWorkspace(b)
        let newerSession = app.imageWorkspace!
        for _ in 0..<1000 { if await transport.requests.count == 1 { break }; try await Task.sleep(for: .milliseconds(1)) }
        #expect(app.isBusy && app.selectedID == a.conversationID)
        #expect(app.imageWorkspace?.id == newerSession.id)
        #expect(try store.messages(in: a.conversationID).filter { $0.role == .user }.count == 1)
        app.closeImageWorkspace()
        #expect(app.isBusy)
        await transport.releasePlanning(); try await wait(app)
        #expect(editor.lastRun?.stage == .completed && app.imageWorkspace == nil)
        let oldRun = editor.lastRun!
        await transport.holdNextPlanning()
        app.openImageWorkspace(a)
        let secondSession = app.imageWorkspace!
        let second = ImageEditorModel(app: app, target: secondSession.target, sessionID: secondSession.id); second.load(); select(second)
        second.submit()
        let activeID = app.activeSubmissionID
        app.receiveProgress(oldRun, submissionID: firstSubmission, accepted: { app.closeImageWorkspace() })
        #expect(app.activeSubmissionID == activeID && app.activeRun == nil)
        #expect(app.imageWorkspace?.id == secondSession.id)
        await transport.releasePlanning(); try await wait(app)
        #expect(await transport.requests.count == 4)
        #expect(try store.runs(in: a.conversationID).count == 2)
    }
    @Test func engineRejectionBeforePersistenceKeepsWorkspaceAndDraft() async throws {
        let (app, store, a, _, transport, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        app.openImageWorkspace(a)
        let session = app.imageWorkspace!
        let editor = ImageEditorModel(app: app, target: session.target, sessionID: session.id); editor.load()
        editor.selection = RegionSelection(width: 2, height: 1)
        editor.selection.addRectangle(from: .init(x: 0, y: 0), to: .init(x: 2, y: 1))
        editor.prompt = "preserve rejected instruction"
        editor.submit(); try await wait(app)
        #expect(app.imageWorkspace?.id == session.id && editor.error != nil)
        #expect(editor.prompt == "preserve rejected instruction" && !editor.selection.isEmpty)
        #expect(try store.messages(in: a.conversationID).isEmpty)
        #expect(await transport.requests.isEmpty)
    }
    @Test func obsoleteEditorCannotSubmitAfterItsSessionIsReplaced() async throws {
        let (app, store, a, b, transport, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        app.openImageWorkspace(a)
        let session = app.imageWorkspace!
        let editor = ImageEditorModel(app: app, target: session.target, sessionID: session.id); editor.load(); select(editor)
        app.openImageWorkspace(b)
        let current = app.imageWorkspace!.id
        editor.submit()
        #expect(!app.isBusy && editor.error != nil && app.imageWorkspace?.id == current)
        #expect(try store.messages(in: a.conversationID).isEmpty)
        #expect(await transport.requests.isEmpty)
    }

    @Test func staleEditorChangesCannotReplaceNewSessionDraftOrAttachComments() throws {
        let (app, _, a, _, _, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        app.openImageWorkspace(a)
        let oldSession = app.imageWorkspace!
        let old = ImageEditorModel(app: app, target: oldSession.target, sessionID: oldSession.id); old.load(); select(old)
        app.closeImageWorkspace(); app.openImageWorkspace(a)
        let session = app.imageWorkspace!
        let current = ImageEditorModel(app: app, target: session.target, sessionID: session.id); current.load()
        current.prompt = "newer session instruction"
        old.prompt = "late obsolete instruction"; old.submit(); old.addComment()
        #expect(app.imageWorkspace?.id == session.id && app.referenceID == nil)
        app.closeImageWorkspace(); app.openImageWorkspace(a)
        let restored = ImageEditorModel(app: app, target: app.imageWorkspace!.target, sessionID: app.imageWorkspace!.id); restored.load()
        #expect(restored.prompt == "newer session instruction")
    }
    @Test func eraseKeepsExistingInstructionAndDoesNotDuplicateItsPreset() throws {
        let (app, _, a, _, _, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let editor = ImageEditorModel(app: app, target: .init(conversationID: a.conversationID, assetID: a.id)); editor.load()
        editor.prompt = "保留衣服上的细节"
        editor.erase(); let combined = editor.prompt
        #expect(combined.contains("保留衣服上的细节") && combined.contains("移除选中的内容"))
        editor.erase()
        #expect(editor.prompt == combined && !app.isBusy)
    }

}
