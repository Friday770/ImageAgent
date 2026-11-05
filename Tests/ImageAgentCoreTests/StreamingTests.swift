import Foundation
import Testing
@testable import ImageAgentCore

func streamEvent(_ type: String, _ fields: [String: JSONValue] = [:], newline: String = "\n") throws -> Data {
    var object = fields; object["type"] = .string(type)
    return Data(("event: \(type)\(newline)data: \(try JSONValue.object(object).encodedString())\(newline)\(newline)").utf8)
}
func streamItem(_ arguments: String = "", name: String = "prepare_image_request", id: String = "fc_1") -> JSONValue {
    .object(["type": .string("function_call"), "id": .string(id), "name": .string(name), "call_id": .string("call_1"), "arguments": .string(arguments)])
}
func streamPlan(prompt: String = "清晨的湖泊", action: String = "generate", reference: String? = nil, selection: ImageSelection = .init()) throws -> String {
    try JSONValue.object(["action": .string(action), "prompt": .string(prompt), "model": .string(selection.model.rawValue),
        "size": .string(selection.size.rawValue), "quality": .string(selection.quality.rawValue),
        "reference_image_id": reference.map(JSONValue.string) ?? .null, "reply_text": .string("完成")]).encodedString()
}
func streamCompleted(_ arguments: String, status: String = "completed") throws -> Data {
    try streamEvent("response.\(status)", ["response": .object(["status": .string(status), "output": .array([streamItem(arguments)])])])
}
func streamAdded() throws -> Data { try streamEvent("response.output_item.added", ["output_index": .number(0), "item": streamItem()]) }
func streamDelta(_ delta: String, id: String = "fc_1", index: Int = 0) throws -> Data {
    try streamEvent("response.function_call_arguments.delta", ["item_id": .string(id), "output_index": .number(Double(index)), "delta": .string(delta)])
}

final class PreviewLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    var text: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

/// Bytes can only advance when the test opens the gate; send never supplies planner data.
actor GatedStreamingTransport: HTTPTransport {
    var requests: [URLRequest] = []
    private let contentType: String
    private var receive: (@Sendable (HTTPStreamEvent) throws -> Void)?
    private var finished: CheckedContinuation<Void, Error>?
    private var ready: [CheckedContinuation<Void, Never>] = []
    init(contentType: String = "text/event-stream") { self.contentType = contentType }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard request.url?.path.contains("/images/") == true else { throw ImageAgentError.invalidInput("Planner must use incremental transport") }
        return imageReply()
    }
    func stream(_ request: URLRequest, receive: @escaping @Sendable (HTTPStreamEvent) throws -> Void) async throws {
        requests.append(request); self.receive = receive
        try receive(.response(statusCode: 200, contentType: contentType))
        for waiter in ready { waiter.resume() }; ready = []
        try await withCheckedThrowingContinuation { finished = $0 }
    }
    func waitUntilReady() async {
        if receive != nil { return }
        await withCheckedContinuation { ready.append($0) }
    }
    func emit(_ data: Data) throws { try receive?(.bytes(data)) }
    func finish(_ error: Error? = nil) {
        if let error { finished?.resume(throwing: error) } else { finished?.resume() }
        finished = nil; receive = nil
    }
}

@Suite struct StreamingParserTests {
    @Test func realByteFragmentsDecodeUTF8EscapesAndSurrogatesBeforeTerminal() throws {
        let parser = ResponsesStreamDecoder()
        var previews: [String] = []
        let prefix = try streamAdded() + streamDelta(#"{"reply_text":"ignored prompt","prompt":"湖泊 \"晨光\" \\ \n \uD83D"#)
        for byte in prefix { previews += try parser.append(Data([byte])) }
        #expect(previews.last == "湖泊 \"晨光\" \\ \n ")
        let rest = #"\uDE00","action":"generate","model":"gpt-image-2","size":"1024x1024","quality":"auto","reference_image_id":null}"#
        previews += try parser.append(streamDelta(rest))
        #expect(previews.last == "湖泊 \"晨光\" \\ \n 😀")
        #expect(throws: (any Error).self) { try parser.finish() }
        _ = try parser.append(streamCompleted(#"{"reply_text":"ignored prompt","prompt":"湖泊 \"晨光\" \\ \n \uD83D\uDE00","action":"generate","model":"gpt-image-2","size":"1024x1024","quality":"auto","reference_image_id":null}"#))
        #expect(try parser.finish().status == "completed")
    }

    @Test func framingHandlesCRLFHeartbeatMultilineAndFinalUnterminatedEvent() throws {
        let parser = ResponsesStreamDecoder()
        _ = try parser.append(Data(": heartbeat\r\n\r\n".utf8))
        let event = "event: response.completed\r\ndata: {\"type\":\"response.completed\",\r\ndata: \"response\":{\"status\":\"completed\",\"output\":[]}}"
        for byte in event.utf8 { _ = try parser.append(Data([byte])) }
        #expect(try parser.finish().status == "completed")
    }

    @Test func ignoresOtherFunctionReasoningAndOutputTextAndRejectsIdentityMismatch() throws {
        let parser = ResponsesStreamDecoder()
        _ = try parser.append(streamEvent("response.output_item.added", ["output_index": .number(0), "item": streamItem(name: "other")]))
        #expect(try parser.append(streamDelta(#"{"prompt":"do not display"}"#)).isEmpty)
        #expect(try parser.append(streamEvent("response.output_text.delta", ["delta": .string("hidden")])).isEmpty)
        #expect(try parser.append(streamEvent("response.reasoning_text.delta", ["delta": .string("hidden")])).isEmpty)
        #expect(throws: (any Error).self) { try parser.append(streamDelta("x", id: "foreign")) }
    }

    @Test func doneArgumentsEOFAndDoneMarkerAreNotSuccessfulTerminals() throws {
        let arguments = try streamPlan()
        for ending in [Data(), Data("data: [DONE]\n\n".utf8), try streamEvent("response.function_call_arguments.done", ["item_id": .string("fc_1"), "output_index": .number(0), "arguments": .string(arguments)])] {
            let parser = ResponsesStreamDecoder()
            _ = try parser.append(streamAdded() + streamDelta(arguments) + ending)
            #expect(throws: (any Error).self) { try parser.finish() }
        }
    }

    @Test func malformedOversizedAndFailedStreamsFailClosed() throws {
        for bytes in [Data("data: {invalid}\n\n".utf8), try streamCompleted(streamPlan(), status: "failed"), try streamCompleted(streamPlan(), status: "incomplete")] {
            let parser = ResponsesStreamDecoder()
            #expect(throws: (any Error).self) { _ = try parser.append(bytes); _ = try parser.finish() }
        }
        let parser = ResponsesStreamDecoder()
        _ = try parser.append(streamAdded())
        #expect(throws: (any Error).self) { try parser.append(streamDelta("{\"prompt\":\"" + String(repeating: "x", count: 32_001))) }
        let huge = ResponsesStreamDecoder()
        #expect(throws: (any Error).self) { try huge.append(streamEvent("response.output_text.delta", ["delta": .string(String(repeating: "x", count: 300_000))])) }
    }

    @Test func completeNativeBytesSurviveEOFAndIncompleteTerminal() throws {
        for terminal in [Data(), try streamCompleted(streamPlan(), status: "incomplete")] {
            let parser = ResponsesStreamDecoder()
            let native: JSONValue = .object(["id": .string("native_1"), "type": .string("image_generation_call"), "result": .string(testPNG.base64EncodedString())])
            _ = try parser.append(streamEvent("response.output_item.done", ["output_index": .number(1), "item": native]))
            _ = try? parser.append(terminal)
            #expect(throws: (any Error).self) { try parser.finish() }
            #expect(parser.partialResponse.recoverBase64ImageOutput().images.first?.data == testPNG)
        }
    }

    @Test func nativeEventBudgetPreservesValidBytesLargerThanOrdinaryArgumentBudget() throws {
        let bytes = testPNG + Data(repeating: 0, count: 300_000)
        let parser = ResponsesStreamDecoder()
        _ = try parser.append(streamEvent("response.output_item.done", ["output_index": .number(0), "item": .object(["id": .string("large_native"), "type": .string("image_generation_call"), "result": .string(bytes.base64EncodedString())])]))
        #expect(parser.partialResponse.recoverBase64ImageOutput().images.first?.data == bytes)
    }

    @Test func truncatedNativeImageIsNotRecoveredEvenWhenBase64AndHeaderAreDecodable() throws {
        let truncated = testPNG.dropLast(12) // Complete pixel data but missing the PNG IEND chunk.
        let response = ResponseResult(output: [.object(["type": .string("image_generation_call"), "result": .string(truncated.base64EncodedString())])])
        #expect(response.recoverBase64ImageOutput().images.isEmpty)
        #expect(!response.recoverBase64ImageOutput().failures.isEmpty)
    }

    @Test func rejectsOrphanIndexesDuplicateFieldsChangedArgumentsAndTerminals() throws {
        let arguments = try streamPlan()
        for (caseIndex, tail) in [try streamDelta("x", index: 1), try streamDelta(#"{"prompt":"a","prompt":"b"}"#), try streamCompleted("{}"), try streamCompleted(arguments) + streamCompleted(arguments)].enumerated() {
            let parser = ResponsesStreamDecoder()
            _ = try parser.append(streamAdded())
            if caseIndex != 1 { _ = try parser.append(streamDelta(arguments)) }
            #expect(throws: (any Error).self) { try parser.append(tail) }
        }
    }

    @Test func repeatedNativeIdentityAndBytesIgnoreStatusWhileDifferentKnownBytesSurvive() throws {
        let first: JSONValue = .object(["id": .string("native_same"), "type": .string("image_generation_call"), "status": .string("in_progress"), "result": .string(testPNG.base64EncodedString())])
        let completed: JSONValue = .object(["id": .string("native_same"), "type": .string("image_generation_call"), "status": .string("completed"), "result": .string(testPNG.base64EncodedString())])
        let parser = ResponsesStreamDecoder()
        _ = try parser.append(streamEvent("response.output_item.added", ["output_index": .number(0), "item": first]))
        _ = try parser.append(streamEvent("response.completed", ["response": .object(["status": .string("completed"), "output": .array([completed])])]))
        let response = try parser.finish()
        #expect(response.nativeImageOutputs.count == 1)
        #expect(response.recoverBase64ImageOutput().images.map(\.data) == [testPNG])

        let differentBytes = testPNG + Data([0])
        let different: JSONValue = .object(["id": .string("native_same"), "type": .string("image_generation_call"), "status": .string("completed"), "result": .string(differentBytes.base64EncodedString())])
        let interrupted = ResponsesStreamDecoder()
        _ = try interrupted.append(streamEvent("response.output_item.added", ["output_index": .number(0), "item": first]))
        _ = try interrupted.append(streamEvent("response.output_item.done", ["output_index": .number(0), "item": different]))
        #expect(throws: (any Error).self) { try interrupted.finish() }
        #expect(Set(interrupted.partialResponse.recoverBase64ImageOutput().images.map(\.data)) == Set([testPNG, differentBytes]))
    }
}

@Suite struct StreamingEngineTests {
    @Test func isolatedSimulationUsesActualChunkParserAndCanStopWithoutAnImageRequest() async throws {
        for interrupted in [false, true] {
            let transport = SimulatedPlanningTransport(imageData: testPNG, delay: .zero, interruptAfterPreview: interrupted)
            let client = try APIClient(baseURL: "https://offline.invalid", apiKey: "offline-placeholder", transport: transport)
            let previews = PreviewLog()
            if interrupted {
                await #expect(throws: (any Error).self) { try await client.respond(input: [], selection: .init(), promptPreview: { previews.append($0) }) }
            } else {
                let response = try await client.respond(input: [], selection: .init(), promptPreview: { previews.append($0) })
                #expect(response.status == "completed")
            }
            #expect(previews.text.count >= 3 && previews.text.first!.count < previews.text.last!.count)
            let stats = await transport.statistics()
            #expect(stats.plans == 1 && stats.images == 0)
        }
    }

    @Test func gatedPromptGrowthPrecedesTerminalAndExactlyOneImageRequestWithPersistedFinalEquality() async throws {
        let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths); let conversation = try store.createConversation()
        let transport = GatedStreamingTransport(); let previews = PreviewLog()
        let client = try APIClient(baseURL: "https://example.test", apiKey: "test-secret", transport: transport)
        let engine = AgentEngine(store: store, client: client)
        let task = Task { try await engine.submit(.init(conversationID: conversation.id, text: "湖泊"), planningPreview: { previews.append($0.text) }) }
        await transport.waitUntilReady()
        let first = #"{"prompt":"清晨"#
        let second = #"的湖泊","action":"generate","model":"gpt-image-2","size":"1024x1024","quality":"auto","reference_image_id":null,"reply_text":"完成"}"#
        try await transport.emit(streamAdded() + streamDelta(first))
        #expect(previews.text.last == "清晨")
        try await transport.emit(streamDelta(second))
        #expect(previews.text.last == "清晨的湖泊" && previews.text.count >= 2)
        #expect(await transport.requests.count == 1)
        #expect(try store.runs(in: conversation.id).first?.detailedPrompt == nil)
        #expect(try MemoryBuilder(store: store).build(conversationID: conversation.id).entries.count == 1)
        try await transport.emit(streamCompleted(first + second))
        await transport.finish()
        let outcome = try await task.value
        #expect(outcome.run.stage == .completed)
        let imageRequest = try #require(await transport.requests.last)
        let actual = try requestJSON(imageRequest)["prompt"]?.string
        #expect(actual == "清晨的湖泊" && outcome.run.detailedPrompt == actual && outcome.message.detailedPrompt == actual)
        let reopened = try SQLiteStore(paths: paths)
        #expect(try reopened.messages(in: conversation.id).last?.detailedPrompt == actual)
        #expect(await transport.requests.count == 2)
    }

    @Test func splitConfiguredSecretNeverAppearsInPreviewOrFinalAndHTTPIsSingleShot() async throws {
        let transport = GatedStreamingTransport(); let previews = PreviewLog()
        let secret = "configured-private-key"
        let client = try APIClient(baseURL: "https://example.test", apiKey: secret, transport: transport)
        let task = Task { try await client.respond(input: [], selection: .init(), promptPreview: { previews.append($0) }) }
        await transport.waitUntilReady()
        try await transport.emit(streamAdded() + streamDelta(#"{"prompt":"lake configured-pr"#))
        #expect(previews.text.allSatisfy { !$0.contains("configured-pr") })
        try await transport.emit(streamDelta(#"ivate-key sky sk-part"#))
        #expect(previews.text.allSatisfy { !$0.contains(secret) && !$0.contains("sk-part") })
        await transport.finish(URLError(.networkConnectionLost))
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(await transport.requests.count == 1)
    }

    @Test func completeNonSKCredentialIsRedactedBeforeSuffixWithholdingAcrossRealFragments() async throws {
        let transport = GatedStreamingTransport(); let previews = PreviewLog()
        let client = try APIClient(baseURL: "https://example.test", apiKey: "private-value-b", transport: transport)
        let task = Task { try await client.respond(input: [], selection: .init(), promptPreview: { previews.append($0) }) }
        await transport.waitUntilReady()
        let first = #"{"prompt":"请保密 private-"#
        let second = #"value-b","action":"generate","model":"gpt-image-2","size":"1024x1024","quality":"auto","reference_image_id":null,"reply_text":"完成"}"#
        try await transport.emit(streamAdded() + streamDelta(first))
        #expect(previews.text.last == "请保密 ")
        try await transport.emit(streamDelta(second))
        #expect(previews.text.last == "请保密 [已隐藏]")
        #expect(previews.text.allSatisfy { !$0.contains("private-") })
        try await transport.emit(streamCompleted(first + second)); await transport.finish()
        _ = try await task.value
        #expect(previews.text.last == "请保密 [已隐藏]")
        #expect(await transport.requests.count == 1)
    }

    @Test func completedPromptFlushesSpeculativeSuffixAndMatchesTheSafelyRedactedFinalPrompt() async throws {
        for jsonCompatibility in [false, true] {
            let prompt = "soft green grass"
            let arguments = try streamPlan(prompt: prompt)
            let previews = PreviewLog()
            if jsonCompatibility {
                let response: JSONValue = .object(["status": .string("completed"), "output": .array([streamItem(arguments)])])
                let transport = RecordingTransport([httpJSON(try response.encodedString())])
                let client = try APIClient(baseURL: "https://example.test", apiKey: "sk-configured-test-value", transport: transport)
                _ = try await client.respond(input: [], selection: .init(), promptPreview: { previews.append($0) })
                #expect(previews.text == [prompt])
                #expect(await transport.requests.count == 1)
            } else {
                let transport = GatedStreamingTransport()
                let client = try APIClient(baseURL: "https://example.test", apiKey: "sk-configured-test-value", transport: transport)
                let task = Task { try await client.respond(input: [], selection: .init(), promptPreview: { previews.append($0) }) }
                await transport.waitUntilReady()
                try await transport.emit(streamAdded() + streamDelta(arguments))
                #expect(previews.text.last == "soft green gra")
                try await transport.emit(streamCompleted(arguments)); await transport.finish()
                let response = try await task.value
                let final = try JSONDecoder().decode(JSONValue.self, from: Data(response.toolCalls[0].arguments.utf8))["prompt"]?.string
                #expect(previews.text.last == client.sanitized(try #require(final)))
                #expect(await transport.requests.count == 1)
            }
        }
    }

    @Test func EOFErrorCancelledAndInvalidTerminalNeverExecutePartialPlan() async throws {
        for failure in [nil, URLError(.networkConnectionLost) as Error?, CancellationError() as Error?] {
            let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
            let store = try SQLiteStore(paths: paths); let conversation = try store.createConversation()
            let transport = GatedStreamingTransport(); let previews = PreviewLog()
            let engine = AgentEngine(store: store, client: try APIClient(baseURL: "https://example.test", apiKey: "test-secret", transport: transport))
            let task = Task { try await engine.submit(.init(conversationID: conversation.id, text: "lake"), planningPreview: { previews.append($0.text) }) }
            await transport.waitUntilReady(); try await transport.emit(streamAdded() + streamDelta(streamPlan()))
            await transport.finish(failure)
            let outcome = try await task.value
            #expect(outcome.run.stage == (failure is CancellationError ? .cancelled : .failed))
            #expect(!previews.text.isEmpty && outcome.run.detailedPrompt == nil && outcome.message.detailedPrompt == nil)
            #expect(await transport.requests.count == 1)
        }
    }

    @Test func nativeImageReceivedBeforeNetworkFailureIsSavedUnverifiedWithoutReplay() async throws {
        let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths); let conversation = try store.createConversation()
        let transport = GatedStreamingTransport()
        let engine = AgentEngine(store: store, client: try APIClient(baseURL: "https://example.test", apiKey: "test-secret", transport: transport))
        let task = Task { try await engine.submit(.init(conversationID: conversation.id, text: "lake")) }
        await transport.waitUntilReady()
        try await transport.emit(streamEvent("response.output_item.done", ["output_index": .number(0), "item": .object(["id": .string("native"), "type": .string("image_generation_call"), "result": .string(testPNG.base64EncodedString())])]))
        await transport.finish(URLError(.networkConnectionLost))
        let outcome = try await task.value
        #expect(outcome.run.stage == .failed && outcome.assets.first?.modelVerified == false)
        #expect(try Data(contentsOf: store.assetURL(#require(outcome.assets.first))) == testPNG)
        #expect(await transport.requests.count == 1)
    }

    @Test func nativeBytesArePreservedWithCancelledStatusWhenTransportCancels() async throws {
        let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths); let conversation = try store.createConversation()
        let transport = GatedStreamingTransport()
        let engine = AgentEngine(store: store, client: try APIClient(baseURL: "https://example.test", apiKey: "test-secret", transport: transport))
        let task = Task { try await engine.submit(.init(conversationID: conversation.id, text: "lake")) }
        await transport.waitUntilReady()
        try await transport.emit(streamEvent("response.output_item.done", ["output_index": .number(0), "item": .object(["id": .string("native"), "type": .string("image_generation_call"), "result": .string(testPNG.base64EncodedString())])]))
        await transport.finish(CancellationError())
        let outcome = try await task.value
        #expect(outcome.run.stage == .cancelled && outcome.assets.first?.modelVerified == false)
        #expect(await transport.requests.count == 1)
    }

    @Test func bufferedJSONNativeRecoverySurvivesTransportFailureWithoutCompletingPartialJSONOrPlans() async throws {
        let complete: JSONValue = .object(["status": .string("completed"), "output": .array([
            .object(["id": .string("json_native"), "type": .string("image_generation_call"), "result": .string(testPNG.base64EncodedString())]),
            streamItem(try streamPlan())
        ])])
        let fullData = Data(try complete.encodedString().utf8)
        let planOnly = Data(try JSONValue.object(["status": .string("completed"), "output": .array([streamItem(streamPlan())])]).encodedString().utf8)
        for (data, shouldRecover) in [(fullData, true), (Data(fullData.dropLast()), false), (planOnly, false)] {
            let parser = ResponsesStreamDecoder()
            #expect(try parser.append(data).isEmpty)
            let snapshot = parser.partialResponse
            #expect(snapshot.status == nil && snapshot.toolCalls.isEmpty && parser.finalPreviews.isEmpty)
            #expect(snapshot.recoverBase64ImageOutput().images.count == (shouldRecover ? 1 : 0))
            for cancelled in [false, true] {
                let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
                let store = try SQLiteStore(paths: paths); let conversation = try store.createConversation()
                let transport = GatedStreamingTransport(contentType: "application/json"); let previews = PreviewLog()
                let engine = AgentEngine(store: store, client: try APIClient(baseURL: "https://example.test", apiKey: "test-secret", transport: transport))
                let task = Task { try await engine.submit(.init(conversationID: conversation.id, text: "lake"), planningPreview: { previews.append($0.text) }) }
                await transport.waitUntilReady()
                let split = data.count / 2
                try await transport.emit(Data(data.prefix(split)))
                try await transport.emit(Data(data.dropFirst(split)))
                #expect(previews.text.isEmpty)
                #expect(try store.assets(in: conversation.id).isEmpty)
                await transport.finish(cancelled ? CancellationError() : URLError(.networkConnectionLost))
                let outcome = try await task.value
                #expect(outcome.run.stage == (cancelled ? .cancelled : .failed))
                #expect(outcome.assets.count == (shouldRecover ? 1 : 0))
                if let asset = outcome.assets.first {
                    #expect(asset.modelVerified == false)
                    #expect(try Data(contentsOf: store.assetURL(asset)) == testPNG)
                }
                #expect(outcome.run.detailedPrompt == nil && outcome.message.detailedPrompt == nil && previews.text.isEmpty)
                #expect(try SQLiteStore(paths: paths).assets(in: conversation.id).count == (shouldRecover ? 1 : 0))
                #expect(await transport.requests.count == 1)
            }
        }
    }

    @Test func singleRequestJSONCompatibilityPublishesFullPromptAndDiscussionHasNoPreview() async throws {
        for action in ["generate", "reply"] {
            let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
            let store = try SQLiteStore(paths: paths); let conversation = try store.createConversation()
            let transport = RecordingTransport([try plannedTool(action == "reply" ? "reply" : "generate_image"), imageReply()])
            let previews = PreviewLog()
            let outcome = try await AgentEngine(store: store, client: APIClient(baseURL: "https://example.test", apiKey: "test-secret", transport: transport))
                .submit(.init(conversationID: conversation.id, text: "hello"), planningPreview: { previews.append($0.text) })
            #expect(outcome.run.stage == .completed)
            #expect(previews.text.count == (action == "reply" ? 0 : 1))
            #expect(previews.text.last == outcome.run.detailedPrompt)
            #expect(await transport.requests.filter { $0.url?.path == "/v1/responses" }.count == 1)
        }
    }

    @Test func failedImageStillPersistsTheExactValidatedPromptAndUnfinishedStreamDoesNot() async throws {
        let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try SQLiteStore(paths: paths); let conversation = try store.createConversation()
        let transport = RecordingTransport([try plannedTool(extra: ["prompt": .string("Draw sky with test-secret hidden")]), httpJSON(#"{"error":{"message":"image failed"}}"#, status: 500)])
        let outcome = try await AgentEngine(store: store, client: APIClient(baseURL: "https://example.test", apiKey: "test-secret", transport: transport)).submit(.init(conversationID: conversation.id, text: "lake"))
        let actual = try requestJSON(#require(await transport.requests.last))["prompt"]?.string
        #expect(outcome.run.stage == .failed && actual == "Draw sky with [已隐藏] hidden")
        #expect(outcome.run.detailedPrompt == actual && outcome.message.detailedPrompt == actual)
        #expect(try SQLiteStore(paths: paths).messages(in: conversation.id).last?.detailedPrompt == actual)
    }

    @Test func streamErrorRedactsConfiguredKeyAndNoTerminalNeverStartsAnImage() async throws {
        let secret = "configured-private-key"
        for tail in [try streamEvent("error", ["message": .string("failed " + secret)]), try streamCompleted(streamPlan(), status: "incomplete"), Data("data: [DONE]\n\n".utf8)] {
            let paths = try temporaryPaths(); defer { try? FileManager.default.removeItem(at: paths.root) }
            let store = try SQLiteStore(paths: paths); let conversation = try store.createConversation()
            let data = try streamAdded() + streamDelta(streamPlan()) + tail
            let transport = RecordingTransport([.init(data: data, statusCode: 200)])
            let outcome = try await AgentEngine(store: store, client: APIClient(baseURL: "https://example.test", apiKey: secret, transport: transport)).submit(.init(conversationID: conversation.id, text: "lake"))
            #expect(outcome.run.stage == .failed && outcome.run.detailedPrompt == nil && !outcome.message.text.contains(secret))
            #expect(await transport.requests.count == 1)
        }
    }
}
