import Foundation
import Testing
@testable import ImageAgentCore

actor RecordingTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var replies: [HTTPResponse]
    var onRequest: (@Sendable (URLRequest, Int) throws -> Void)?
    init(_ replies: [HTTPResponse], onRequest: (@Sendable (URLRequest, Int) throws -> Void)? = nil) { self.replies = replies; self.onRequest = onRequest }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        try onRequest?(request, requests.count)
        guard !replies.isEmpty else { throw ImageAgentError.invalidInput("Unexpected duplicate HTTP request") }
        return replies.removeFirst()
    }
}
func httpJSON(_ text: String, status: Int = 200) -> HTTPResponse { .init(data: Data(text.utf8), statusCode: status) }
func imageReply() -> HTTPResponse { httpJSON("{\"data\":[{\"b64_json\":\"\(testPNG.base64EncodedString())\"}]}") }
func requestJSON(_ request: URLRequest) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody)) }

@Suite struct APIClientTests {
    @Test func normalizesOnlyOnceAndRejectsUnsafeURLs() throws {
        #expect(try ServiceEndpoint(" https://api.example.com/ ").string == "https://api.example.com/v1")
        #expect(try ServiceEndpoint("https://api.example.com/v1/").url("responses").path == "/v1/responses")
        #expect(try ServiceEndpoint("http://127.0.0.1:9876").string == "http://127.0.0.1:9876/v1")
        for invalid in ["http://example.com", "https://user:secret@example.com", "https://example.com?key=secret", "file:///tmp/api", "https://example.com/v1/v1"] {
            #expect(throws: (any Error).self) { try ServiceEndpoint(invalid) }
        }
    }

    @Test func responseStoreFalseAndRawOutputPreserved() async throws {
        let raw = #"{"status":"completed","output":[{"type":"reasoning","id":"rs_1","encrypted_content":"opaque"},{"type":"message","content":[{"type":"output_text","text":"你好"}]}]}"#
        let transport = RecordingTransport([httpJSON(raw)])
        let client = try APIClient(baseURL: "https://api.example.com", apiKey: "test-secret", transport: transport)
        let response = try await client.respond(input: [.object(["role":.string("user"),"content":.string("hello")])], selection: .init())
        let request = try #require(await transport.requests.first)
        let json = try requestJSON(request)
        #expect(request.url?.path == "/v1/responses")
        #expect(json["model"]?.string == "gpt-6.1-sol")
        #expect(json["store"] == .bool(false))
        #expect(json["stream"] == .bool(true))
        #expect(json["previous_response_id"] == nil)
        #expect(json["tool_choice"]?["type"]?.string == "function")
        #expect(json["tool_choice"]?["name"]?.string == "prepare_image_request")
        #expect(json["reasoning"]?["effort"]?.string == "low")
        #expect(json["max_output_tokens"] == .number(4096))
        #expect(json["tools"]?.array?.count == 1)
        #expect(json["tools"]?.array?.first?["name"]?.string == "prepare_image_request")
        #expect(response.output.first?["encrypted_content"]?.string == "opaque")
        #expect(response.text == "你好")
    }

    @Test func exactModelsAndImageEndpoint() async throws {
        for model in ImageModel.allCases {
            let transport = RecordingTransport([imageReply()])
            let client = try APIClient(baseURL: "https://api.example.com/v1", apiKey: "test-secret", transport: transport)
            let result = try await client.generate(prompt: "A quiet mountain lake", selection: .init(model: model))
            #expect(result.width == 1 && result.height == 1)
            let request = try #require(await transport.requests.first)
            #expect(request.url?.path == "/v1/images/generations")
            #expect(try requestJSON(request)["model"]?.string == model.rawValue)
            #expect(try requestJSON(request)["n"] == .number(1))
        }
    }

    @Test func editIsMultipartWithReferenceBytes() async throws {
        let transport = RecordingTransport([imageReply()])
        let client = try APIClient(baseURL: "https://api.example.com/v1", apiKey: "test-secret", transport: transport)
        _ = try await client.edit(prompt: "Change the sky", selection: .init(model: .sunburst), reference: testPNG)
        let request = try #require(await transport.requests.first)
        #expect(request.url?.path == "/v1/images/edits")
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let body = try #require(request.httpBody)
        #expect(body.range(of: testPNG) != nil)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("name=\"image\"; filename=\"reference.png\""))
        #expect(text.contains("gpt-image-2.5-sunburst"))
    }

    @Test func imageDownloadHasNoAuthorizationAndInvalidBytesFail() async throws {
        let transport = RecordingTransport([httpJSON(#"{"data":[{"url":"https://images.example.test/result.png"}]}"#), .init(data: testPNG, statusCode: 200)])
        let client = try APIClient(baseURL: "https://api.example.com", apiKey: "test-secret", transport: transport)
        _ = try await client.generate(prompt: "a lake", selection: .init())
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == nil)
        for response in [#"{"data":[{"b64_json":"not base64"}]}"#, #"{"data":[{"b64_json":"aGVsbG8="}]}"#, #"{"data":[{"url":"http://images.example.test/a.png"}]}"#] {
            let mock = RecordingTransport([httpJSON(response)])
            let api = try APIClient(baseURL: "https://api.example.com", apiKey: "test-secret", transport: mock)
            await #expect(throws: (any Error).self) { try await api.generate(prompt: "lake", selection: .init()) }
            #expect(await mock.requests.count == 1)
        }
    }

    @Test func redactsErrorsAndNeverRetriesAnImage() async throws {
        let secret = "sk-private-secret-value"
        let transport = RecordingTransport([httpJSON("{\"error\":{\"message\":\"Bearer \(secret) is invalid\"}}", status: 401)])
        let client = try APIClient(baseURL: "https://api.example.com", apiKey: secret, transport: transport)
        do { _ = try await client.generate(prompt: "a lake", selection: .init()); Issue.record("Expected auth failure") }
        catch { #expect(!error.localizedDescription.contains(secret)); #expect(error.localizedDescription.contains("401")) }
        #expect(await transport.requests.count == 1)
    }

    @Test func refusesIncompleteOrFailedResponsesBeforeToolExecution() async throws {
        for response in [
            #"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"reasoning","id":"rs_1","summary":[]}]}"#,
            #"{"status":"failed","error":{"message":"upstream planning error"},"output":[]}"#
        ] {
            let transport = RecordingTransport([httpJSON(response)])
            let client = try APIClient(baseURL: "https://api.example.com", apiKey: "test-secret", transport: transport)
            await #expect(throws: (any Error).self) { try await client.respond(input: [], selection: .init()) }
            #expect(await transport.requests.count == 1)
        }
    }
}

@Suite struct RegionAPITests {
    @Test func alphaMaskIsUploadedAsPNGWithCropAndInvalidMaskFailsBeforeHTTP() async throws {
        let image = try colorGrid(width: 3, height: 2).pngData()
        let mask = try PixelImage(width: 3, height: 2, rgba: [UInt8](repeating: 0, count: 24)).pngData()
        let transport = RecordingTransport([imageReply()])
        let client = try APIClient(baseURL: "https://api.example.com", apiKey: "test-secret", transport: transport)
        _ = try await client.edit(prompt: "change selected pixels", selection: .init(size: .auto), reference: image, mask: mask)
        let body = try #require(await transport.requests.first?.httpBody)
        #expect(body.range(of: mask) != nil)
        #expect(String(decoding: body, as: UTF8.self).contains("name=\"mask\"; filename=\"mask.png\"\r\nContent-Type: image/png"))
        await #expect(throws: (any Error).self) { try await client.edit(prompt: "edit", selection: .init(), reference: image, mask: testPNG) }
        #expect(await transport.requests.count == 1)
    }
}
