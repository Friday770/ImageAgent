import Foundation
import Testing
import ImageAgentCore
@testable import ImageAgent

private actor AppPromptTransport: HTTPTransport {
    private var receive: (@Sendable (HTTPStreamEvent) throws -> Void)?
    private var continuation: CheckedContinuation<Void, Error>?
    private var readiness: [CheckedContinuation<Void, Never>] = []
    private(set) var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        return .init(data: Data(#"{"error":{"message":"offline image failure"}}"#.utf8), statusCode: 500)
    }
    func stream(_ request: URLRequest, receive: @escaping @Sendable (HTTPStreamEvent) throws -> Void) async throws {
        requests.append(request); self.receive = receive
        try receive(.response(statusCode: 200, contentType: "text/event-stream"))
        for waiter in readiness { waiter.resume() }; readiness = []
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func ready() async { if receive == nil { await withCheckedContinuation { readiness.append($0) } } }
    func fragment(_ value: String, first: Bool = false) throws {
        if first {
            try emit(["type": .string("response.output_item.added"), "output_index": .number(0), "item": .object(["id": .string("fc_1"), "type": .string("function_call"), "name": .string("prepare_image_request"), "call_id": .string("call_1"), "arguments": .string("")])])
        }
        try emit(["type": .string("response.function_call_arguments.delta"), "output_index": .number(0), "item_id": .string("fc_1"), "delta": .string(value)])
    }
    func finish() { continuation?.resume(); continuation = nil; receive = nil }
    private func emit(_ fields: [String: JSONValue]) throws {
        try receive?(.bytes(Data(("data: " + (try JSONValue.object(fields).encodedString()) + "\n\n").utf8)))
    }
}

@MainActor @Suite struct PromptStreamingTests {
    @Test func startupRecoveryPersistsValidatedPromptOnceWithoutReplayingAnUnregisteredImageTask() async throws {
        for stage in [RunStage.generating, .editing] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("PromptRestartTests-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try SQLiteStore(paths: AppPaths(root: root)); let conversation = try store.createConversation()
            let prompt = "Exactly the validated prompt sent before restart."
            let run = RunRecord(conversationID: conversation.id, stage: stage, request: "lake", detailedPrompt: prompt)
            try store.saveRun(run)
            let transport = AppPromptTransport()
            var notices: [MessageRecord] = []
            for _ in 0..<2 {
                let reopened = try SQLiteStore(paths: AppPaths(root: root))
                let client = try APIClient(baseURL: "https://example.test", apiKey: "dummy-test-key", transport: transport)
                let model = AppModel(store: reopened, engine: AgentEngine(store: reopened, client: client)); model.selectedID = conversation.id; model.refresh()
                #expect(model.messages.count == 1 && model.messages.first?.id == "interrupted-\(run.id)")
                #expect(model.messages.first?.detailedPrompt == prompt && model.messages.first?.assetIDs.isEmpty == true)
                #expect(model.runs.count == 1 && model.runs.first?.stage == .interrupted && model.runs.first?.detailedPrompt == prompt)
                #expect(model.assets.isEmpty && !model.isBusy)
                if notices.isEmpty { notices = model.messages } else { #expect(model.messages == notices) }
                await Task.yield()
            }
            #expect(await transport.requests.isEmpty)
        }
    }

    @Test func isolatedDemoCannotSwitchIntoCredentialConnectionAndRetainsNamedHistory() async throws {
        let session = "test-\(UUID().uuidString)"
        let arguments = ["ImageAgent", "--streaming-demo", "--streaming-demo-session", session, "--configure-from-environment"]
        let model = AppModel(arguments: arguments)
        let root = try #require(model.store?.paths.root); defer { try? FileManager.default.removeItem(at: root) }
        await model.start()
        #expect(model.isDemo && model.isStreamingDemo && model.hasConnection && model.error == nil)
        #expect(!model.canSend && root.lastPathComponent == "ImageAgentDemo-\(session)")
        let conversation = try #require(model.selectedID)
        let count = model.conversations.count
        let prompt = "Saved demo prompt"
        try model.store?.addMessage(.init(conversationID: conversation, role: .assistant, text: "Saved demo reply", detailedPrompt: prompt))
        model.changeConnection()
        #expect(model.hasConnection)
        let reopened = AppModel(arguments: arguments); await reopened.start()
        #expect(reopened.conversations.count == count)
        #expect(reopened.messages.last?.detailedPrompt == prompt && reopened.hasConnection)
    }

    private func fixture() throws -> (AppModel, SQLiteStore, AppPromptTransport, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PromptStreamingTests-\(UUID().uuidString)")
        let store = try SQLiteStore(paths: AppPaths(root: root)); let conversation = try store.createConversation()
        let transport = AppPromptTransport()
        let client = try APIClient(baseURL: "https://example.test", apiKey: "dummy-test-key", transport: transport)
        let model = AppModel(store: store, engine: AgentEngine(store: store, client: client))
        model.hasConnection = true; model.selectedID = conversation.id; model.refresh()
        return (model, store, transport, root)
    }
    private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(1)) }
        Issue.record("Timed out waiting for prompt lifecycle")
    }

    @Test func livePromptIsSourceBoundTransientAndStaleTerminalCallbacksCannotResurrectIt() async throws {
        let (model, store, transport, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = model.selectedID!; let other = try store.createConversation()
        model.draft = "lake"; model.send(); await transport.ready()
        try await wait { model.activeRun != nil }
        let run = model.activeRun!; let token = model.activeSubmissionID!
        try await transport.fragment(#"{"prompt":"清晨"#, first: true)
        try await wait { model.planningPrompt?.text == "清晨" }
        #expect(model.visiblePlanningPrompt?.status == .planning)
        #expect(try store.run(run.id)?.detailedPrompt == nil)
        model.receivePlanningPreview(.init(conversationID: other.id, runID: run.id, text: "foreign"), submissionID: token)
        model.receivePlanningPreview(.init(conversationID: source, runID: "foreign-run", text: "foreign"), submissionID: token)
        model.receivePlanningPreview(.init(conversationID: source, runID: run.id, text: "stale"), submissionID: UUID())
        #expect(model.planningPrompt?.text == "清晨")
        model.selectedID = other.id; model.selectionChanged(); model.draft = "keep draft"
        #expect(model.visiblePlanningPrompt == nil)
        try await transport.fragment("的湖泊")
        try await wait { model.planningPrompt?.text == "清晨的湖泊" }
        #expect(model.visiblePlanningPrompt == nil && model.draft == "keep draft")
        await transport.finish(); try await wait { !model.isBusy }
        #expect(model.planningPrompt?.status == .unfinished)
        let terminal = model.activeRun!
        model.receivePlanningPreview(.init(conversationID: source, runID: run.id, text: "late"), submissionID: token)
        model.receiveProgress(run, submissionID: token)
        #expect(model.activeRun == terminal && model.planningPrompt?.text == "清晨的湖泊")
        model.selectedID = source; model.selectionChanged()
        #expect(model.visiblePlanningPrompt?.status == .unfinished)
        #expect(model.messages.last?.detailedPrompt == nil)
        #expect(await transport.requests.count == 1)
    }

    @Test func progressCannotRegressAfterTerminalOrSwitchRunIdentityWithinOneSubmission() async throws {
        let (model, _, transport, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        model.draft = "lake"; model.send(); await transport.ready(); try await wait { model.activeRun != nil }
        let original = model.activeRun!; let token = model.activeSubmissionID!
        let foreign = RunRecord(conversationID: original.conversationID, request: "foreign")
        model.receiveProgress(foreign, submissionID: token)
        #expect(model.activeRun?.id == original.id)
        var completed = original; completed.stage = .failed
        model.receiveProgress(completed, submissionID: token)
        model.receiveProgress(original, submissionID: token)
        model.receivePlanningPreview(.init(conversationID: original.conversationID, runID: original.id, text: "late"), submissionID: token)
        #expect(model.activeRun?.stage == .failed && model.planningPrompt == nil)
        await transport.finish(); try await wait { !model.isBusy }
    }

    @Test func regionPreviewNeverAcceptsWorkspaceFromTextAndSurvivesCloseAndChatSwitch() async throws {
        let (model, store, transport, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = model.selectedID!; let other = try store.createConversation()
        let image = try PixelImage(width: 2, height: 2, rgba: [UInt8](repeating: 255, count: 16)).pngData()
        let asset = try store.saveImage(image, conversationID: source, source: .imported)
        model.openImageWorkspace(asset); let session = model.imageWorkspace!
        var selection = RegionSelection(width: 2, height: 2)
        selection.addRectangle(from: .init(x: 0, y: 0), to: .init(x: 1, y: 1))
        #expect(model.submitRegionEdit(conversationID: source, assetID: asset.id, selection: selection, instruction: "blue", workspaceSessionID: session.id, completion: { _ in }))
        let token = model.activeSubmissionID!
        model.receivePlanningPreview(.init(conversationID: source, runID: "not-accepted", text: "preview"), submissionID: token)
        #expect(model.imageWorkspace?.id == session.id && model.planningPrompt == nil)
        await transport.ready(); try await wait { model.activeRun != nil }
        #expect(model.imageWorkspace == nil && model.selectedID == source)
        model.selectedID = other.id; model.selectionChanged(); model.draft = "other draft"
        try await transport.fragment(#"{"prompt":"仅修改选区"#, first: true)
        try await wait { model.planningPrompt != nil }
        #expect(model.planningPrompt?.conversationID == source && model.visiblePlanningPrompt == nil)
        await transport.finish(); try await wait { !model.isBusy }
        #expect(model.draft == "other draft" && model.failedEditorTarget?.assetID == asset.id)
        model.selectedID = source; model.selectionChanged()
        #expect(model.visiblePlanningPrompt?.status == .unfinished)
        #expect(model.editorDraft(for: session.target)?.selection == selection)
    }
}
