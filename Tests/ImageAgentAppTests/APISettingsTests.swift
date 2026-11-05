import Foundation
import Testing
import CSQLite
import ImageAgentCore
@testable import ImageAgent

final class FakeCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private var failRead = false, failSave = false
    private var mainThreadReads = 0
    init(_ values: [String: String] = [:]) { self.values = values }
    func failures(read: Bool = false, save: Bool = false) { lock.lock(); defer { lock.unlock() }; failRead = read; failSave = save }
    func readsOnMain() -> Int { lock.lock(); defer { lock.unlock() }; return mainThreadReads }
    func key(for endpoint: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }; if Thread.isMainThread { mainThreadReads += 1 }
        if failRead { throw ImageAgentError.credential("fake credential read failure") }; return values[endpoint]
    }
    func save(_ key: String, for endpoint: String) throws {
        lock.lock(); defer { lock.unlock() }; if failSave { throw ImageAgentError.credential("fake credential save failure") }; values[endpoint] = key
    }
    func delete(for endpoint: String) throws { lock.lock(); defer { lock.unlock() }; values[endpoint] = nil }
}
actor SettingsTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var status = 200
    var paused = false
    func configure(status: Int = 200, paused: Bool = false) { self.status = status; self.paused = paused }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        while paused { try await Task.sleep(for: .milliseconds(1)) }
        if status == -1 { throw URLError(.notConnectedToInternet) }
        return .init(data: Data((status == 200 ? #"{"data":[{"id":"gpt-image-2"}]}"# : #"{"error":{"message":"offline unauthorized"}}"#).utf8), statusCode: status)
    }
}
@MainActor @Suite struct APISettingsTests {
    private func fixture() async throws -> (AppModel, SQLiteStore, FakeCredentials, SettingsTransport, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ImageAgentSettings-\(UUID())")
        let store = try SQLiteStore(paths: .init(root: root)); _ = try store.createConversation()
        let settings = AppSettings(endpoint: "https://old.invalid/v1", selection: .init(model: .sunburst, size: .auto, quality: .high))
        try store.saveSettings(settings)
        let credentials = FakeCredentials([settings.endpoint: "old-dummy"]), transport = SettingsTransport()
        let model = AppModel(store: store, credentials: credentials, transport: transport)
        await model.start(); #expect(model.hasConnection)
        return (model, store, credentials, transport, root)
    }
    private func wait(_ model: AppModel) async throws {
        for _ in 0..<2000 { if !model.isConnecting { return }; try await Task.sleep(for: .milliseconds(1)) }
        Issue.record("Settings save did not finish")
    }
    private func sql(_ text: String, store: SQLiteStore) throws {
        var handle: OpaquePointer?; #expect(sqlite3_open(store.paths.database.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, text, nil, nil, nil) == SQLITE_OK else { throw ImageAgentError.storage("Test setup SQL failed") }
    }
    @Test func replacementKeyAndNormalizedBlankKeySaveAndRestartWithoutLosingSelection() async throws {
        let (model, store, credentials, transport, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        model.endpointText = " https://OLD.invalid/ "; model.keyText = "replacement-dummy"; model.connect(); try await wait(model)
        #expect(model.hasConnection && model.keyText.isEmpty && model.settings.endpoint == "https://old.invalid/v1")
        #expect(try credentials.key(for: model.settings.endpoint) == "replacement-dummy")
        model.endpointText = "https://old.invalid/v1/"; model.keyText = " \n "; model.connect(); try await wait(model)
        #expect(model.error == nil)
        #expect(await transport.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer replacement-dummy")
        let reopened = AppModel(store: try SQLiteStore(paths: .init(root: root)), credentials: credentials, transport: transport)
        await reopened.start()
        #expect(reopened.hasConnection && reopened.settings.selection == .init(model: .sunburst, size: .auto, quality: .high))
        #expect(try store.settings() == reopened.settings)
    }
    @Test func differentEndpointNeverReceivesOldServiceKey() async throws {
        let (model, _, _, transport, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = model.settings
        model.endpointText = "https://new.invalid"; model.keyText = ""; model.connect(); try await wait(model)
        #expect(model.hasConnection && model.settings == original && model.error != nil)
        #expect(await transport.requests.isEmpty)
        model.keyText = "new-dummy"; model.connect(); try await wait(model)
        #expect(model.hasConnection && model.settings.endpoint == "https://new.invalid/v1")
        #expect(await transport.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer new-dummy")
    }
    @Test func invalidURLAuthNetworkAndCredentialFailuresKeepPreviousConnectionAndSettings() async throws {
        let (model, store, credentials, transport, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = model.settings
        model.endpointText = "http://unsafe.invalid"; model.keyText = "candidate-dummy"; model.connect(); try await wait(model)
        #expect(model.error != nil && model.hasConnection && model.settings == original)
        #expect(await transport.requests.isEmpty)
        for status in [401, -1] {
            await transport.configure(status: status); model.endpointText = "https://new.invalid"; model.connect(); try await wait(model)
            #expect(model.error != nil && model.hasConnection && model.settings == original)
            #expect(try store.settings() == original)
            #expect(try credentials.key(for: "https://new.invalid/v1") == nil)
        }
        await transport.configure(); credentials.failures(save: true); model.connect(); try await wait(model)
        #expect(model.error != nil && model.hasConnection && model.settings == original)
        credentials.failures(read: true); model.keyText = ""; model.connect(); try await wait(model)
        #expect(model.error != nil && model.hasConnection && model.settings == original)
    }
    @Test func databaseFailureRollsBackCandidateCredentialAndNeverPublishesCandidateEndpoint() async throws {
        let (model, store, credentials, _, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try sql("CREATE TRIGGER reject_settings BEFORE INSERT ON settings BEGIN SELECT RAISE(FAIL,'offline storage failure'); END", store: store)
        let original = model.settings
        model.endpointText = "https://new.invalid"; model.keyText = "new-dummy"; model.connect(); try await wait(model)
        #expect(model.hasConnection && model.error != nil && model.settings == original)
        #expect(try store.settings() == original)
        #expect(try credentials.key(for: "https://new.invalid/v1") == nil)
        model.endpointText = original.endpoint; model.keyText = "replacement-dummy"; model.connect(); try await wait(model)
        #expect(try credentials.key(for: original.endpoint) == "old-dummy")
    }
    @Test func latestUnrelatedSettingsSurviveValidationAndBusySaveIsRejected() async throws {
        let (model, store, _, transport, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await transport.configure(paused: true)
        model.endpointText = "https://new.invalid"; model.keyText = "new-dummy"; model.connect()
        for _ in 0..<100 { if await !transport.requests.isEmpty { break }; try await Task.sleep(for: .milliseconds(1)) }
        #expect(model.hasConnection && model.settings.endpoint == "https://old.invalid/v1")
        model.draft = "验证期间不能发送"; model.send(); #expect(!model.isBusy && !model.canSend)
        let asset = try store.saveImage(frontendPNG(), conversationID: model.selectedID!, source: .imported)
        var region = RegionSelection(width: 4, height: 3); region.addRectangle(from: .init(x: 0, y: 0), to: .init(x: 2, y: 2))
        var rejected = false
        #expect(!model.submitRegionEdit(conversationID: model.selectedID!, assetID: asset.id, selection: region, instruction: "验证期间不能编辑") { if case .failure = $0 { rejected = true } })
        #expect(rejected && !model.isBusy)
        #expect(try store.messages(in: model.selectedID!).isEmpty)
        model.settings.memory.hours = 72; model.settings.selection.model = .flare
        await transport.configure(); try await wait(model)
        #expect(model.settings.memory.hours == 72 && model.settings.selection.model == .flare)
        #expect(try store.settings() == model.settings)
        model.isBusy = true; model.endpointText = "https://blocked.invalid"; model.keyText = "blocked-dummy"; model.connect(); try await wait(model)
        #expect(model.settings.endpoint == "https://new.invalid/v1")
        #expect(await transport.requests.count == 1)
    }
    @Test func startupCredentialReadRunsOffMainThreadAndNeverValidatesOverNetwork() async throws {
        let (model, _, credentials, transport, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(model.hasConnection && credentials.readsOnMain() == 0)
        #expect(await transport.requests.isEmpty)
    }
}
