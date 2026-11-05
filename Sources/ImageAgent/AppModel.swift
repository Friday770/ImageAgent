import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Darwin
import ImageAgentCore

struct PlanningPromptState: Equatable {
    enum Status { case planning, validated, unfinished }
    let conversationID: String
    let runID: String
    var text: String
    var status: Status
}

@MainActor final class AppModel: ObservableObject {
    @Published var settings = AppSettings()
    @Published var endpointText = "https://api.example.com/v1"
    @Published var keyText = ""
    @Published var hasConnection = false
    @Published var isConnecting = false
    @Published var connectionNote = ""
    @Published var connectionError: String?
    @Published var error: String?
    @Published var startupError: String?
    @Published var conversations: [Conversation] = []
    @Published var selectedID: String? {
        didSet {
            guard selectedID != oldValue else { return }
            if let oldValue { composerDrafts[oldValue] = .init(text: draft, referenceID: referenceID) }
            let saved = selectedID.flatMap { composerDrafts[$0] }
            draft = saved?.text ?? ""; referenceID = saved?.referenceID
        }
    }
    @Published var messages: [MessageRecord] = []
    @Published var assets: [AssetRecord] = []
    @Published var runs: [RunRecord] = []
    @Published var draft = ""
    @Published var referenceID: String?
    @Published var activeRun: RunRecord?
    @Published private(set) var planningPrompt: PlanningPromptState?
    @Published var isBusy = false
    @Published var isCancelling = false
    @Published var showSettings = false
    @Published private(set) var activeConversationID: String?
    @Published private(set) var imageWorkspace: ImageWorkspaceSession?
    @Published private(set) var failedEditorTarget: ImageEditorTarget?
    @Published private(set) var composerFocusID = UUID()
    let isDemo: Bool
    let isStreamingDemo: Bool
    let isFrontendDemo: Bool
    let isConnectionDemo: Bool
    let store: SQLiteStore?
    private var credentials: any CredentialStore
    private var transport: any HTTPTransport
    private var engine: AgentEngine?
    private var task: Task<Void, Never>?
    private var started = false
    private struct ComposerDraft { var text: String; var referenceID: String? }
    private var composerDrafts: [String: ComposerDraft] = [:]
    private var editorDrafts: [ImageEditorTarget: ImageEditorDraft] = [:]
    private var editorFailures: [ImageEditorTarget: RunRecord] = [:]
    private(set) var activeSubmissionID: UUID?
    private var submissionAccepted = false
    private let launchArguments: [String]

    init(store suppliedStore: SQLiteStore? = nil, engine: AgentEngine? = nil, arguments: [String] = CommandLine.arguments,
         credentials: any CredentialStore = KeychainCredentialStore(), transport: any HTTPTransport = URLSessionTransport(),
         bundledDemoSession: String? = Bundle.main.object(forInfoDictionaryKey: "ImageAgentOfflineDemoSession") as? String) {
        self.engine = engine; self.credentials = credentials; self.transport = transport
        launchArguments = arguments
        isStreamingDemo = arguments.contains("--streaming-demo")
        isFrontendDemo = arguments.contains("--frontend-demo") || bundledDemoSession != nil
        isDemo = arguments.contains("--demo") || isStreamingDemo || isFrontendDemo
        isConnectionDemo = arguments.contains("--connection-demo")
        do {
            let isolated = isDemo || isConnectionDemo
            let session: String
            if isFrontendDemo {
                if let index = arguments.firstIndex(of: "--frontend-demo-session"), index + 1 < arguments.count { session = arguments[index + 1] }
                else { session = bundledDemoSession ?? UUID().uuidString }
                guard session.range(of: #"^[A-Za-z0-9_-]{1,80}$"#, options: .regularExpression) != nil else { throw ImageAgentError.invalidInput("离线演示 session 名称无效。") }
            } else if isStreamingDemo, let index = arguments.firstIndex(of: "--streaming-demo-session"), index + 1 < arguments.count {
                session = arguments[index + 1]
                guard session.range(of: #"^[A-Za-z0-9_-]{1,80}$"#, options: .regularExpression) != nil else { throw ImageAgentError.invalidInput("离线演示 session 名称无效。") }
            } else { session = UUID().uuidString }
            let root = isolated ? FileManager.default.temporaryDirectory.appendingPathComponent("\(isFrontendDemo ? "ImageAgentFrontendDemo" : "ImageAgentDemo")-\(session)") : nil
            let created = try suppliedStore ?? SQLiteStore(paths: AppPaths(root: root))
            let loadedSettings = try created.settings()
            try created.recoverInterruptedRuns()
            if isFrontendDemo {
                self.credentials = FrontendDemoCredentials(root: created.paths.root)
                self.transport = FrontendDemoTransport()
            }
            store = created; settings = loadedSettings; endpointText = loadedSettings.endpoint
        } catch { store = nil; startupError = error.localizedDescription }
    }
    var currentConversation: Conversation? { conversations.first { $0.id == selectedID } }
    var selectedReference: AssetRecord? { assets.first { $0.id == referenceID } }
    var visiblePlanningPrompt: PlanningPromptState? {
        guard let planningPrompt, planningPrompt.conversationID == selectedID, !planningPrompt.text.isEmpty else { return nil }
        return planningPrompt
    }
    var pendingAssets: [AssetRecord] {
        let shown = Set(messages.flatMap(\.assetIDs))
        return assets.filter { $0.source != .imported && !shown.contains($0.id) }
    }
    var canSend: Bool { imageWorkspace == nil && hasConnection && (!isDemo || isFrontendDemo) && !isBusy && !isConnecting && selectedID != nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var dataPath: String { store?.paths.root.path ?? "不可用" }

    func start() async {
        guard !started, let store else { return }; started = true
        if isDemo {
            do {
                if try store.conversations().isEmpty { try seedDemo(store) }
                if isFrontendDemo {
                    guard let demoTransport = transport as? FrontendDemoTransport else { throw ImageAgentError.invalidInput("离线 transport 不可用。") }
                    await demoTransport.setImage(demoPNG())
                    let credentials = self.credentials, endpoint = try ServiceEndpoint(settings.endpoint)
                    if let key = try await Task.detached(operation: { try credentials.key(for: endpoint.string) }).value {
                        engine = AgentEngine(store: store, client: try APIClient(baseURL: endpoint.string, apiKey: key, plannerModel: settings.plannerModel, transport: demoTransport))
                        hasConnection = true
                    }
                } else { hasConnection = true }
                refresh()
            } catch { self.error = error.localizedDescription }
            return
        }
        if isConnectionDemo { refresh(); return }
        do {
            if let connection = try EnvironmentConnection.consumeIfRequested(arguments: launchArguments, read: { name in
                guard let value = getenv(name) else { return nil }; return String(cString: value)
            }, clear: { _ = unsetenv($0) }) {
                _ = await saveConnection(address: connection.baseURL, key: connection.apiKey)
                return
            }
        } catch { self.error = error.localizedDescription; connectionNote = ""; return }
        refresh()
        isConnecting = true; connectionNote = "正在恢复已保存的连接…"
        defer { isConnecting = false }
        do {
            let endpoint = try ServiceEndpoint(settings.endpoint)
            let credentials = self.credentials
            let key = try await Task.detached { try credentials.key(for: endpoint.string) }.value
            if let key {
                let client = try APIClient(baseURL: endpoint.string, apiKey: key, plannerModel: settings.plannerModel, transport: transport)
                engine = AgentEngine(store: store, client: client); hasConnection = true
                connectionNote = "已恢复保存的连接"
                if conversations.isEmpty { newConversation() }
            } else { connectionNote = "" }
        } catch { self.error = error.localizedDescription; connectionError = self.error; connectionNote = "" }
    }
    func savedAPIKeyForSettings(for address: String) async throws -> String? {
        let endpoint = try ServiceEndpoint(address).string
        guard endpoint == settings.endpoint, (!isDemo || isFrontendDemo), (!isConnectionDemo || isFrontendDemo) else { return nil }
        let credentials = self.credentials
        let key = try await Task.detached { try credentials.key(for: endpoint) }.value
        guard !Task.isCancelled, endpoint == settings.endpoint else { return nil }
        return key
    }
    private var canChangeConnection: Bool { !isConnecting && !isBusy && (!isDemo || isFrontendDemo) && (!isConnectionDemo || isFrontendDemo) && store != nil }
    func plannerModels(address: String, key input: String) async throws -> [String] {
        guard canChangeConnection else { throw ImageAgentError.invalidInput("当前无法刷新模型列表，请等待任务或连接保存完成。") }
        let endpoint = try ServiceEndpoint(address)
        let entered = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let key: String?
        if !entered.isEmpty { key = entered }
        else {
            let credentials = self.credentials
            key = try await Task.detached { try credentials.key(for: endpoint.string) }.value
        }
        try Task.checkCancellation()
        guard canChangeConnection else { throw ImageAgentError.invalidInput("当前无法刷新模型列表，请等待任务或连接保存完成。") }
        guard let key else { throw ImageAgentError.credential("请输入此服务的 API Key 后刷新模型列表。") }
        let client = try APIClient(baseURL: endpoint.string, apiKey: key, transport: transport)
        do { return try await client.validateConnection() }
        catch { throw ImageAgentError.invalidInput(client.safeDescription(error)) }
    }
    private func beginConnectionSave() -> Bool {
        guard canChangeConnection else {
            connectionError = "请等待当前任务或连接操作完成，再保存 API 设置。"; return false
        }
        isConnecting = true; error = nil; connectionError = nil; connectionNote = "正在验证并保存连接…"
        return true
    }
    func connect() {
        guard beginConnectionSave() else { return }
        let address = endpointText, enteredKey = keyText, plannerModel = settings.plannerModel
        Task { _ = await performConnectionSave(address: address, key: enteredKey, plannerModel: plannerModel) }
    }
    @discardableResult func saveConnection(address: String, key: String, plannerModel: String? = nil) async -> Bool {
        guard beginConnectionSave() else { return false }
        return await performConnectionSave(address: address, key: key, plannerModel: plannerModel ?? settings.plannerModel)
    }
    private func performConnectionSave(address: String, key input: String, plannerModel: String) async -> Bool {
        defer { isConnecting = false }
        guard let store else { return false }
        var candidateClient: APIClient?
        do {
            let planner = try PlannerModel.validated(plannerModel)
            let endpoint = try ServiceEndpoint(address)
            let entered = input.trimmingCharacters(in: .whitespacesAndNewlines)
            let credentials = self.credentials
            let previousKey = try await Task.detached { try credentials.key(for: endpoint.string) }.value
            try Task.checkCancellation()
            if let previousKey, !previousKey.isEmpty, planner.contains(previousKey) {
                throw ImageAgentError.invalidInput("规划模型 ID 不能包含 API 凭据。")
            }
            guard let key = entered.isEmpty ? previousKey : entered else { throw ImageAgentError.credential("请输入此服务的 API Key；空白只会复用这个地址自己保存的 Key。") }
            let client = try APIClient(baseURL: endpoint.string, apiKey: key, plannerModel: planner, transport: transport)
            candidateClient = client
            let models = try await client.validateConnection()
            try Task.checkCancellation()
            let writesCredential = !entered.isEmpty && entered != previousKey
            if writesCredential { try await Task.detached { try credentials.save(key, for: endpoint.string) }.value }
            do {
                try Task.checkCancellation()
                // Preserve unrelated settings changed during validation/credential access.
                var candidate = settings; candidate.endpoint = endpoint.string; candidate.plannerModel = planner
                try store.saveSettings(candidate)
                settings = candidate
            } catch {
                if writesCredential {
                    do {
                        try await Task.detached {
                            if let previousKey { try credentials.save(previousKey, for: endpoint.string) }
                            else { try credentials.delete(for: endpoint.string) }
                        }.value
                    } catch {
                        throw ImageAgentError.credential("API 设置未切换；恢复候选地址的钥匙串凭据失败。请在系统允许访问后重新保存该地址。原连接和历史仍保留。")
                    }
                }
                throw error
            }
            endpointText = endpoint.string; keyText = ""
            engine = AgentEngine(store: store, client: client); hasConnection = true
            connectionNote = "连接已保存 · \(models.count) 个可见模型"; connectionError = nil; error = nil
            refresh(); if conversations.isEmpty { newConversation() }
            return true
        } catch {
            let description = candidateClient?.safeDescription(error) ?? error.localizedDescription
            self.error = description; connectionError = description; connectionNote = ""
            return false
        }
    }
    func changeConnection() {
        guard !isBusy, !isConnecting else { return }
        endpointText = settings.endpoint; keyText = ""; connectionError = nil; showSettings = true
    }
    func disconnect() {
        guard beginConnectionSave() else { return }
        let address = settings.endpoint, credentials = self.credentials
        Task {
            defer { isConnecting = false }
            do {
                let endpoint = try ServiceEndpoint(address)
                try await Task.detached { try credentials.delete(for: endpoint.string) }.value
                showSettings = false; hasConnection = false; engine = nil; keyText = ""; error = nil; connectionNote = ""; connectionError = nil
                endpointText = settings.endpoint
            } catch { self.error = error.localizedDescription; connectionError = self.error; connectionNote = "" }
        }
    }
    func persistSettings() {
        do { try store?.saveSettings(settings) } catch { self.error = error.localizedDescription }
    }
    func refresh() {
        guard let store else { return }
        do {
            conversations = try store.conversations()
            if selectedID == nil || !conversations.contains(where: { $0.id == selectedID }) { selectedID = conversations.first?.id }
            if let id = selectedID {
                messages = try store.messages(in: id); assets = try store.assets(in: id); runs = try store.runs(in: id)
            } else { messages = []; assets = []; runs = [] }
        } catch { self.error = error.localizedDescription }
    }
    func selectionChanged() {
        refresh()
    }
    func newConversation() {
        guard imageWorkspace == nil else { return }
        do {
            guard let store else { return }
            let created = try store.createConversation(); selectedID = created.id; draft = ""; referenceID = nil; refresh()
        } catch { self.error = error.localizedDescription }
    }
    func deleteConversation(_ id: String) {
        guard imageWorkspace == nil else { return }
        guard activeConversationID != id || !isBusy else { return }
        do {
            try store?.deleteConversation(id); if selectedID == id { selectedID = nil }; refresh()
            composerDrafts[id] = nil; editorDrafts = editorDrafts.filter { $0.key.conversationID != id }
            editorFailures = editorFailures.filter { $0.key.conversationID != id }
            if failedEditorTarget?.conversationID == id { failedEditorTarget = nil }
        }
        catch { self.error = error.localizedDescription }
    }
    func resetMemory() {
        guard imageWorkspace == nil, let selectedID else { return }
        do { try store?.resetMemory(selectedID); error = nil; refresh() }
        catch { self.error = error.localizedDescription }
    }
    func send() {
        guard canSend, let selectedID, let engine else { return }
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).count <= 8000 else {
            error = "请输入 1–8000 字的需求。"
            return
        }
        let request = AgentRequest(conversationID: selectedID, text: draft, selection: settings.selection, referenceAssetID: referenceID)
        submitMessage(request, engine: engine)
    }
    func startStreamingDemo(interrupt: Bool = false) {
        guard isStreamingDemo, !isBusy, imageWorkspace == nil, let selectedID, let store else { return }
        do {
            let transport = SimulatedPlanningTransport(imageData: demoPNG(), selection: settings.selection, interruptAfterPreview: interrupt)
            let client = try APIClient(baseURL: "https://offline.invalid", apiKey: "offline-demo-placeholder", plannerModel: settings.plannerModel, transport: transport)
            let engine = AgentEngine(store: store, client: client)
            let request = AgentRequest(conversationID: selectedID, text: interrupt ? "离线模拟：展示中断后的提示词预览。" : "离线模拟：把山间湖泊的想法整理成图片提示词。", selection: settings.selection)
            submitMessage(request, engine: engine)
        } catch { self.error = error.localizedDescription }
    }
    private func submitMessage(_ request: AgentRequest, engine: AgentEngine) {
        let policy = settings.memory
        draft = ""; referenceID = nil; error = nil
        let submissionID = beginSubmission(conversationID: request.conversationID)
        task = Task { [weak self] in
            do {
                let outcome = try await engine.submit(request, policy: policy, progress: { [weak self] run in
                    Task { @MainActor in self?.receiveProgress(run, submissionID: submissionID) }
                }, planningPreview: { [weak self] preview in
                    Task { @MainActor in self?.receivePlanningPreview(preview, submissionID: submissionID) }
                })
                self?.receiveProgress(outcome.run, submissionID: submissionID)
            } catch {
                guard let self, self.activeSubmissionID == submissionID else { return }
                if self.selectedID == request.conversationID, self.draft.isEmpty, self.referenceID == nil {
                    self.draft = request.text; self.referenceID = request.referenceAssetID
                } else if self.selectedID != request.conversationID,
                          self.composerDrafts[request.conversationID]?.text.isEmpty != false,
                          self.composerDrafts[request.conversationID]?.referenceID == nil {
                    self.composerDrafts[request.conversationID] = .init(text: request.text, referenceID: request.referenceAssetID)
                }
                self.error = error.localizedDescription
            }
            self?.finishSubmission(submissionID)
        }
    }
    func cancel() { isCancelling = true; task?.cancel() }
    @discardableResult func pasteReference(from pasteboard: NSPasteboard) -> Bool {
        do {
            guard let data = try PasteboardImageReader.read(pasteboard) else { return false }
            return importReference(data)
        } catch { self.error = error.localizedDescription; return false }
    }
    private func canImportReference() -> Bool {
        guard !isBusy, !isConnecting, imageWorkspace == nil, selectedID != nil else {
            error = "请先等待当前任务或连接保存完成，并关闭图片工作区，再添加参考图。"; return false
        }
        guard referenceID == nil else { error = "已有未发送的参考图。请先发送或移除该附件，再添加图片。"; return false }
        return true
    }
    @discardableResult func importReference(_ data: Data) -> Bool {
        guard canImportReference(), let selectedID, let store else { return false }
        do {
            let validated = try PasteboardImageReader.validate(data)
            let asset = try store.saveImage(validated, conversationID: selectedID, source: .imported)
            refresh(); referenceID = asset.id; error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func uploadReference() {
        guard canImportReference() else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .webP, .tiff]; panel.allowsMultipleSelection = false
        panel.message = "选择 PNG、TIFF、JPEG 或 WebP 作为当前会话的参考图"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = importReference(try PasteboardImageReader.readFile(url))
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult func useReference(_ asset: AssetRecord) -> Bool {
        guard !isBusy, !isConnecting else { error = "请等待当前任务或连接保存完成，再选择参考图。"; return false }
        do { _ = try editorAsset(asset.id, conversationID: asset.conversationID) }
        catch { self.error = error.localizedDescription; return false }
        let existing = selectedID == asset.conversationID ? referenceID : composerDrafts[asset.conversationID]?.referenceID
        guard existing == nil || existing == asset.id else {
            error = "来源会话已有另一张未发送的参考图。请先发送或移除该附件，再添加评论。"
            return false
        }
        selectedID = asset.conversationID; refresh(); referenceID = asset.id; composerFocusID = UUID(); error = nil
        return true
    }
    @discardableResult func openImageWorkspace(_ asset: AssetRecord) -> Bool {
        do { _ = try editorAsset(asset.id, conversationID: asset.conversationID) }
        catch { self.error = error.localizedDescription; return false }
        imageWorkspace = .init(target: .init(conversationID: asset.conversationID, assetID: asset.id))
        return true
    }
    func closeImageWorkspace(sessionID: UUID? = nil) {
        guard sessionID == nil || imageWorkspace?.id == sessionID else { return }
        imageWorkspace = nil
    }
    func editorDraft(for target: ImageEditorTarget) -> ImageEditorDraft? { editorDrafts[target] }
    func editorFailure(for target: ImageEditorTarget) -> RunRecord? { editorFailures[target] }
    func retainEditorDraft(_ draft: ImageEditorDraft, for target: ImageEditorTarget, sessionID: UUID? = nil) {
        if let sessionID { guard imageWorkspace?.id == sessionID, imageWorkspace?.target == target else { return } }
        editorDrafts[target] = draft
    }
    func reopenFailedEdit() {
        guard let target = failedEditorTarget else { return }
        do { _ = openImageWorkspace(try editorAsset(target.assetID, conversationID: target.conversationID)) }
        catch { self.error = error.localizedDescription }
    }
    private func beginSubmission(conversationID: String) -> UUID {
        let id = UUID(); activeSubmissionID = id; submissionAccepted = false
        isBusy = true; isCancelling = false; activeConversationID = conversationID; activeRun = nil; planningPrompt = nil
        return id
    }
    func receiveProgress(_ run: RunRecord, submissionID: UUID, accepted: (() -> Void)? = nil) {
        guard activeSubmissionID == submissionID, activeConversationID == run.conversationID else { return }
        if let previous = activeRun {
            guard previous.id == run.id, !previous.stage.isTerminal, progressOrder(run.stage) >= progressOrder(previous.stage) else { return }
        }
        activeRun = run
        if run.stage.isTerminal {
            if run.detailedPrompt != nil || run.stage == .completed { planningPrompt = nil }
            else if planningPrompt?.runID == run.id { planningPrompt?.status = .unfinished }
        } else if let prompt = run.detailedPrompt, !prompt.isEmpty {
            planningPrompt = .init(conversationID: run.conversationID, runID: run.id, text: prompt, status: .validated)
        }
        if !submissionAccepted { submissionAccepted = true; accepted?() }
        refresh()
    }
    func receivePlanningPreview(_ preview: PlanningPreview, submissionID: UUID) {
        guard activeSubmissionID == submissionID, activeConversationID == preview.conversationID,
              let run = activeRun, run.id == preview.runID, run.stage == .planning, !isCancelling,
              !preview.text.isEmpty, preview.text.count <= 32_000 else { return }
        planningPrompt = .init(conversationID: preview.conversationID, runID: preview.runID, text: preview.text, status: .planning)
    }
    private func progressOrder(_ stage: RunStage) -> Int {
        switch stage { case .planning: return 0; case .generating, .editing: return 1; case .saving: return 2; case .finalizing: return 3; default: return 4 }
    }
    private func finishSubmission(_ submissionID: UUID) {
        guard activeSubmissionID == submissionID else { return }
        if planningPrompt?.status == .planning { planningPrompt?.status = .unfinished }
        activeSubmissionID = nil; isBusy = false; isCancelling = false; activeConversationID = nil; task = nil; refresh()
    }
    func asset(_ id: String) -> AssetRecord? { try? store?.asset(id) }
    func editorAsset(_ id: String, conversationID: String) throws -> AssetRecord {
        guard let store, try store.conversation(conversationID) != nil,
              let asset = try store.asset(id), asset.conversationID == conversationID else {
            throw ImageAgentError.invalidInput("原图片或原会话已删除，或图片不属于该会话。")
        }
        guard FileManager.default.fileExists(atPath: try store.assetURL(asset).path) else { throw ImageAgentError.invalidImage("原始图片文件不可用。") }
        return asset
    }
    func editorPixels(_ asset: AssetRecord) throws -> PixelImage {
        guard let store else { throw ImageAgentError.storage("本地数据不可用。") }
        _ = try editorAsset(asset.id, conversationID: asset.conversationID)
        return try PixelImage(data: Data(contentsOf: store.assetURL(asset)))
    }
    @discardableResult func submitRegionEdit(conversationID: String, assetID: String, selection: RegionSelection, instruction: String,
                                            workspaceSessionID: UUID? = nil,
                                            completion: @escaping (Result<RunOutcome, Error>) -> Void) -> Bool {
        if let workspaceSessionID {
            guard imageWorkspace?.id == workspaceSessionID,
                  imageWorkspace?.target == ImageEditorTarget(conversationID: conversationID, assetID: assetID) else {
                completion(.failure(ImageAgentError.invalidInput("图片工作区已切换，请在当前图片中确认修改。"))); return false
            }
        }
        guard hasConnection, (!isDemo || isFrontendDemo), let engine else { completion(.failure(ImageAgentError.invalidInput("请先在主窗口连接图片服务。"))); return false }
        guard !isBusy, !isConnecting else { completion(.failure(ImageAgentError.busy)); return false }
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 8000, !selection.isEmpty else {
            completion(.failure(ImageAgentError.invalidInput("请选择区域，并输入 1–8000 字的修改要求。"))); return false
        }
        do { _ = try editorAsset(assetID, conversationID: conversationID) }
        catch { completion(.failure(error)); return false }
        let request = AgentRequest(conversationID: conversationID, text: instruction, selection: settings.selection,
                                   referenceAssetID: assetID, regionEdit: RegionEditRequest(assetID: assetID, selection: selection))
        let policy = settings.memory
        let target = ImageEditorTarget(conversationID: conversationID, assetID: assetID)
        let snapshot = ImageEditorDraft(selection: selection, prompt: instruction, tool: editorDrafts[target]?.tool ?? .pen)
        editorDrafts[target] = snapshot
        let submissionID = beginSubmission(conversationID: conversationID); error = nil
        let accepted: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.selectedID = conversationID; self.refresh()
            if let workspaceSessionID { self.closeImageWorkspace(sessionID: workspaceSessionID) }
        }
        task = Task { [weak self] in
            let result: Result<RunOutcome, Error>
            do {
                result = .success(try await engine.submit(request, policy: policy, progress: { [weak self] run in
                    Task { @MainActor in self?.receiveProgress(run, submissionID: submissionID, accepted: accepted) }
                }, planningPreview: { [weak self] preview in
                    Task { @MainActor in self?.receivePlanningPreview(preview, submissionID: submissionID) }
                }))
            } catch { result = .failure(error) }
            guard let self, self.activeSubmissionID == submissionID else { return }
            switch result {
            case .success(let outcome):
                // A terminal outcome is also persisted acceptance if queued progress has not run yet.
                self.receiveProgress(outcome.run, submissionID: submissionID, accepted: accepted)
                if outcome.run.stage == .completed {
                    if self.editorDrafts[target] == snapshot { self.editorDrafts[target] = nil }
                    self.editorFailures[target] = nil
                    if self.failedEditorTarget == target { self.failedEditorTarget = nil }
                } else {
                    self.failedEditorTarget = target; self.editorFailures[target] = outcome.run; self.error = outcome.run.error
                }
            case .failure(let failure):
                self.error = failure.localizedDescription
                if self.submissionAccepted {
                    self.failedEditorTarget = target
                    if var run = self.activeRun { run.error = failure.localizedDescription; self.editorFailures[target] = run }
                }
            }
            self.finishSubmission(submissionID)
            completion(result)
        }
        return true
    }
    func revealRecovery(_ run: RunRecord) {
        do { if let url = try store?.recoveryURL(run) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
        catch { self.error = error.localizedDescription }
    }
    func image(_ asset: AssetRecord) -> NSImage? { guard let url = try? store?.assetURL(asset) else { return nil }; return NSImage(contentsOf: url) }
    func export(_ asset: AssetRecord) {
        guard let source = try? store?.assetURL(asset) else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "ImageAgent-\(asset.id.prefix(8)).\(source.pathExtension)"
        if let type = UTType(filenameExtension: source.pathExtension) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            try Data(contentsOf: source).write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        } catch { self.error = error.localizedDescription }
    }
    func reveal(_ asset: AssetRecord) { if let url = try? store?.assetURL(asset) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    func openDataFolder() { if let url = store?.paths.root { NSWorkspace.shared.open(url) } }
    private func cancelledRun(for message: MessageRecord) throws -> RunRecord? {
        guard message.role == .user, let store,
              try store.conversation(message.conversationID) != nil else { return nil }
        let history = try store.messages(in: message.conversationID)
        guard history.contains(message), message.assetIDs.count <= 1 else { return nil }
        let run: RunRecord
        if let runID = message.runID {
            guard let bound = try store.run(runID), bound.conversationID == message.conversationID,
                  history.filter({ $0.role == .user && $0.runID == runID }).count == 1 else { return nil }
            run = bound
        } else {
            let matches = try store.runs(in: message.conversationID).filter { $0.createdAt == message.createdAt && $0.request == message.text }
            guard matches.count == 1, let match = matches.first,
                  history.filter({ $0.role == .user && $0.createdAt == message.createdAt && $0.text == message.text }).count == 1 else { return nil }
            // Old image requests did not record whether they were regional. Never turn an unknown mask into a full-image edit.
            guard message.assetIDs.isEmpty || match.regionEdit != nil else { return nil }
            run = match
        }
        guard run.stage == .cancelled else { return nil }
        for id in message.assetIDs { _ = try editorAsset(id, conversationID: message.conversationID) }
        if let region = run.regionEdit {
            guard message.assetIDs == [region.assetID] else { return nil }
        }
        return run
    }
    func canReturnToEdit(_ message: MessageRecord) -> Bool {
        guard !isBusy, !isCancelling, !isConnecting, imageWorkspace == nil else { return false }
        return (try? cancelledRun(for: message)) != nil
    }
    @discardableResult func returnToEdit(_ message: MessageRecord) -> Bool {
        guard !isBusy, !isCancelling, !isConnecting, imageWorkspace == nil else {
            error = "请等待当前任务取消完成，并关闭图片工作区，再返回编辑。"; return false
        }
        do {
            guard let run = try cancelledRun(for: message) else {
                throw ImageAgentError.invalidInput("只有准确关联且已取消的任务可以返回编辑；旧的图片任务可能缺少原选区。")
            }
            let saved = selectedID == message.conversationID ? ComposerDraft(text: draft, referenceID: referenceID) : composerDrafts[message.conversationID]
            let restoredReference = message.assetIDs.first
            guard saved?.text.isEmpty != false || saved?.text == message.text,
                  saved?.referenceID == nil || saved?.referenceID == restoredReference else {
                throw ImageAgentError.invalidInput("来源会话已有不同的未发送草稿或参考图。请先发送或移除它们，再返回编辑。")
            }
            for id in message.assetIDs {
                let asset = try editorAsset(id, conversationID: message.conversationID)
                _ = try editorPixels(asset)
            }
            if let region = run.regionEdit {
                let asset = try editorAsset(region.assetID, conversationID: message.conversationID)
                let pixels = try editorPixels(asset)
                guard region.selection.width == pixels.width, region.selection.height == pixels.height, !region.selection.isEmpty else {
                    throw ImageAgentError.invalidInput("原选区与图片不匹配，不能改为整张图片编辑。")
                }
                let target = ImageEditorTarget(conversationID: message.conversationID, assetID: region.assetID)
                if let existing = editorDrafts[target], (!existing.prompt.isEmpty || !existing.selection.isEmpty),
                   existing.prompt != message.text || existing.selection != region.selection {
                    throw ImageAgentError.invalidInput("这张图片已有不同的编辑草稿。请先处理该草稿，再恢复原任务。")
                }
                editorDrafts[target] = .init(selection: region.selection, prompt: message.text, tool: .pen)
                selectedID = message.conversationID; refresh()
                imageWorkspace = .init(target: target)
            } else {
                selectedID = message.conversationID; refresh()
                draft = message.text; referenceID = restoredReference; composerFocusID = UUID()
            }
            error = nil; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func copyMessage(_ message: MessageRecord, to pasteboard: NSPasteboard = .general) {
        guard message.role == .user else { return }
        pasteboard.clearContents(); pasteboard.setString(message.text, forType: .string)
    }
    func copyPrompt(_ asset: AssetRecord) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(asset.prompt, forType: .string) }

    private func seedDemo(_ store: SQLiteStore) throws {
        if !isFrontendDemo { settings.selection = .init(model: .flare) }
        let now = Date()
        let conversation = try store.createConversation(title: "山间的一日 · 创作练习", now: now.addingTimeInterval(-900))
        selectedID = conversation.id
        _ = try store.createConversation(title: "咖啡品牌视觉", now: now.addingTimeInterval(-3600))
        _ = try store.createConversation(title: "一些还没成形的想法", now: now.addingTimeInterval(-7200))
        let prompt = "一幅极简、温暖的山间湖泊插画。远山层叠，清晨的光从画面右上方落下，赭红色小屋坐落在岸边，深绿色松树与薄雾构成宁静的留白。纸张颗粒质感，柔和奶油色与森林绿配色，方形构图，无文字。"
        try store.addMessage(.init(conversationID: conversation.id, role: .user, text: "想要一张安静的山间湖泊插画。暖一点的晨光，有一间小屋，像周末醒来的感觉。", createdAt: now.addingTimeInterval(-800)))
        let asset = try store.saveImage(demoPNG(), conversationID: conversation.id, source: .generated, prompt: prompt, selection: settings.selection, now: now.addingTimeInterval(-790))
        try store.addMessage(.init(conversationID: conversation.id, role: .assistant, text: "把清晨留在了这片湖边。暖色天空、层叠的远山和一间临水小屋，让画面有一点慢下来的感觉。\n\n可以继续调整光线、色彩，或选这张图作为参考。", assetIDs: [asset.id], detailedPrompt: prompt, createdAt: now.addingTimeInterval(-780)))
        if isFrontendDemo {
            let text = "离线示例：让晨光更温暖一些。"
            let run = RunRecord(conversationID: conversation.id, stage: .cancelled, request: text, createdAt: now.addingTimeInterval(-700))
            try store.saveRun(run)
            try store.addMessage(.init(conversationID: conversation.id, role: .user, text: text, runID: run.id, createdAt: run.createdAt))
            try store.addMessage(.init(conversationID: conversation.id, role: .assistant, text: "离线模拟：任务已取消，可以返回编辑。", runID: run.id, createdAt: now.addingTimeInterval(-690)))
            var selection = RegionSelection(width: 1024, height: 1024)
            selection.addRectangle(from: .init(x: 540, y: 540), to: .init(x: 760, y: 750))
            let regionalText = "离线局部示例：只让方框内的小屋变亮。"
            let regional = RunRecord(conversationID: conversation.id, stage: .cancelled, request: regionalText, regionEdit: .init(assetID: asset.id, selection: selection), createdAt: now.addingTimeInterval(-600))
            try store.saveRun(regional)
            try store.addMessage(.init(conversationID: conversation.id, role: .user, text: regionalText, assetIDs: [asset.id], runID: regional.id, createdAt: regional.createdAt))
            try store.addMessage(.init(conversationID: conversation.id, role: .assistant, text: "离线模拟：局部任务已取消，原选区可以返回图片工作区。", runID: regional.id, createdAt: now.addingTimeInterval(-590)))
        }
    }
    private func demoPNG() -> Data {
        let image = NSImage(size: NSSize(width: 1024, height: 1024))
        image.lockFocus()
        NSColor(calibratedRed: 0.94, green: 0.88, blue: 0.74, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
        NSColor(calibratedRed: 0.98, green: 0.79, blue: 0.48, alpha: 1).setFill(); NSBezierPath(ovalIn: NSRect(x: 700, y: 680, width: 142, height: 142)).fill()
        func shape(_ points: [(CGFloat, CGFloat)], _ color: NSColor) {
            color.setFill(); let path = NSBezierPath(); path.move(to: NSPoint(x: points[0].0, y: points[0].1))
            for p in points.dropFirst() { path.line(to: NSPoint(x: p.0, y: p.1)) }; path.close(); path.fill()
        }
        shape([(0,400),(0,590),(210,800),(430,560),(640,750),(1024,470),(1024,300)], NSColor(calibratedRed: 0.59, green: 0.67, blue: 0.58, alpha: 1))
        shape([(0,350),(0,450),(340,670),(600,470),(850,620),(1024,420),(1024,250)], NSColor(calibratedRed: 0.32, green: 0.49, blue: 0.42, alpha: 1))
        NSColor(calibratedRed: 0.54, green: 0.69, blue: 0.61, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 1024, height: 350).fill()
        shape([(0,0),(0,250),(230,330),(440,270),(680,260),(1024,150),(1024,0)], NSColor(calibratedRed: 0.18, green: 0.35, blue: 0.29, alpha: 1))
        NSColor(calibratedRed: 0.78, green: 0.42, blue: 0.26, alpha: 1).setFill(); NSRect(x: 560, y: 285, width: 180, height: 110).fill()
        shape([(540,395),(650,485),(760,395)], NSColor(calibratedRed: 0.28, green: 0.29, blue: 0.23, alpha: 1))
        NSColor(calibratedRed: 0.99, green: 0.83, blue: 0.52, alpha: 1).setFill(); NSRect(x: 585, y: 320, width: 36, height: 43).fill()
        for (x, y, h) in [(130.0,170.0,280.0),(230.0,190.0,190.0),(850.0,100.0,320.0)] {
            shape([(x-60,y),(x,y+h),(x+60,y)], NSColor(calibratedRed: 0.12, green: 0.28, blue: 0.23, alpha: 1))
        }
        image.unlockFocus()
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }
}
