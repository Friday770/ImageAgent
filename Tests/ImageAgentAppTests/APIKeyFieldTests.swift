import Foundation
import Testing
import ImageAgentCore
@testable import ImageAgent

private final class DelayedSettingsCredential: CredentialStore, @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var began = false
    var isReading: Bool { lock.lock(); defer { lock.unlock() }; return began }
    func key(for endpoint: String) throws -> String? {
        lock.lock(); began = true; lock.unlock()
        guard release.wait(timeout: .now() + 5) == .success else { throw ImageAgentError.credential("Test credential read timed out") }
        return "old-test-key"
    }
    func save(_ key: String, for endpoint: String) throws {}
    func delete(for endpoint: String) throws {}
}

@MainActor @Suite struct APIKeyFieldTests {
    private func fixture(credentials: any CredentialStore) throws -> (AppModel, SQLiteStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ImageAgentKeyField-\(UUID())")
        let store = try SQLiteStore(paths: .init(root: root))
        try store.saveSettings(.init(endpoint: "https://old.invalid/v1"))
        return (AppModel(store: store, credentials: credentials, transport: SettingsTransport()), store, root)
    }
    @Test func savedKeyLoadsMaskedWithoutChangingConnectionOrPersistingPlaintext() async throws {
        let credentials = FakeCredentials(["https://old.invalid/v1": "saved-test-key"])
        let (app, store, root) = try fixture(credentials: credentials)
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try store.settings()
        let field = APIKeyFieldModel(address: before.endpoint)
        await field.loadSavedKey(from: app)
        #expect(field.key == "saved-test-key" && !field.revealed)
        field.revealed = true; #expect(field.key == "saved-test-key")
        field.revealed = false; #expect(field.key == "saved-test-key")
        #expect(credentials.readsOnMain() == 0)
        #expect(try store.settings() == before && app.keyText.isEmpty && !app.isConnecting)
        #expect(!(try Data(contentsOf: store.paths.database)).contains(Data("saved-test-key".utf8)))
    }
    @Test func switchingAddressClearsAndHidesOldKeyAndCannotLoadItForAnotherService() async throws {
        let credentials = FakeCredentials(["https://old.invalid/v1": "old-test-key", "https://new.invalid/v1": "other-test-key"])
        let (app, _, root) = try fixture(credentials: credentials)
        defer { try? FileManager.default.removeItem(at: root) }
        let field = APIKeyFieldModel(address: app.settings.endpoint)
        await field.loadSavedKey(from: app); field.revealed = true
        field.address = "https://new.invalid/v1"
        #expect(field.key.isEmpty && !field.revealed)
        await field.loadSavedKey(from: app)
        #expect(field.key.isEmpty && app.settings.endpoint == "https://old.invalid/v1")
    }
    @Test(arguments: ["edit", "switch", "dismiss"])
    func delayedReadNeverOverwritesNewInputOrRestoresAClosedField(_ action: String) async throws {
        let credentials = DelayedSettingsCredential()
        let (app, _, root) = try fixture(credentials: credentials)
        defer { credentials.release.signal(); try? FileManager.default.removeItem(at: root) }
        let field = APIKeyFieldModel(address: app.settings.endpoint)
        let read = Task { await field.loadSavedKey(from: app) }
        for _ in 0..<1000 { if credentials.isReading { break }; try await Task.sleep(for: .milliseconds(1)) }
        #expect(credentials.isReading)
        if action == "edit" { field.key = "newly-typed-test-key" }
        else if action == "switch" { field.address = "https://new.invalid/v1" }
        else { field.revealed = true; field.clear() }
        credentials.release.signal(); await read.value
        #expect(field.key == (action == "edit" ? "newly-typed-test-key" : ""))
        #expect(!field.revealed)
    }
    @Test func sameEndpointSaveAndReopenKeepARealMaskedValueInsteadOfABlankField() async throws {
        let credentials = FakeCredentials(["https://old.invalid/v1": "old-test-key"])
        let (app, _, root) = try fixture(credentials: credentials)
        defer { try? FileManager.default.removeItem(at: root) }
        let field = APIKeyFieldModel(address: app.settings.endpoint)
        await field.loadSavedKey(from: app)
        field.key = "replacement-test-key"; field.revealed = true
        #expect(await app.saveConnection(address: field.address, key: field.key))
        await field.loadSavedKey(from: app)
        #expect(field.key == "replacement-test-key" && !field.revealed)
        field.clear(); #expect(field.key.isEmpty && !field.revealed)
        let reopened = APIKeyFieldModel(address: app.settings.endpoint)
        await reopened.loadSavedKey(from: app)
        #expect(reopened.key == "replacement-test-key" && !reopened.revealed)
    }
}
