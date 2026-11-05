import AppKit
import Testing
import ImageAgentCore
@testable import ImageAgent

private struct ImmediateCancelledRegionTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse { throw CancellationError() }
}

@MainActor @Suite struct MessageActionTests {
    private func fixture() throws -> (AppModel, SQLiteStore, String, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ImageAgentActions-\(UUID())")
        let store = try SQLiteStore(paths: .init(root: root)); let chat = try store.createConversation()
        let model = AppModel(store: store); model.selectedID = chat.id
        return (model, store, chat.id, root)
    }
    private func records(_ store: SQLiteStore, chat: String, stage: RunStage = .cancelled, text: String = "原始文字", asset: AssetRecord? = nil, region: RegionEditRequest? = nil, legacy: Bool = false, date: Date = Date()) throws -> (MessageRecord, RunRecord) {
        let run = RunRecord(conversationID: chat, stage: stage, request: text, regionEdit: region, createdAt: date)
        let message = MessageRecord(conversationID: chat, role: .user, text: text, assetIDs: asset.map { [$0.id] } ?? [], runID: legacy ? nil : run.id, createdAt: date)
        try store.saveRun(run); try store.addMessage(message)
        return (message, run)
    }
    @Test func copyUsesExactUserTextEvenForSuccessfulRuns() throws {
        let (model, store, chat, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (message, _) = try records(store, chat: chat, stage: .completed, text: "  原话\n保留空格  ")
        let board = NSPasteboard(name: .init("ImageAgentCopy-\(UUID())")); defer { board.releaseGlobally() }
        model.copyMessage(message, to: board)
        #expect(board.string(forType: .string) == message.text)
    }
    @Test func onlyPreciselyCancelledRunCanReturnAndNeverSubmits() throws {
        let (model, store, chat, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for stage in [RunStage.planning, .generating, .editing, .saving, .finalizing, .completed, .failed, .interrupted, .cancelled] {
            let (message, _) = try records(store, chat: chat, stage: stage)
            model.refresh()
            #expect(model.canReturnToEdit(message) == (stage == .cancelled))
            if stage == .cancelled {
                let count = try store.messages(in: chat).count
                #expect(model.returnToEdit(message))
                #expect(model.draft == message.text && !model.isBusy)
                #expect(try store.messages(in: chat).count == count)
            }
        }
    }
    @Test func runningCancellingAndEditorBlockReturnUntilCancellationFinishes() throws {
        let (model, store, chat, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (message, _) = try records(store, chat: chat)
        model.isBusy = true; #expect(!model.canReturnToEdit(message)); #expect(!model.returnToEdit(message))
        model.isBusy = false; model.isCancelling = true; #expect(!model.canReturnToEdit(message))
        model.isCancelling = false
        let asset = try store.saveImage(frontendPNG(), conversationID: chat, source: .imported)
        model.openImageWorkspace(asset); #expect(!model.canReturnToEdit(message))
        model.closeImageWorkspace(); #expect(model.canReturnToEdit(message))
    }
    @Test func explicitBindingDistinguishesIdenticalTextAndLegacyRequiresUniqueExactMatch() throws {
        let (model, store, chat, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 123)
        let (cancelled, _) = try records(store, chat: chat, date: date)
        let (completed, _) = try records(store, chat: chat, stage: .completed, date: date)
        #expect(model.canReturnToEdit(cancelled)); #expect(!model.canReturnToEdit(completed))
        let legacyDate = date.addingTimeInterval(5)
        let (legacy, _) = try records(store, chat: chat, legacy: true, date: legacyDate)
        #expect(model.canReturnToEdit(legacy))
        try store.saveRun(.init(conversationID: chat, stage: .cancelled, request: legacy.text, createdAt: legacyDate))
        #expect(!model.canReturnToEdit(legacy))
        let (near, _) = try records(store, chat: chat, legacy: true, date: date.addingTimeInterval(10))
        let unrelated = MessageRecord(conversationID: chat, role: .user, text: near.text, createdAt: near.createdAt.addingTimeInterval(0.0001))
        try store.addMessage(unrelated); #expect(!model.canReturnToEdit(unrelated))
        let image = try store.saveImage(frontendPNG(), conversationID: chat, source: .imported)
        let (ambiguousImage, _) = try records(store, chat: chat, asset: image, legacy: true)
        #expect(!model.canReturnToEdit(ambiguousImage))
    }
    @Test func returnRestoresReferenceToSourceChatAndPreservesConflictingDrafts() throws {
        let (model, store, chat, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let asset = try store.saveImage(frontendPNG(), conversationID: chat, source: .imported)
        let otherAsset = try store.saveImage(frontendPNG(), conversationID: chat, source: .imported)
        let (message, _) = try records(store, chat: chat, text: "恢复这段话", asset: asset)
        model.draft = "尚未发送的另一个想法"; model.referenceID = otherAsset.id
        #expect(!model.returnToEdit(message)); #expect(model.error != nil)
        #expect(model.draft == "尚未发送的另一个想法" && model.referenceID == otherAsset.id)
        let other = try store.createConversation(); model.selectedID = other.id; model.draft = "其他会话草稿"
        #expect(!model.returnToEdit(message)); #expect(model.selectedID == other.id && model.draft == "其他会话草稿")
        model.selectedID = chat; model.draft = ""; model.referenceID = nil; model.selectedID = other.id
        let focus = model.composerFocusID
        #expect(model.returnToEdit(message)); #expect(model.selectedID == chat && model.draft == message.text && model.referenceID == asset.id)
        #expect(model.composerFocusID != focus)
        model.selectedID = other.id; #expect(model.draft == "其他会话草稿")
        try FileManager.default.removeItem(at: store.assetURL(asset)); model.draft = ""; model.referenceID = nil
        #expect(!model.returnToEdit(message)); #expect(model.selectedID == other.id && model.error != nil)
    }
    @Test func restartedRegionalReturnReopensOriginalEditorWithExactMaskAndNoWholeImageDraft() throws {
        let (_, store, chat, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let asset = try store.saveImage(frontendPNG(), conversationID: chat, source: .imported)
        var selection = RegionSelection(width: 4, height: 3)
        selection.addRectangle(from: .init(x: 1, y: 1), to: .init(x: 3, y: 2))
        let region = RegionEditRequest(assetID: asset.id, selection: selection)
        let (message, _) = try records(store, chat: chat, text: "只改框里的部分", asset: asset, region: region)
        let restarted = AppModel(store: try SQLiteStore(paths: .init(root: root)))
        restarted.selectedID = chat; restarted.refresh()
        #expect(restarted.returnToEdit(message))
        let session = try #require(restarted.imageWorkspace)
        #expect(session.target.assetID == asset.id && session.target.conversationID == chat)
        let editor = ImageEditorModel(app: restarted, target: session.target, sessionID: session.id); editor.load()
        #expect(editor.selection == selection && editor.prompt == message.text)
        #expect(restarted.draft.isEmpty && restarted.referenceID == nil && !restarted.isBusy)
        restarted.closeImageWorkspace()
        var changed = selection; changed.clear()
        restarted.retainEditorDraft(.init(selection: changed, prompt: "新编辑草稿", tool: .rectangle), for: session.target)
        #expect(!restarted.returnToEdit(message))
        #expect(restarted.editorDraft(for: session.target)?.prompt == "新编辑草稿")
    }
    @Test func cancelledRegionalSubmissionReturnsWithOriginalWhitespaceAndExistingSnapshot() async throws {
        let (_, store, chat, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let asset = try store.saveImage(frontendPNG(), conversationID: chat, source: .imported)
        let client = try APIClient(baseURL: "https://offline.invalid", apiKey: "dummy", transport: ImmediateCancelledRegionTransport())
        let model = AppModel(store: store, engine: AgentEngine(store: store, client: client)); model.selectedID = chat; model.hasConnection = true
        var selection = RegionSelection(width: 4, height: 3); selection.addRectangle(from: .init(x: 1, y: 1), to: .init(x: 3, y: 2))
        let instruction = "  只改选区\n保持其余内容  \n"
        #expect(model.submitRegionEdit(conversationID: chat, assetID: asset.id, selection: selection, instruction: instruction) { _ in })
        for _ in 0..<1000 { if !model.isBusy { break }; try await Task.sleep(for: .milliseconds(1)) }
        #expect(!model.isBusy)
        let user = try #require(model.messages.first { $0.role == .user })
        #expect(user.text == instruction)
        #expect(model.returnToEdit(user))
        let target = try #require(model.imageWorkspace?.target)
        #expect(model.editorDraft(for: target)?.prompt == instruction && model.editorDraft(for: target)?.selection == selection)
    }

}
