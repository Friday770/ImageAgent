import Foundation
import Testing
import ImageAgentCore
@testable import ImageAgent

@MainActor @Suite struct PlannerModelFieldTests {
    private func fixture() async throws -> (AppModel, PlannerModelFieldModel, PlannerSettingsTransport, URL) {
        let (app, _, _, transport, root) = try await PlannerSettingsTests().fixture()
        return (app, PlannerModelFieldModel(value: app.settings.plannerModel, address: app.settings.endpoint, key: "fake-private-key"), transport, root)
    }
    private func waitForRequests(_ count: Int, _ transport: PlannerSettingsTransport) async throws {
        try await PlannerSettingsTests().waitForRequests(count, transport: transport)
    }
    @Test func listedAndManualChoicesRemainIndependentOfAsyncSuggestions() async throws {
        let (app, field, transport, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await field.refresh(from: app)
        #expect(field.options == ["saved/custom-planner", "gpt-6.1-sol", "alternate-planner"])
        #expect(field.value == "saved/custom-planner" && field.error == nil && !field.isLoading)
        field.value = "alternate-planner"
        #expect(field.options.filter { $0 == "alternate-planner" }.count == 1)
        field.value = "unlisted/manual-model"
        await transport.configure(ids: [])
        await field.refresh(from: app)
        #expect(field.value == "unlisted/manual-model")
        #expect(field.options.contains("saved/custom-planner") && field.options.contains("unlisted/manual-model") && field.options.contains(PlannerModel.default))
        #expect(!field.options.contains(where: { ImageModel(rawValue: $0) != nil }))
        #expect(app.settings.plannerModel == "saved/custom-planner")
    }
    @Test func failedOrEmptyListsKeepManualEntryAndErrorsAreSecretFree() async throws {
        let (app, field, transport, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        field.value = "manual-model"
        await transport.configure(status: 401)
        await field.refresh(from: app)
        #expect(field.value == "manual-model" && field.options.contains("manual-model"))
        #expect(field.error?.contains("401") == true && field.error?.contains("fake-private-key") != true && !field.isLoading)
        await transport.configure(ids: ["fake-private-key", "sk-private-value", "bad\nmodel", "valid/custom", "valid/custom", "gpt-image-2"])
        await field.refresh(from: app)
        #expect(field.error == nil && field.options.contains("valid/custom"))
        #expect(field.options.filter { $0 == "valid/custom" }.count == 1)
        #expect(!field.options.contains("fake-private-key") && !field.options.contains("gpt-image-2"))
        #expect(await app.saveConnection(address: app.settings.endpoint, key: "", plannerModel: field.value))
        #expect(app.settings.plannerModel == "manual-model")
    }
    @Test(arguments: ["address", "key", "close", "cancel"])
    func obsoleteResultsCannotRepopulateAnotherSourceOrClosedOrCancelledDraft(_ change: String) async throws {
        let (app, field, transport, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await field.refresh(from: app); #expect(field.options.contains("alternate-planner"))
        await transport.configure(pause: true)
        let request = Task { await field.refresh(from: app) }
        try await waitForRequests(2, transport)
        field.value = "manual-before-completion"
        if change == "address" { field.sourceChanged(address: "https://other.invalid/v1", key: "") }
        if change == "key" { field.sourceChanged(address: app.settings.endpoint, key: "changed-fake-key") }
        if change == "close" { field.close() }
        if change == "cancel" { field.reset(value: app.settings.plannerModel, address: app.settings.endpoint, key: "fake-private-key") }
        #expect(!field.options.contains("alternate-planner") && !field.isLoading)
        try await transport.complete(ids: ["obsolete-model"]); await request.value
        #expect(!field.options.contains("obsolete-model") && field.error == nil && !field.isLoading)
        #expect(field.value == (change == "cancel" ? "saved/custom-planner" : "manual-before-completion"))
        #expect(app.settings.plannerModel == "saved/custom-planner")
    }
    @Test func newRefreshWinsEvenIfThePreviousRequestCompletesLast() async throws {
        let (app, field, transport, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await transport.configure(pause: true)
        let first = Task { await field.refresh(from: app) }
        try await waitForRequests(1, transport)
        let second = Task { await field.refresh(from: app) }
        try await waitForRequests(2, transport)
        field.value = "newer/manual-choice"
        try await transport.complete(1, ids: ["newer-list"]); await second.value
        try await transport.complete(0, ids: ["older-list"]); await first.value
        #expect(field.value == "newer/manual-choice" && field.options.contains("newer-list") && !field.options.contains("older-list"))
    }
    @Test func switchingKeySourceClearsOldOptionsBeforeTheNextFetch() async throws {
        let (app, field, transport, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await field.refresh(from: app)
        field.sourceChanged(address: "https://new.invalid", key: "")
        #expect(!field.options.contains("alternate-planner"))
        await field.refresh(from: app)
        #expect(field.error != nil && field.value == "saved/custom-planner")
        #expect(await transport.requests.count == 1)
        field.sourceChanged(address: "https://other.invalid", key: "")
        await field.refresh(from: app)
        #expect(await transport.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer other-fake-key")
    }
}

extension PlannerModelFieldTests {
    @Test func apiKeyDraftInvalidatesDiscoveryImmediatelyOnAddressOrKeyEdits() async throws {
        let (app, field, transport, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let key = APIKeyFieldModel(address: app.settings.endpoint)
        key.key = "fake-private-key"
        key.onSourceChange = { address, value in field.sourceChanged(address: address, key: value) }
        await field.refresh(from: app); #expect(field.options.contains("alternate-planner"))
        key.key = "edited-fake-key"
        #expect(!field.options.contains("alternate-planner"))
        await field.refresh(from: app); #expect(field.options.contains("alternate-planner"))
        key.revealed = true; key.address = "https://new.invalid/v1"
        #expect(key.key.isEmpty && !key.revealed && !field.options.contains("alternate-planner"))
        await field.refresh(from: app)
        #expect(field.error != nil)
        #expect(await transport.requests.count == 2)
    }
}
