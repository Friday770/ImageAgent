import Foundation
import Testing
@testable import ImageAgentCore

@Suite struct PlannerModelTests {
    @Test func legacySettingsDecodeWithTheOriginalPlannerAndKeepImageAndMemoryChoices() throws {
        let legacy = Data(#"{"endpoint":"https://old.invalid/v1","selection":{"model":"gpt-image-2.5-sunburst","size":"auto","quality":"high"},"memory":{"hours":72,"turns":18,"maxCharacters":12345}}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: legacy)
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(settings))
        #expect(encoded["plannerModel"]?.string == "gpt-6.1-sol")
        #expect(settings.selection.model == .sunburst && settings.memory.hours == 72)
    }
    @Test func exactCustomPlannerSurvivesSettingsRoundtrip() throws {
        let raw = Data(#"{"endpoint":"https://old.invalid/v1","plannerModel":"custom/Planner:2026","selection":{"model":"gpt-image-2","size":"1024x1024","quality":"auto"},"memory":{"hours":24,"turns":12,"maxCharacters":24000}}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: raw)
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(settings))
        #expect(encoded["plannerModel"]?.string == "custom/Planner:2026")
    }
    @Test func modelDiscoveryOmitsMalformedAndCredentialContainingIDsWithoutRewritingIDs() async throws {
        let ids: [JSONValue] = ["custom/Planner:2026", "dummy-key-private", "prefix-dummy-key-private", "sk-hidden-secret", "Bearer anything", " spaced ", "bad\nmodel", "", String(repeating: "a", count: 201), "gpt-image-2"].map { .object(["id": .string($0)]) }
        let transport = RecordingTransport([.init(data: try JSONEncoder().encode(JSONValue.object(["data": .array(ids)])), statusCode: 200)])
        let client = try APIClient(baseURL: "https://models.invalid", apiKey: "dummy-key-private", transport: transport)
        #expect(try await client.validateConnection() == ["custom/Planner:2026", "gpt-image-2"])
        #expect(await transport.requests.count == 1)
        #expect(await transport.requests.first?.httpMethod == "GET")
    }
}

@Suite struct SelectedPlannerRequestTests {
    @Test func selectedPlannerUsesExactIDAndLeavesImageToolsAndRequestsIndependent() async throws {
        let transport = RecordingTransport([httpJSON(#"{"status":"completed","output":[]}"#), imageReply()])
        let client = try APIClient(baseURL: "https://models.invalid", apiKey: "fake-key", plannerModel: "custom/Planner:2026", transport: transport)
        let selection = ImageSelection(model: .sunburst, size: .portrait, quality: .high)
        _ = try await client.respond(input: [], selection: selection)
        _ = try await client.generate(prompt: "quiet lake", selection: selection)
        let requests = await transport.requests
        let body = try requestJSON(#require(requests.first))
        #expect(body["model"]?.string == "custom/Planner:2026")
        #expect(body["reasoning"] == nil)
        #expect(body["store"] == .bool(false) && body["stream"] == .bool(true))
        #expect(body["parallel_tool_calls"] == .bool(false))
        #expect(body["tools"]?.array?.first?["strict"] == .bool(true))
        #expect(body["tool_choice"]?["name"]?.string == "prepare_image_request")
        #expect(body["tools"]?.array?.first?["parameters"]?["properties"]?["model"]?["enum"]?.array == [.string(ImageModel.sunburst.rawValue)])
        #expect(try requestJSON(requests[1])["model"]?.string == ImageModel.sunburst.rawValue)
        #expect(requests.count == 2)
    }
    @Test func rejectsInvalidIDsAndKnownImageModelsBeforeAnyRequest() throws {
        for id in ["", "   ", "bad\nmodel", "bad\u{0}model", String(repeating: "a", count: 201)] + ImageModel.allCases.map(\.rawValue) {
            #expect(throws: (any Error).self) { try PlannerModel.validated(id) }
        }
        #expect(try PlannerModel.validated("  custom/Planner:2026  ") == "custom/Planner:2026")
        #expect(try PlannerModel.validated(String(repeating: "a", count: 200)).count == 200)
        #expect(throws: (any Error).self) { try APIClient(baseURL: "https://models.invalid", apiKey: "fake-private-key", plannerModel: "prefix-fake-private-key", transport: RecordingTransport([])) }
    }
    @Test func unsupportedPlannerReportsActualFailureWithoutFallbackOrRetry() async throws {
        let transport = RecordingTransport([httpJSON(#"{"error":{"message":"selected model has no tool support"}}"#, status: 400)])
        let client = try APIClient(baseURL: "https://models.invalid", apiKey: "fake-key", plannerModel: "no-tools-custom", transport: transport)
        await #expect(throws: APIError.self) { try await client.respond(input: [], selection: .init()) }
        #expect(await transport.requests.count == 1)
        let request = try #require(await transport.requests.first)
        #expect(try requestJSON(request)["model"]?.string == "no-tools-custom")
    }
}

@Suite struct PlannerRunMetadataTests {
    @Test func actualClientPlannerIsRecordedAndLegacyRunsStillDecode() async throws {
        let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths), conversation = try store.createConversation()
        let transport = RecordingTransport([try plannedTool(), imageReply()])
        let client = try APIClient(baseURL: "https://offline.invalid", apiKey: "fake-key", plannerModel: "actual/custom-planner", transport: transport)
        let outcome = try await AgentEngine(store: store, client: client).submit(.init(conversationID: conversation.id, text: "A quiet lake"))
        #expect(outcome.run.plannerModel == "actual/custom-planner")
        #expect(try store.run(outcome.run.id)?.plannerModel == "actual/custom-planner")
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(outcome.run)) as? [String: Any])
        old.removeValue(forKey: "plannerModel")
        let legacy = try JSONDecoder().decode(RunRecord.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(legacy.plannerModel == nil && legacy.id == outcome.run.id && legacy.selection == outcome.run.selection)
    }
}

@Suite struct PlannerModelCredentialTests {
    @Test func embeddedKeyPrefixInTaskPlannerRemainsAnExactSelectedRequestID() async throws {
        let transport = RecordingTransport([httpJSON(#"{"status":"completed","output":[]}"#)])
        let client = try APIClient(baseURL: "https://models.invalid", apiKey: "configured-private-key", plannerModel: "task-planner", transport: transport)
        _ = try await client.respond(input: [], selection: .init())
        let request = try #require(await transport.requests.first)
        let body = try requestJSON(request)
        #expect(client.selectedPlannerModel == "task-planner" && body["model"]?.string == "task-planner")
        #expect(body["stream"] == .bool(true) && body["store"] == .bool(false))
        // Model-ID validation must not narrow the existing public display/stream redactor.
        #expect(client.sanitized("task-planner") == "ta[已隐藏]")
    }
    @Test func discoveryKeepsTaskPlannerSpellingWhileOmittingRealKeysAndStandaloneTokens() async throws {
        let ids = ["task-planner", "team/task-planner:preview", "configured-private-key", "prefix-configured-private-key-suffix", "sk-other-secret", "(sk-other-secret)", "Bearer other-token", "prefix Bearer other-token"]
        let data = try JSONEncoder().encode(JSONValue.object(["data": .array(ids.map { .object(["id": .string($0)]) })]))
        let transport = RecordingTransport([.init(data: data, statusCode: 200)])
        let client = try APIClient(baseURL: "https://models.invalid", apiKey: "configured-private-key", transport: transport)
        #expect(try await client.validateConnection() == ["task-planner", "team/task-planner:preview"])
        #expect(await transport.requests.count == 1)
    }
    @Test func selectedModelStillRejectsConfiguredKeyContainmentAndStandaloneCredentialTokens() throws {
        for id in ["configured-private-key", "prefix-configured-private-key-suffix", "sk-other-secret", "(sk-other-secret)", "Bearer other-token", "prefix Bearer other-token"] {
            #expect(throws: (any Error).self) {
                try APIClient(baseURL: "https://models.invalid", apiKey: "configured-private-key", plannerModel: id, transport: RecordingTransport([]))
            }
        }
    }
}
