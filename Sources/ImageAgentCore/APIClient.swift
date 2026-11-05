import Foundation
import ImageIO

public struct ServiceEndpoint: Equatable, Sendable {
    public let string: String
    public init(_ input: String) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())) else {
            throw ImageAgentError.invalidInput("请输入 HTTPS API 服务地址；仅本机测试允许 HTTP。地址不能含账号、查询参数或片段。")
        }
        parts.scheme = scheme; parts.host = host.lowercased()
        var path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              !path.contains("//"), !path.contains("v1/v1") else { throw ImageAgentError.invalidInput("API 地址包含重复或无效路径。") }
        if path != "v1", !path.hasSuffix("/v1") { path = path.isEmpty ? "v1" : path + "/v1" }
        parts.path = "/" + path
        guard let normalized = parts.url?.absoluteString else { throw ImageAgentError.invalidInput("API 地址无效。") }
        string = normalized
    }
    public func url(_ path: String) -> URL { URL(string: string + "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))! }
}

public struct HTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public init(data: Data, statusCode: Int) { self.data = data; self.statusCode = statusCode }
}
public enum HTTPStreamEvent: Sendable {
    case response(statusCode: Int, contentType: String?)
    case bytes(Data)
}
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
    /// Deliver headers followed by bytes serially, while the request is still in flight.
    func stream(_ request: URLRequest, receive: @escaping @Sendable (HTTPStreamEvent) throws -> Void) async throws
}
public extension HTTPTransport {
    /// Existing fixture transports can return one complete JSON response without a second request.
    func stream(_ request: URLRequest, receive: @escaping @Sendable (HTTPStreamEvent) throws -> Void) async throws {
        let response = try await send(request)
        try receive(.response(statusCode: response.statusCode, contentType: nil))
        try receive(.bytes(response.data))
    }
}

public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 360
        config.timeoutIntervalForResource = 420
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }
    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ImageAgentError.invalidInput("服务未返回 HTTP 响应。") }
        return .init(data: data, statusCode: response.statusCode)
    }
    public func stream(_ request: URLRequest, receive: @escaping @Sendable (HTTPStreamEvent) throws -> Void) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw ImageAgentError.invalidInput("服务未返回 HTTP 响应。") }
        defer { bytes.task.cancel() }
        try receive(.response(statusCode: response.statusCode, contentType: response.value(forHTTPHeaderField: "Content-Type")))
        var chunk = Data(); chunk.reserveCapacity(4096)
        for try await byte in bytes {
            chunk.append(byte)
            // A line is enough to deliver complete SSE frames immediately; never buffer the body.
            if byte == 10 || chunk.count >= 4096 { try receive(.bytes(chunk)); chunk.removeAll(keepingCapacity: true) }
        }
        if !chunk.isEmpty { try receive(.bytes(chunk)) }
    }
}

public struct APIError: LocalizedError, Sendable {
    public let statusCode: Int?
    public let message: String
    public var errorDescription: String? { message }
}
public struct ToolCall: Sendable {
    public let name: String
    public let callID: String
    public let arguments: String
}
public struct ResponseResult: Sendable {
    public let output: [JSONValue]
    public let status: String?
    public let failureDetail: String?
    public init(output: [JSONValue], status: String? = nil, failureDetail: String? = nil) {
        self.output = output; self.status = status; self.failureDetail = failureDetail
    }
    public static func decode(_ data: Data) throws -> ResponseResult {
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let output = json["output"]?.array else { throw ImageAgentError.invalidInput("规划模型未返回有效的 Responses output。") }
        return .init(output: output, status: json["status"]?.string, failureDetail: json["incomplete_details"]?["reason"]?.string ?? json["error"]?["message"]?.string)
    }
    public var nativeImageOutputs: [JSONValue] { output.filter { $0["type"]?.string == "image_generation_call" } }
    public func recoverBase64ImageOutput() -> NativeImageRecovery {
        var images: [DecodedImage] = []
        var failures: [String] = []
        for (index, item) in nativeImageOutputs.enumerated() {
            guard var base64 = item["result"]?.string, !base64.isEmpty else {
                failures.append("内置图片输出 \(index + 1) 未包含可恢复的图片字节。")
                continue
            }
            if base64.hasPrefix("data:image/"), let comma = base64.firstIndex(of: ",") { base64 = String(base64[base64.index(after: comma)...]) }
            base64.removeAll(where: \.isWhitespace)
            guard let bytes = Data(base64Encoded: base64) else { failures.append("内置图片输出 \(index + 1) 的 Base64 无效。"); continue }
            guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  CGImageSourceGetStatus(source) == .statusComplete,
                  CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
                  Self.hasCompletePNGEnvelope(bytes) else {
                failures.append("内置图片输出 \(index + 1) 的图片字节不完整。")
                continue
            }
            do { images.append(try DecodedImage(data: bytes)) }
            catch { failures.append("内置图片输出 \(index + 1) 无法解码为有效图片。") }
        }
        return .init(images: images, failures: failures)
    }
    private static func hasCompletePNGEnvelope(_ bytes: Data) -> Bool {
        guard bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { return true }
        // ImageIO may report a complete, renderable image even without the terminal IEND.
        // Walk chunk lengths rather than looking for IEND bytes inside compressed pixel data.
        var offset = 8
        while offset <= bytes.count - 12 {
            let length = (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(bytes[offset + $1]) }
            guard Int(length) <= bytes.count - offset - 12 else { return false }
            if bytes[(offset + 4)..<(offset + 8)].elementsEqual([73, 69, 78, 68]) { return length == 0 }
            offset += Int(length) + 12
        }
        return false
    }
    public var text: String {
        output.flatMap { item -> [String] in
            guard item["type"]?.string == "message" else { return [] }
            return (item["content"]?.array ?? []).compactMap {
                if $0["type"]?.string == "output_text" { return $0["text"]?.string }
                if $0["type"]?.string == "refusal" { return $0["refusal"]?.string }
                return nil
            }
        }.joined(separator: "\n")
    }
    public var toolCalls: [ToolCall] {
        output.compactMap { item in
            guard item["type"]?.string == "function_call" else { return nil }
            return .init(name: item["name"]?.string ?? "", callID: item["call_id"]?.string ?? "", arguments: item["arguments"]?.string ?? "")
        }
    }
}

public struct NativeImageRecovery: Sendable {
    public let images: [DecodedImage]
    public let failures: [String]
}

public final class APIClient: @unchecked Sendable {
    public let endpoint: ServiceEndpoint
    public static let plannerModel = PlannerModel.default
    public let selectedPlannerModel: String
    private let apiKey: String
    private let transport: any HTTPTransport
    public init(baseURL: String, apiKey: String, plannerModel: String = APIClient.plannerModel, transport: any HTTPTransport = URLSessionTransport()) throws {
        endpoint = try ServiceEndpoint(baseURL)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains("\n"), !key.contains("\r") else { throw ImageAgentError.credential("请输入有效的 API Key。") }
        self.apiKey = key; self.transport = transport
        selectedPlannerModel = try PlannerModel.validated(plannerModel)
        guard !modelIDContainsCredential(selectedPlannerModel) else {
            throw ImageAgentError.invalidInput("规划模型 ID 不能包含 API 凭据。")
        }
    }
    public func safeDescription(_ error: Error) -> String { redact(error.localizedDescription) }
    public func sanitized(_ text: String) -> String { redact(text, limit: nil) }
    private func modelIDContainsCredential(_ id: String) -> Bool {
        if id.contains(apiKey) { return true }
        // Token boundaries keep embedded words such as task-planner valid.
        let tokens = #"(?<![\p{L}\p{N}_-])(?:sk-[A-Za-z0-9_-]{6,}(?![\p{L}\p{N}_-])|(?i:Bearer)\s+[^\s\"'<>]+)"#
        return id.range(of: tokens, options: .regularExpression) != nil
    }
    private func redact(_ input: String, limit: Int? = 800) -> String {
        var output = input.replacingOccurrences(of: apiKey, with: "[已隐藏]")
        output = output.replacingOccurrences(of: #"(?i)Bearer\s+[^\s\"'<>]+"#, with: "Bearer [已隐藏]", options: .regularExpression)
        output = output.replacingOccurrences(of: #"sk-[A-Za-z0-9_\-]{6,}"#, with: "[已隐藏]", options: .regularExpression)
        return limit.map { String(output.prefix($0)) } ?? output
    }
    private func request(path: String, method: String = "POST", timeout: TimeInterval = 90) -> URLRequest {
        var request = URLRequest(url: endpoint.url(path))
        request.httpMethod = method; request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
    private func send(_ request: URLRequest) async throws -> Data {
        do {
            let response = try await transport.send(request)
            guard (200..<300).contains(response.statusCode) else {
                let json = try? JSONDecoder().decode(JSONValue.self, from: response.data)
                let detail = json?["error"]?["message"]?.string ?? json?["message"]?.string ?? "服务请求失败"
                let hint: String
                switch response.statusCode {
                case 401, 403: hint = "请检查此服务的 API Key 和访问权限。"
                case 429: hint = "服务限流或额度不足，请稍后手动重试。"
                case 404: hint = "请检查 API 地址及所选模型是否可用。"
                default: hint = "请求未自动重试。"
                }
                throw APIError(statusCode: response.statusCode, message: "HTTP \(response.statusCode)：\(redact(detail))\n\(hint)")
            }
            return response.data
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as APIError { throw error }
        catch {
            throw APIError(statusCode: nil, message: "网络请求失败：\(redact(error.localizedDescription))。请求未自动重试。")
        }
    }
    public func validateConnection() async throws -> [String] {
        let data = try await send(request(path: "models", method: "GET", timeout: 30))
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let models = json["data"]?.array else { throw ImageAgentError.invalidInput("模型列表格式无效，请检查服务地址。") }
        return models.compactMap {
            guard let id = $0["id"]?.string, !id.isEmpty, id.count <= 200,
                  id == id.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !modelIDContainsCredential(id) else { return nil }
            return id
        }
    }
    public func respond(input: [JSONValue], selection: ImageSelection, promptPreview: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ResponseResult {
        var request = request(path: "responses", timeout: 120)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        var body: [String: JSONValue] = [
            "model": .string(selectedPlannerModel), "store": .bool(false), "input": .array(input),
            "tools": .array(Self.tools(selection: selection)), "parallel_tool_calls": .bool(false),
            "tool_choice": .object(["type": .string("function"), "name": .string("prepare_image_request")]),
            "max_output_tokens": .number(4096)
        ]
        if selectedPlannerModel == Self.plannerModel { body["reasoning"] = .object(["effort": .string("low")]) }
        body["stream"] = .bool(true)
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        let consumer = PlannerStreamConsumer()
        do {
            try await transport.stream(request) { event in
                for text in try consumer.receive(event) {
                    consumer.publish(self.streamingPreview(text), to: promptPreview)
                }
            }
            if let status = consumer.statusCode, !(200..<300).contains(status) {
                let json = try? JSONDecoder().decode(JSONValue.self, from: consumer.errorBody)
                let detail = json?["error"]?["message"]?.string ?? json?["message"]?.string ?? "服务请求失败"
                throw APIError(statusCode: status, message: "HTTP \(status)：\(redact(detail))。请求未自动重试。")
            }
            guard consumer.statusCode != nil else { throw ImageAgentError.invalidInput("服务未返回 HTTP 响应。") }
            let result = try consumer.decoder.finish()
            for text in consumer.decoder.finalPreviews {
                // A successful complete response no longer needs speculative suffix withholding.
                consumer.publish(self.sanitized(text), to: promptPreview)
            }
            return result
        } catch {
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
            let partial = consumer.decoder.partialResponse
            if !partial.nativeImageOutputs.isEmpty {
                throw ResponseStreamError(partialResponse: partial, wasCancelled: cancelled, message: cancelled ? "规划流已取消；已收到的图片会保留。" : "规划流未完成：\(redact(error.localizedDescription))。请求未自动重试。")
            }
            if cancelled { throw CancellationError() }
            if let error = error as? APIError { throw error }
            throw APIError(statusCode: nil, message: "规划流未完成：\(redact(error.localizedDescription))。请求未自动重试。")
        }
    }
    /// Withhold a suffix that could be the start of a credential until the next real fragment.
    private func streamingPreview(_ input: String) -> String {
        // Hide complete credentials before a generic prefix rule can trim their last character.
        var visible = redact(input, limit: nil)
        for token in [apiKey, "Bearer", "sk-"] where !token.isEmpty {
            let lower = token == apiKey ? visible : visible.lowercased()
            let comparison = token == apiKey ? token : token.lowercased()
            let limit = min(comparison.count - 1, lower.count)
            if limit > 0 {
                for length in stride(from: limit, through: 1, by: -1) where lower.hasSuffix(String(comparison.prefix(length))) {
                    visible = String(visible.dropLast(length)); break
                }
            }
        }
        visible = redact(visible, limit: nil)
        visible = visible.replacingOccurrences(of: #"(?i)Bearer\s+[^\s\"'<>]*"#, with: "Bearer [已隐藏]", options: .regularExpression)
        return visible.replacingOccurrences(of: #"(?i)sk-[A-Za-z0-9_\-]*"#, with: "[已隐藏]", options: .regularExpression)
    }
    public static func tools(selection: ImageSelection) -> [JSONValue] {
        let properties: [String: JSONValue] = [
            "action": .object(["type": .string("string"), "enum": .array(["generate", "edit", "reply"].map(JSONValue.string))]),
            "prompt": .object(["type": .string("string"), "description": .string("完整图片提示词。action=reply 时填写空字符串。")]),
            "model": .object(["type": .string("string"), "enum": .array([.string(selection.model.rawValue)])]),
            "size": .object(["type": .string("string"), "enum": .array([.string(selection.size.rawValue)])]),
            "quality": .object(["type": .string("string"), "enum": .array([.string(selection.quality.rawValue)])]),
            "reference_image_id": .object(["type": .array([.string("string"), .string("null")]), "description": .string("edit 必须填当前有效参考图 ID；generate 填 null。")]),
            "reply_text": .object(["type": .string("string"), "description": .string("reply 时填写完整讨论回复；图片任务填写简洁作品说明，图片完成保存后才展示。")])
        ]
        return [.object([
            "type": .string("function"), "name": .string("prepare_image_request"), "strict": .bool(true),
            "description": .string("只规划图片任务或普通讨论，不生成图片。App 校验后执行固定的生成/编辑操作。"),
            "parameters": .object(["type": .string("object"), "properties": .object(properties), "required": .array(["action", "prompt", "model", "size", "quality", "reference_image_id", "reply_text"].map(JSONValue.string)), "additionalProperties": .bool(false)])
        ])]
    }
    public func generate(prompt: String, selection: ImageSelection) async throws -> DecodedImage {
        var request = request(path: "images/generations", timeout: 360)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(JSONValue.object([
            "model": .string(selection.model.rawValue), "prompt": .string(prompt), "size": .string(selection.size.rawValue), "quality": .string(selection.quality.rawValue), "n": .number(1)
        ]))
        return try await decodeImageResponse(send(request))
    }
    public func edit(prompt: String, selection: ImageSelection, reference: Data, mask: Data? = nil) async throws -> DecodedImage {
        let image = try DecodedImage(data: reference)
        if let mask {
            let decoded = try DecodedImage(data: mask)
            guard decoded.mediaType == "image/png", decoded.width == image.width, decoded.height == image.height,
                  mask.count < 4 * 1024 * 1024,
                  let source = CGImageSourceCreateWithData(mask as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  [.first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly].contains(cgImage.alphaInfo) else {
                throw ImageAgentError.invalidInput("编辑遮罩必须是小于 4MB、与参考图同尺寸且带 alpha 的 PNG。")
            }
        }
        let boundary = "ImageAgent-\(UUID().uuidString)"
        var body = Data()
        func append(_ value: String) { body.append(Data(value.utf8)) }
        let fields = [("model", selection.model.rawValue), ("prompt", prompt), ("size", selection.size.rawValue), ("quality", selection.quality.rawValue), ("n", "1")]
        for (name, value) in fields {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"reference.\(image.fileExtension)\"\r\nContent-Type: \(image.mediaType)\r\n\r\n")
        body.append(reference); append("\r\n")
        if let mask {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"mask\"; filename=\"mask.png\"\r\nContent-Type: image/png\r\n\r\n")
            body.append(mask); append("\r\n")
        }
        append("--\(boundary)--\r\n")
        var request = request(path: "images/edits", timeout: 360)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await decodeImageResponse(send(request))
    }
    private func decodeImageResponse(_ data: Data) async throws -> DecodedImage {
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let first = json["data"]?.array?.first else { throw ImageAgentError.invalidImage("图片服务未返回图片数据。") }
        if let base64 = first["b64_json"]?.string {
            guard let data = Data(base64Encoded: base64) else { throw ImageAgentError.invalidImage("图片服务返回的 Base64 数据无效。") }
            return try DecodedImage(data: data)
        }
        if let address = first["url"]?.string, let url = URL(string: address), url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil {
            var download = URLRequest(url: url); download.timeoutInterval = 120
            // A result URL can be a different service: never attach the API key to it.
            return try DecodedImage(data: await send(download))
        }
        throw ImageAgentError.invalidImage("图片服务未返回有效 Base64 或 HTTPS 图片地址。")
    }
}
