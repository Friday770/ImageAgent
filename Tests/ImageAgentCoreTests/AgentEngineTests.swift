import Foundation
import Testing
@testable import ImageAgentCore

func plannedTool(_ operation: String = "generate_image", model: String = "gpt-image-2", reference: String? = nil, extra: [String: JSONValue] = [:]) throws -> HTTPResponse {
    let action = operation == "edit_image" ? "edit" : (operation == "reply" ? "reply" : "generate")
    var arguments: [String: JSONValue] = [
        "action": .string(action), "prompt": .string(action == "reply" ? "" : "A detailed watercolor mountain lake at sunrise"),
        "model": .string(model), "size": .string("1024x1024"), "quality": .string("auto"),
        "reference_image_id": reference.map(JSONValue.string) ?? .null,
        "reply_text": .string(action == "reply" ? "你好，可以一起讨论创作想法。" : "晨光映在安静的湖面上。")
    ]
    extra.forEach { arguments[$0.key] = $0.value }
    let name = ["generate_image", "edit_image", "reply"].contains(operation) ? "prepare_image_request" : operation
    let output: JSONValue = .object(["status": .string("completed"), "output": .array([
        .object(["type": .string("reasoning"), "id": .string("rs_opaque"), "encrypted_content": .string("preserve-me")]),
        .object(["type": .string("function_call"), "name": .string(name), "call_id": .string("call_1"), "arguments": .string(try JSONValue.object(arguments).encodedString())])
    ])])
    return .init(data: try JSONEncoder().encode(output), statusCode: 200)
}
func finalReply() -> HTTPResponse { httpJSON(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"图片已生成。"}]}]}"#) }
struct TestFinalizer: ImageReplyFinalizer {
    let body: @Sendable ([AssetRecord], String) throws -> String
    func finalize(assets: [AssetRecord], caption: String) throws -> String { try body(assets, caption) }
}

@Suite struct AgentEngineTests {
    @Test func automaticGenerationSavesBeforeLocalFinalization() async throws {
        let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths); let conversation = try store.createConversation()
        let transport = RecordingTransport([try plannedTool(), imageReply()])
        let client = try APIClient(baseURL: "https://api.example.com", apiKey: "test-secret", transport: transport)
        let finalizer = TestFinalizer { assets, _ in
            let records = try store.assets(in: conversation.id)
            let asset = try #require(assets.first)
            let runID = try #require(asset.runID)
            let run = try store.run(runID)
            #expect(records.count == 1)
            #expect(run?.resultAssetIDs == assets.map(\.id))
            return "图片已保存。"
        }
        let outcome = try await AgentEngine(store: store, client: client, finalizer: finalizer).submit(.init(conversationID: conversation.id, text: "画一幅晨光湖泊"))
        #expect(outcome.run.stage == .completed)
        let asset = try #require(outcome.assets.first)
        #expect(FileManager.default.fileExists(atPath: try store.assetURL(asset).path))
        #expect(asset.width == 1 && asset.dimensionWarning != nil)
        #expect(outcome.message.assetIDs == [asset.id])
        #expect(await transport.requests.count == 2)
        #expect(await transport.requests.filter { $0.url?.path.contains("/images/") == true }.count == 1)
    }

    @Test func failedLocalFinalizationRetainsImageWithoutAnotherRemoteCall() async throws {
        let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths); let conversation = try store.createConversation()
        let transport = RecordingTransport([try plannedTool(), imageReply()])
        let client = try APIClient(baseURL: "https://api.example.com", apiKey: "test-secret", transport: transport)
        let finalizer = TestFinalizer { _, _ in throw ImageAgentError.storage("local finalizer failed") }
        let outcome = try await AgentEngine(store: store, client: client, finalizer: finalizer).submit(.init(conversationID: conversation.id, text: "画湖"))
        #expect(outcome.run.stage == .failed)
        #expect(outcome.assets.count == 1 && outcome.message.assetIDs.count == 1)
        #expect(outcome.message.text.contains("已保存"))
        #expect(await transport.requests.count == 2)
        let reopened = try SQLiteStore(paths: paths); try reopened.recoverInterruptedRuns()
        #expect(try reopened.assets(in: conversation.id).count == 1)
        #expect(try reopened.messages(in: conversation.id).last?.assetIDs.count == 1)
    }

    @Test func editsOnlyAuthorizedCurrentConversationReference() async throws {
        let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths)
        let conversation = try store.createConversation(); let other = try store.createConversation()
        let asset = try store.saveImage(testPNG, conversationID: conversation.id, source: .imported)
        let transport = RecordingTransport([try plannedTool("edit_image", reference: asset.id), imageReply()])
        let client = try APIClient(baseURL: "https://api.example.com", apiKey: "test-secret", transport: transport)
        let engine = AgentEngine(store: store, client: client)
        let outcome = try await engine.submit(.init(conversationID: conversation.id, text: "换成日落", referenceAssetID: asset.id))
        #expect(outcome.assets.first?.parentAssetID == asset.id)
        #expect(await transport.requests[1].url?.path == "/v1/images/edits")
        await #expect(throws: (any Error).self) { try await engine.submit(.init(conversationID: other.id, text: "edit", referenceAssetID: asset.id)) }
        #expect(await transport.requests.count == 2)
    }

    @Test func rejectsUnknownToolsModelChangesActionsAndReferences() async throws {
        for reply in [try plannedTool("run_shell"), try plannedTool(model: "gpt-image-2.5"), try plannedTool("edit_image", reference: "unknown"), try plannedTool(extra: ["command": .string("arbitrary code")]), try plannedTool(extra: ["action": .string("execute_command")])] {
            let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
            let store = try SQLiteStore(paths: paths); let conversation = try store.createConversation()
            let transport = RecordingTransport([reply])
            let client = try APIClient(baseURL: "https://api.example.com", apiKey: "test-secret", transport: transport)
            let outcome = try await AgentEngine(store: store, client: client).submit(.init(conversationID: conversation.id, text: "画图"))
            #expect(outcome.run.stage == .failed && outcome.assets.isEmpty)
            #expect(await transport.requests.count == 1)
        }
    }

    @Test func discussionPlanDoesNotCallImageAPI() async throws {
        let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths); let conversation = try store.createConversation()
        let transport = RecordingTransport([try plannedTool("reply")])
        let client = try APIClient(baseURL: "https://api.example.com", apiKey: "test-secret", transport: transport)
        let outcome = try await AgentEngine(store: store, client: client).submit(.init(conversationID: conversation.id, text: "你好"))
        #expect(outcome.run.stage == .completed && outcome.assets.isEmpty)
        #expect(outcome.message.text.contains("讨论"))
        #expect(await transport.requests.count == 1)
    }

    @Test func cancellationPersistsWithoutRetry() async throws {
        let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths); let conversation = try store.createConversation()
        let transport = RecordingTransport([try plannedTool()], onRequest: { _, count in if count == 2 { throw CancellationError() } })
        let client = try APIClient(baseURL: "https://api.example.com", apiKey: "test-secret", transport: transport)
        let outcome = try await AgentEngine(store: store, client: client).submit(.init(conversationID: conversation.id, text: "画图"))
        #expect(outcome.run.stage == .cancelled)
        #expect(try store.runs(in: conversation.id).first?.stage == .cancelled)
        #expect(await transport.requests.count == 2)
    }

    @Test func cancellationAfterImageResponseStillSavesKnownResult() async throws {
        let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths); let conversation = try store.createConversation()
        let transport = RecordingTransport([try plannedTool(), imageReply()], onRequest: { _, count in if count == 2 { withUnsafeCurrentTask { $0?.cancel() } } })
        let client = try APIClient(baseURL: "https://api.example.com", apiKey: "test-secret", transport: transport)
        let task = Task { try await AgentEngine(store: store, client: client).submit(.init(conversationID: conversation.id, text: "画图")) }
        let outcome = try await task.value
        #expect(outcome.run.stage == .cancelled && outcome.assets.count == 1)
        #expect(try store.assets(in: conversation.id).count == 1)
        #expect(outcome.message.assetIDs.count == 1)
        #expect(await transport.requests.count == 2)
    }

    @Test func singlePlanNeverRequestsRemoteFinalization() async throws {
        let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths); let conversation = try store.createConversation()
        let transport = RecordingTransport([try plannedTool(), imageReply(), try plannedTool()])
        let client = try APIClient(baseURL: "https://api.example.com", apiKey: "test-secret", transport: transport)
        let outcome = try await AgentEngine(store: store, client: client).submit(.init(conversationID: conversation.id, text: "画图"))
        #expect(outcome.run.stage == .completed && outcome.assets.count == 1)
        #expect(await transport.requests.count == 2)
        #expect(await transport.requests.filter { $0.url?.path == "/v1/responses" }.count == 1)
    }

    @Test func preservesUnexpectedNativeImageWithoutAnotherImageRequest() async throws {
        let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths); let conversation = try store.createConversation()
        let response = httpJSON("{\"status\":\"incomplete\",\"output\":[{\"type\":\"image_generation_call\",\"result\":\"\(testPNG.base64EncodedString())\"},{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"\"}]}]}")
        let transport = RecordingTransport([response])
        let client = try APIClient(baseURL: "https://api.example.com", apiKey: "test-secret", transport: transport)
        let outcome = try await AgentEngine(store: store, client: client).submit(.init(conversationID: conversation.id, text: "编辑图片"))
        #expect(outcome.run.stage == .failed && outcome.assets.count == 1)
        #expect(outcome.assets.first?.modelVerified == false)
        #expect(outcome.assets.first?.prompt.isEmpty == true)
        #expect(outcome.message.text.contains("未验证"))
        #expect(await transport.requests.count == 1)
    }
}
