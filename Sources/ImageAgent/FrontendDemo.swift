import Foundation
import ImageAgentCore

/// The dedicated QA mode stores endpoint markers, never the value entered in its Key field.
/// It cannot access Keychain, and its transport has no URLSession/network implementation.
final class FrontendDemoCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    init(root: URL) { url = root.appendingPathComponent("offline-credential-markers.json") }
    private func markers() throws -> [String: Bool] {
        if !FileManager.default.fileExists(atPath: url.path) { return [AppSettings().endpoint: true] }
        return try JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: url))
    }
    func key(for endpoint: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return try markers()[endpoint] == true ? "offline-demo-placeholder" : nil
    }
    func save(_ key: String, for endpoint: String) throws {
        lock.lock(); defer { lock.unlock() }
        var saved = try markers(); saved[endpoint] = true; try write(saved)
    }
    func delete(for endpoint: String) throws {
        lock.lock(); defer { lock.unlock() }
        var saved = try markers(); saved[endpoint] = nil; try write(saved)
    }
    private func write(_ saved: [String: Bool]) throws {
        try JSONEncoder().encode(saved).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
actor FrontendDemoTransport: HTTPTransport {
    private var image = Data()
    func setImage(_ data: Data) { image = data }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard let path = request.url?.path else { throw ImageAgentError.invalidInput("离线演示端点无效。") }
        if request.url?.host == "offline-network-failure.invalid" { throw URLError(.notConnectedToInternet) }
        if path.hasSuffix("/models") {
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer fail" {
                return .init(data: Data(#"{"error":{"message":"离线模拟：Key 验证失败"}}"#.utf8), statusCode: 401)
            }
            let ids = [PlannerModel.default, "gpt-6-sol"] + ImageModel.allCases.map(\.rawValue)
            return .init(data: try JSONEncoder().encode(JSONValue.object(["data": .array(ids.map { .object(["id": .string($0)]) })])), statusCode: 200)
        }
        guard path.hasSuffix("/images/generations") || path.hasSuffix("/images/edits"), !image.isEmpty else {
            throw ImageAgentError.invalidInput("离线演示禁止这个端点；没有访问网络。")
        }
        return .init(data: try JSONEncoder().encode(JSONValue.object(["data": .array([.object(["b64_json": .string(image.base64EncodedString())])])])), statusCode: 200)
    }
    func stream(_ request: URLRequest, receive: @escaping @Sendable (HTTPStreamEvent) throws -> Void) async throws {
        guard request.url?.path.hasSuffix("/responses") == true, let body = request.httpBody else {
            throw ImageAgentError.invalidInput("离线演示只接受模拟规划；没有访问网络。")
        }
        let json = try JSONDecoder().decode(JSONValue.self, from: body)
        guard let properties = json["tools"]?.array?.first?["parameters"]?["properties"],
              let model = properties["model"]?["enum"]?.array?.first?.string,
              let size = properties["size"]?["enum"]?.array?.first?.string,
              let quality = properties["quality"]?["enum"]?.array?.first?.string else { throw ImageAgentError.invalidInput("离线规划缺少图片选择。") }
        let system = json["input"]?.array?.first?["content"]?.string ?? ""
        let reference = system.components(separatedBy: "主动选定的参考图：").dropFirst().first?.components(separatedBy: "。").first
        let selectedReference = reference.flatMap { $0.hasPrefix("无") ? nil : $0 }
        let suffix: JSONValue = .object(["action": .string(selectedReference == nil ? "generate" : "edit"), "model": .string(model), "size": .string(size), "quality": .string(quality),
            "reference_image_id": selectedReference.map(JSONValue.string) ?? .null, "reply_text": .string("离线模拟完成，没有访问网络或钥匙串。")])
        let arguments = "{\"prompt\":" + (try JSONValue.string(SimulatedPlanningTransport.prompt).encodedString()) + "," + (try suffix.encodedString()).dropFirst()
        let base: [String: JSONValue] = ["type": .string("function_call"), "id": .string("frontend_function"), "call_id": .string("frontend_call"), "name": .string("prepare_image_request")]
        try receive(.response(statusCode: 200, contentType: "text/event-stream"))
        var added = base; added["arguments"] = .string("")
        try receive(.bytes(event("response.output_item.added", ["output_index": .number(0), "item": .object(added)])))
        let scalars = Array(arguments.unicodeScalars)
        for offset in stride(from: 0, to: scalars.count, by: 50) {
            try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(500))
            let chunk = String(String.UnicodeScalarView(scalars[offset..<min(scalars.count, offset + 50)]))
            try receive(.bytes(event("response.function_call_arguments.delta", ["item_id": .string("frontend_function"), "output_index": .number(0), "delta": .string(chunk)])))
        }
        var completed = base; completed["arguments"] = .string(arguments)
        try receive(.bytes(event("response.completed", ["response": .object(["status": .string("completed"), "output": .array([.object(completed)])])])) )
        try receive(.bytes(Data("data: [DONE]\n\n".utf8)))
    }
    private func event(_ type: String, _ fields: [String: JSONValue]) throws -> Data {
        var value = fields; value["type"] = .string(type)
        return Data(("data: " + (try JSONValue.object(value).encodedString()) + "\n\n").utf8)
    }
}
