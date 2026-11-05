import Foundation
import Testing
import CSQLite
import ImageAgentCore
@testable import ImageAgent

actor PlannerSettingsTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var modelIDs = ["gpt-6.1-sol", "alternate-planner", "alternate-planner", "gpt-image-2", "gpt-image-2.5", "gpt-image-2.5-flare", "gpt-image-2.5-sunburst"]
    var status = 200
    var pauseLists = false
    private var pending: [CheckedContinuation<HTTPResponse, Never>] = []
    func configure(ids: [String]? = nil, status: Int = 200, pause: Bool = false) {
        if let ids { modelIDs = ids }; self.status = status; pauseLists = pause
    }
    func complete(_ index: Int = 0, ids: [String]) throws {
        let response = try models(ids)
        pending.remove(at: index).resume(returning: response)
    }
    private func models(_ ids: [String]) throws -> HTTPResponse {
        .init(data: try JSONEncoder().encode(JSONValue.object(["data": .array(ids.map { .object(["id": .string($0)]) })])), statusCode: 200)
    }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        if request.url?.path.hasSuffix("/models") == true {
            if pauseLists { return await withCheckedContinuation { pending.append($0) } }
            if status != 200 { return .init(data: Data(#"{"error":{"message":"list failed fake-private-key Bearer fake-private-key"}}"#.utf8), statusCode: status) }
            return try models(modelIDs)
        }
        if request.url?.path.hasSuffix("/responses") == true {
            let json = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)
            let properties = json["tools"]!.array!.first!["parameters"]!["properties"]!
            let system = json["input"]!.array!.first!["content"]!.string!
            let reference = system.components(separatedBy: "主动选定的参考图：").last!.components(separatedBy: "。").first!
            let referenceID: String? = reference.hasPrefix("无") ? nil : reference
            let arguments: JSONValue = .object(["action": .string(referenceID == nil ? "generate" : "edit"), "prompt": .string("A quiet mountain lake"),
                "model": properties["model"]!["enum"]!.array!.first!, "size": properties["size"]!["enum"]!.array!.first!, "quality": properties["quality"]!["enum"]!.array!.first!,
                "reference_image_id": referenceID.map(JSONValue.string) ?? .null, "reply_text": .string("Saved locally")])
            return .init(data: try JSONEncoder().encode(JSONValue.object(["status": .string("completed"), "output": .array([.object(["type": .string("function_call"), "name": .string("prepare_image_request"), "call_id": .string("test-call"), "arguments": .string(try arguments.encodedString())])])])), statusCode: 200)
        }
        guard request.url?.path.contains("/images/") == true else { throw ImageAgentError.invalidInput("Unexpected fixture route") }
        return .init(data: try JSONEncoder().encode(JSONValue.object(["data": .array([.object(["b64_json": .string(frontendPNG().base64EncodedString())])])])), statusCode: 200)
    }
}

@MainActor @Suite struct PlannerSettingsTests {
    func fixture(planner: String = "saved/custom-planner") async throws -> (AppModel, SQLiteStore, FakeCredentials, PlannerSettingsTransport, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ImageAgentPlannerSettings-\(UUID())")
        let store = try SQLiteStore(paths: .init(root: root)); _ = try store.createConversation()
        try store.saveSettings(.init(endpoint: "https://old.invalid/v1", plannerModel: planner, selection: .init(model: .sunburst, size: .landscape, quality: .high)))
        let credentials = FakeCredentials(["https://old.invalid/v1": "fake-private-key", "https://other.invalid/v1": "other-fake-key"])
        let transport = PlannerSettingsTransport()
        let app = AppModel(store: store, arguments: ["ImageAgent"], credentials: credentials, transport: transport, bundledDemoSession: nil)
        await app.start()
        return (app, store, credentials, transport, root)
    }
    func waitForIdle(_ app: AppModel) async throws {
        for _ in 0..<3000 { if !app.isBusy && !app.isConnecting { return }; try await Task.sleep(for: .milliseconds(1)) }
        Issue.record("Planner fixture did not finish")
    }
    func waitForRequests(_ count: Int, transport: PlannerSettingsTransport) async throws {
        for _ in 0..<2000 { if await transport.requests.count >= count { return }; try await Task.sleep(for: .milliseconds(1)) }
        Issue.record("Expected fixture request did not arrive")
    }
    @Test func savedPlannerIsUsedForNormalAndRegionalRequestsAfterStartup() async throws {
        let (app, store, _, transport, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        app.draft = "A quiet lake"; app.send(); try await waitForIdle(app)
        #expect(app.runs.first?.stage == .completed)
        let conversation = try #require(app.selectedID), asset = try #require(app.assets.first)
        var selection = RegionSelection(width: asset.width, height: asset.height)
        selection.addRectangle(from: .init(x: 0, y: 0), to: .init(x: 2, y: 2))
        var regionalCompleted = false
        #expect(app.submitRegionEdit(conversationID: conversation, assetID: asset.id, selection: selection, instruction: "Change only the selected region") { result in
            if case .success(let outcome) = result { regionalCompleted = outcome.run.stage == .completed }
        })
        try await waitForIdle(app); #expect(regionalCompleted)
        let requests = await transport.requests
        let plans = try requests.filter { $0.url?.path.hasSuffix("/responses") == true }.map { try JSONDecoder().decode(JSONValue.self, from: $0.httpBody!) }
        #expect(plans.count == 2)
        #expect(plans.allSatisfy { $0["model"]?.string == "saved/custom-planner" && $0["reasoning"] == nil })
        let generation = try #require(requests.first { $0.url?.path.hasSuffix("/images/generations") == true })
        #expect(try JSONDecoder().decode(JSONValue.self, from: generation.httpBody!)["model"]?.string == ImageModel.sunburst.rawValue)
        let edit = try #require(requests.first { $0.url?.path.hasSuffix("/images/edits") == true })
        #expect(String(decoding: edit.httpBody!, as: UTF8.self).contains(ImageModel.sunburst.rawValue))
        #expect(try store.settings().selection.size == .landscape)
    }
}

extension PlannerSettingsTests {
    @Test func plannerSaveAndRestartRetainExactIDAndAllUnrelatedSettings() async throws {
        let (app, store, credentials, transport, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let oldSelection = app.settings.selection
        app.settings.memory.hours = 72
        #expect(await app.saveConnection(address: " https://OLD.invalid/ ", key: "", plannerModel: "  listed-or-manual/Planner:2026  "))
        #expect(app.settings.plannerModel == "listed-or-manual/Planner:2026")
        #expect(app.settings.selection == oldSelection && app.settings.memory.hours == 72)
        let reopened = AppModel(store: try SQLiteStore(paths: .init(root: root)), arguments: ["ImageAgent"], credentials: credentials, transport: transport, bundledDemoSession: nil)
        await reopened.start()
        #expect(try reopened.hasConnection && reopened.settings == app.settings && store.settings() == app.settings)
        reopened.draft = "after restarting"; reopened.send(); try await waitForIdle(reopened)
        let request = try #require(await transport.requests.first { $0.url?.path.hasSuffix("/responses") == true })
        #expect(try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)["model"]?.string == "listed-or-manual/Planner:2026")
        #expect(try !Data(contentsOf: store.paths.database).contains(Data("fake-private-key".utf8)))
    }
    @Test func invalidPlannerIsRejectedBeforeRequestsOrCredentialChanges() async throws {
        let (app, store, credentials, transport, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let before = app.settings
        for planner in ["", "   ", "bad\nmodel", "bad\u{0}model", String(repeating: "x", count: 201)] + ImageModel.allCases.map(\.rawValue) + ["fake-private-key"] {
            #expect(await !app.saveConnection(address: before.endpoint, key: "replacement-fake-key", plannerModel: planner))
            #expect(app.settings == before && app.hasConnection && app.connectionError != nil)
            #expect(try store.settings() == before)
            #expect(try credentials.key(for: before.endpoint) == "fake-private-key")
            #expect(app.connectionError?.contains("fake-private-key") != true)
        }
        #expect(await transport.requests.isEmpty)
    }
    @Test func validationCredentialDatabaseAndCancellationFailuresPreserveTheUsablePlanner() async throws {
        let (app, store, credentials, transport, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let before = app.settings
        await transport.configure(status: 401)
        #expect(await !app.saveConnection(address: before.endpoint, key: "replacement-fake-key", plannerModel: "replacement-planner"))
        #expect(try app.settings == before && app.hasConnection && store.settings() == before)
        await transport.configure(); credentials.failures(save: true)
        #expect(await !app.saveConnection(address: before.endpoint, key: "replacement-fake-key", plannerModel: "replacement-planner"))
        #expect(app.settings == before && app.hasConnection)
        credentials.failures()
        var handle: OpaquePointer?; #expect(sqlite3_open(store.paths.database.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, "CREATE TRIGGER reject_planner BEFORE INSERT ON settings BEGIN SELECT RAISE(FAIL,'fake SQLite failure'); END", nil, nil, nil) == SQLITE_OK)
        #expect(await !app.saveConnection(address: before.endpoint, key: "replacement-fake-key", plannerModel: "replacement-planner"))
        #expect(try credentials.key(for: before.endpoint) == "fake-private-key")
        #expect(try app.settings == before && store.settings() == before && app.hasConnection)
        #expect(sqlite3_exec(handle, "DROP TRIGGER reject_planner", nil, nil, nil) == SQLITE_OK)
        await transport.configure(pause: true)
        let count = await transport.requests.count
        let save = Task { await app.saveConnection(address: before.endpoint, key: "replacement-fake-key", plannerModel: "cancelled-planner") }
        try await waitForRequests(count + 1, transport: transport)
        save.cancel(); try await transport.complete(ids: ["cancelled-planner"])
        #expect(await !save.value)
        #expect(try app.settings == before && store.settings() == before && app.hasConnection)
        #expect(try credentials.key(for: before.endpoint) == "fake-private-key")
        await transport.configure()
        app.draft = "old planner still runs"; app.send(); try await waitForIdle(app)
        let request = try #require(await transport.requests.last { $0.url?.path.hasSuffix("/responses") == true })
        #expect(try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)["model"]?.string == before.plannerModel)
    }
    @Test func saveKeepsLatestMemoryAndSelectionAndRejectsBusyPlannerChanges() async throws {
        let (app, store, _, transport, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await transport.configure(pause: true)
        let save = Task { await app.saveConnection(address: app.settings.endpoint, key: "", plannerModel: "candidate-planner") }
        try await waitForRequests(1, transport: transport)
        #expect(app.settings.plannerModel == "saved/custom-planner")
        #expect(await !app.saveConnection(address: app.settings.endpoint, key: "", plannerModel: "racing-planner"))
        app.settings.memory.turns = 33; app.settings.selection.model = .flare
        try await transport.complete(ids: []); #expect(await save.value)
        #expect(app.settings.plannerModel == "candidate-planner" && app.settings.memory.turns == 33 && app.settings.selection.model == .flare)
        #expect(try store.settings() == app.settings)
        app.isBusy = true
        #expect(await !app.saveConnection(address: app.settings.endpoint, key: "", plannerModel: "busy-planner"))
        #expect(app.settings.plannerModel == "candidate-planner")
        #expect(await transport.requests.count == 1)
    }
}

extension PlannerSettingsTests {
    @Test func discoveryUsesOnlyTheExplicitEndpointCredentialAndNeverMutatesSavedSettings() async throws {
        let (app, store, credentials, transport, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let before = app.settings
        #expect(try await app.plannerModels(address: " https://OLD.invalid/ ", key: "").contains("alternate-planner"))
        _ = try await app.plannerModels(address: "https://other.invalid", key: "")
        _ = try await app.plannerModels(address: "https://new.invalid", key: "entered-fake-key")
        let requests = await transport.requests
        #expect(requests.count == 3)
        #expect(requests.map { $0.url?.host } == ["old.invalid", "other.invalid", "new.invalid"])
        #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer fake-private-key", "Bearer other-fake-key", "Bearer entered-fake-key"])
        #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.path == "/v1/models" })
        #expect(try app.settings == before && store.settings() == before && app.hasConnection)
        #expect(!app.isConnecting && app.keyText.isEmpty && credentials.readsOnMain() == 0)
        #expect(try credentials.key(for: "https://new.invalid/v1") == nil)
        await #expect(throws: (any Error).self) { try await app.plannerModels(address: "https://unconfigured.invalid", key: "") }
        #expect(await transport.requests.count == 3)
    }
    @Test func discoveryFailureIsRedactedAndManualSaveRemainsUsable() async throws {
        let (app, _, _, transport, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await transport.configure(status: 401)
        do { _ = try await app.plannerModels(address: app.settings.endpoint, key: "fake-private-key"); Issue.record("Expected list error") }
        catch { #expect(!error.localizedDescription.contains("fake-private-key") && error.localizedDescription.contains("401")) }
        #expect(app.hasConnection && app.settings.plannerModel == "saved/custom-planner")
        await transport.configure(ids: [])
        #expect(await app.saveConnection(address: app.settings.endpoint, key: "", plannerModel: "manual-unlisted-planner"))
        #expect(app.settings.plannerModel == "manual-unlisted-planner")
    }
    @Test func discoveryIsBlockedDuringJobsAndSavesAndInNonFrontendDemoModes() async throws {
        let (app, store, credentials, transport, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        app.isBusy = true
        await #expect(throws: (any Error).self) { try await app.plannerModels(address: app.settings.endpoint, key: "fake-private-key") }
        app.isBusy = false; app.isConnecting = true
        await #expect(throws: (any Error).self) { try await app.plannerModels(address: app.settings.endpoint, key: "fake-private-key") }
        for flag in ["--demo", "--streaming-demo", "--connection-demo"] {
            let demo = AppModel(store: store, arguments: ["ImageAgent", flag], credentials: credentials, transport: transport, bundledDemoSession: nil)
            await #expect(throws: (any Error).self) { try await demo.plannerModels(address: app.settings.endpoint, key: "fake-private-key") }
        }
        #expect(await transport.requests.isEmpty)
    }
}
