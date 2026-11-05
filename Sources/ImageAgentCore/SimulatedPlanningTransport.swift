import Foundation

/// Explicitly offline QA transport. It has no network/credential dependencies, and delivers
/// real SSE chunks through the same parser used by the production planner.
public actor SimulatedPlanningTransport: HTTPTransport {
    public static let prompt = "一幅温暖而安静的山间湖泊插画。清晨的金色光线从右上方洒落，层叠远山映在平静湖面上。岸边是一间赭红色的小屋，周围点缀深绿色松树与轻薄晨雾。采用奶油色、森林绿与柔和暖橙配色，保留纸张颗粒质感和舒展留白。构图简洁，主体清楚，没有文字、水印或边框。"
    private let imageData: Data
    private let selection: ImageSelection
    private let delay: Duration
    private let interrupt: Bool
    private var plans = 0
    private var images = 0
    public init(imageData: Data, selection: ImageSelection = .init(), delay: Duration = .milliseconds(900), interruptAfterPreview: Bool = false) {
        self.imageData = imageData; self.selection = selection; self.delay = delay; interrupt = interruptAfterPreview
    }
    public func statistics() -> (plans: Int, images: Int) { (plans, images) }
    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard request.url?.path == "/v1/images/generations", images == 0 else { throw ImageAgentError.invalidInput("离线演示禁止其他端点或重复图片请求。") }
        images += 1
        let data = try JSONEncoder().encode(JSONValue.object(["data": .array([.object(["b64_json": .string(imageData.base64EncodedString())])])]))
        return .init(data: data, statusCode: 200)
    }
    public func stream(_ request: URLRequest, receive: @escaping @Sendable (HTTPStreamEvent) throws -> Void) async throws {
        guard request.url?.path == "/v1/responses", plans == 0 else { throw ImageAgentError.invalidInput("离线演示仅允许一次模拟规划。") }
        plans += 1
        try receive(.response(statusCode: 200, contentType: "text/event-stream"))
        let base: [String: JSONValue] = ["type": .string("function_call"), "id": .string("demo_function"), "call_id": .string("demo_call"), "name": .string("prepare_image_request")]
        var added = base; added["arguments"] = .string("")
        try receive(.bytes(event("response.output_item.added", ["output_index": .number(0), "item": .object(added)])))
        let encodedPrompt = try JSONValue.string(Self.prompt).encodedString()
        let suffix: JSONValue = .object(["action": .string("generate"), "model": .string(selection.model.rawValue), "size": .string(selection.size.rawValue),
            "quality": .string(selection.quality.rawValue), "reference_image_id": .null, "reply_text": .string("离线模拟已完成，没有访问网络或钥匙串。")])
        let arguments = "{\"prompt\":" + encodedPrompt + "," + (try suffix.encodedString()).dropFirst()
        let scalars = Array(arguments.unicodeScalars)
        let chunkSize = max(1, Self.prompt.unicodeScalars.count / 6)
        var offset = 0
        var delivered = 0
        while offset < scalars.count {
            try Task.checkCancellation()
            if delay > .zero { try await Task.sleep(for: delay) }
            let end = min(scalars.count, offset + chunkSize)
            let chunk = String(String.UnicodeScalarView(scalars[offset..<end]))
            try receive(.bytes(event("response.function_call_arguments.delta", ["item_id": .string("demo_function"), "output_index": .number(0), "delta": .string(chunk)])))
            offset = end; delivered += 1
            if interrupt, delivered == 5 { throw ImageAgentError.invalidInput("离线模拟：规划流中断。未调用图片接口。") }
        }
        var final = base; final["arguments"] = .string(arguments)
        try receive(.bytes(event("response.completed", ["response": .object(["status": .string("completed"), "output": .array([.object(final)])])])))
        try receive(.bytes(Data("data: [DONE]\n\n".utf8)))
    }
    private func event(_ type: String, _ fields: [String: JSONValue]) throws -> Data {
        var fields = fields; fields["type"] = .string(type)
        return Data(("data: " + (try JSONValue.object(fields).encodedString()) + "\n\n").utf8)
    }
}
