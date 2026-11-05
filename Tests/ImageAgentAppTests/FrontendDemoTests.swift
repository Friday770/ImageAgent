import Foundation
import Testing
import ImageAgentCore
@testable import ImageAgent

private struct ForbiddenDemoCredentials: CredentialStore {
    func key(for endpoint: String) throws -> String? { Issue.record("Demo reached injected credential store"); throw ImageAgentError.credential("forbidden") }
    func save(_ key: String, for endpoint: String) throws { Issue.record("Demo reached injected credential store"); throw ImageAgentError.credential("forbidden") }
    func delete(for endpoint: String) throws { Issue.record("Demo reached injected credential store"); throw ImageAgentError.credential("forbidden") }
}
@MainActor @Suite struct FrontendDemoTests {
    private func wait(_ model: AppModel) async throws {
        for _ in 0..<2000 { if !model.isBusy && !model.isConnecting { return }; try await Task.sleep(for: .milliseconds(1)) }
        Issue.record("Offline frontend operation did not finish")
    }
    @Test func dedicatedBundleSessionSelectsFullyIsolatedDemoAndSurvivesConnectionSaveRestart() async throws {
        let session = "qa-test-\(UUID().uuidString)"
        let transport = SettingsTransport()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ImageAgentFrontendDemo-\(session)")
        let isolatedStore = try SQLiteStore(paths: .init(root: root))
        let model = AppModel(store: isolatedStore, arguments: ["ImageAgent"], credentials: ForbiddenDemoCredentials(), transport: transport, bundledDemoSession: session)
        #expect(model.isFrontendDemo && model.isDemo)
        #expect(model.dataPath.hasSuffix("ImageAgentFrontendDemo-\(session)"))
        // Never remove a production path if mode selection regresses.
        defer { if model.dataPath.contains("ImageAgentFrontendDemo-") { try? FileManager.default.removeItem(atPath: model.dataPath) } }
        await model.start(); #expect(model.hasConnection)
        model.draft = "离线测试任务"; #expect(model.canSend)
        let count = model.messages.count; model.send()
        for _ in 0..<100 { if model.activeRun != nil { break }; try await Task.sleep(for: .milliseconds(1)) }
        model.cancel(); try await wait(model)
        let user = try #require(model.messages.last { $0.role == .user })
        #expect(model.messages.count == count + 2 && model.canReturnToEdit(user))
        #expect(model.returnToEdit(user) && model.draft == "离线测试任务")
        #expect(await model.saveConnection(address: "https://offline.invalid", key: "test-only-never-persist-this-value"))
        let savedCount = model.messages.count
        let reopened = AppModel(store: try SQLiteStore(paths: .init(root: root)), arguments: ["ImageAgent"], credentials: ForbiddenDemoCredentials(), transport: transport, bundledDemoSession: session)
        await reopened.start()
        #expect(reopened.hasConnection && reopened.settings.endpoint == "https://offline.invalid/v1" && reopened.messages.count == savedCount)
        let files = FileManager.default.enumerator(at: URL(fileURLWithPath: model.dataPath), includingPropertiesForKeys: [.isRegularFileKey])!
        for url in files.allObjects.compactMap({ $0 as? URL }) where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            #expect(!(try Data(contentsOf: url)).contains(Data("test-only-never-persist-this-value".utf8)))
        }
        #expect(await !reopened.saveConnection(address: "https://offline.invalid", key: "fail"))
        #expect(reopened.hasConnection && reopened.settings.endpoint == "https://offline.invalid/v1")
        #expect(await transport.requests.isEmpty)
    }
    @Test func demoFlagsRemainExplicitAndInvalidSessionFailsClosed() async throws {
        let session = "flag-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ImageAgentFrontendDemo-\(session)")
        let isolatedStore = try SQLiteStore(paths: .init(root: root))
        let model = AppModel(store: isolatedStore, arguments: ["ImageAgent", "--frontend-demo", "--frontend-demo-session", session], credentials: ForbiddenDemoCredentials(), transport: SettingsTransport(), bundledDemoSession: nil)
        #expect(model.isFrontendDemo && model.dataPath.hasSuffix("ImageAgentFrontendDemo-\(session)"))
        defer { if model.dataPath.contains("ImageAgentFrontendDemo-") { try? FileManager.default.removeItem(atPath: model.dataPath) } }
        let invalid = AppModel(store: isolatedStore, arguments: ["ImageAgent"], credentials: ForbiddenDemoCredentials(), transport: SettingsTransport(), bundledDemoSession: "../escape")
        #expect(invalid.startupError != nil && invalid.store == nil)
    }
}

extension FrontendDemoTests {
    @Test func offlineModelListContainsTextPlannerSuggestionsAndAllImageModels() async throws {
        let client = try APIClient(baseURL: "https://offline.invalid", apiKey: "fake-demo-key", transport: FrontendDemoTransport())
        let ids = try await client.validateConnection()
        #expect(ids.contains(PlannerModel.default) && ids.contains("gpt-6-sol"))
        #expect(ImageModel.allCases.allSatisfy { ids.contains($0.rawValue) })
    }
}
