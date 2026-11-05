import Foundation

/// Carries already-received native outputs through transport/parser failure to local recovery.
public struct ResponseStreamError: LocalizedError, Sendable {
    public let partialResponse: ResponseResult
    public let wasCancelled: Bool
    public let message: String
    public var errorDescription: String? { message }
}

/// Used by one serial transport callback. No durable state or UI work happens per fragment.
final class PlannerStreamConsumer: @unchecked Sendable {
    let decoder = ResponsesStreamDecoder()
    private(set) var statusCode: Int?
    private(set) var errorBody = Data()
    private var publishedPreview = ""
    func publish(_ text: String, to callback: @Sendable (String) -> Void) {
        guard !text.isEmpty, text != publishedPreview else { return }
        publishedPreview = text; callback(text)
    }
    func receive(_ event: HTTPStreamEvent) throws -> [String] {
        switch event {
        case .response(let status, _):
            guard statusCode == nil else { throw invalidStream("重复 HTTP 响应头") }
            statusCode = status
            return []
        case .bytes(let data):
            guard let statusCode else { throw invalidStream("缺少 HTTP 响应头") }
            guard (200..<300).contains(statusCode) else {
                errorBody.append(data.prefix(max(0, 65_536 - errorBody.count)))
                return []
            }
            return try decoder.append(data)
        }
    }
}

private func invalidStream(_ detail: String) -> ImageAgentError {
    .invalidInput("规划响应流无效（\(detail)）；未执行图片请求。")
}

/// Byte framing is independent of UTF-8 decoding: only complete SSE data fields are decoded.
/// Large native-image events have a separate bounded budget so the image decoder's 100 MiB
/// accepted payload remains recoverable. Ordinary events and function arguments stay small.
final class ResponsesStreamDecoder: @unchecked Sendable {
    private static let ordinaryEventLimit = 262_144
    private static let nativeEventLimit = 145 * 1024 * 1024
    private static let streamLimit = 384 * 1024 * 1024
    private enum Format { case undecided, json, sse }
    private var format = Format.undecided
    private var totalBytes = 0
    private var line = Data()
    private var eventData = Data()
    private var eventName: String?
    private var jsonBody = Data()
    private var terminal: ResponseResult?
    private var native: [JSONValue] = []
    private var items: [Int: StreamItem] = [:]
    private var doneMarker = false
    private var lastPreview = ""
    private(set) var finalPreviews: [String] = []

    private struct StreamItem {
        let id: String
        let kind: String
        let name: String
        let callID: String
        var arguments = ""
        var scanner = PromptArgumentScanner()
        var argumentsDone = false
    }

    var partialResponse: ResponseResult {
        // A transport can fail after delivering a complete JSON body. Salvage only native
        // outputs for recovery; this snapshot must not accept a terminal state or tool plan.
        let bufferedNative = format == .json && terminal == nil
            ? (try? ResponseResult.decode(jsonBody))?.nativeImageOutputs ?? [] : []
        var output: [JSONValue] = []
        for item in (terminal?.output ?? []) + native + bufferedNative {
            if item["type"]?.string != "image_generation_call" || !output.contains(where: { equivalentNative(item, $0) }) { output.append(item) }
        }
        return .init(output: output, status: terminal?.status, failureDetail: terminal?.failureDetail)
    }

    func append(_ data: Data) throws -> [String] {
        totalBytes += data.count
        guard totalBytes <= Self.streamLimit else { throw invalidStream("响应超过大小上限") }
        var previews: [String] = []
        for byte in data {
            if format == .undecided {
                if [9, 10, 13, 32].contains(byte) { continue }
                format = byte == 123 || byte == 91 ? .json : .sse
            }
            if format == .json {
                guard jsonBody.count < Self.nativeEventLimit else { throw invalidStream("JSON 响应过大") }
                jsonBody.append(byte)
            } else if byte == 10 {
                previews += try consumeLine()
            } else {
                guard line.count + eventData.count < Self.nativeEventLimit else { throw invalidStream("事件超过大小上限") }
                line.append(byte)
            }
        }
        return previews
    }

    func finish() throws -> ResponseResult {
        finalPreviews = []
        if format == .json {
            if terminal == nil {
                let response = try ResponseResult.decode(jsonBody)
                captureNative(response.output)
                terminal = response
                if response.nativeImageOutputs.isEmpty, jsonBody.count > Self.ordinaryEventLimit { throw invalidStream("普通 JSON 响应过大") }
            }
        } else {
            if !line.isEmpty { finalPreviews += try consumeLine() }
            if !eventData.isEmpty { finalPreviews += try consumeEvent() }
        }
        let result = try successfulTerminal()
        if let terminal { finalPreviews = try previewFromFinal(terminal, force: true) }
        return result
    }

    private func successfulTerminal() throws -> ResponseResult {
        guard let terminal, terminal.status == "completed" else {
            throw invalidStream(terminal?.failureDetail ?? terminal?.status ?? "未收到完整的 completed 响应")
        }
        return partialResponse
    }

    private func consumeLine() throws -> [String] {
        if line.last == 13 { line.removeLast() }
        defer { line.removeAll(keepingCapacity: line.count < Self.ordinaryEventLimit) }
        if line.isEmpty { return try consumeEvent() }
        guard let text = String(data: line, encoding: .utf8) else { throw invalidStream("UTF-8 无效") }
        if text.hasPrefix(":") { return [] }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var value = parts.count == 2 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch field {
        case "data":
            guard eventData.count + value.utf8.count + 1 <= Self.nativeEventLimit else { throw invalidStream("事件超过大小上限") }
            if !eventData.isEmpty { eventData.append(10) }
            eventData.append(contentsOf: value.utf8)
        case "event": eventName = value
        case "id", "retry": break
        default: throw invalidStream("未知 SSE 字段")
        }
        return []
    }

    private func consumeEvent() throws -> [String] {
        defer { eventData.removeAll(keepingCapacity: eventData.count < Self.ordinaryEventLimit); eventName = nil }
        guard !eventData.isEmpty else { return [] }
        if eventData == Data("[DONE]".utf8) { doneMarker = true; return [] }
        guard !doneMarker else { throw invalidStream("DONE 后仍有响应事件") }
        let event = try JSONDecoder().decode(JSONValue.self, from: eventData)
        guard let type = event["type"]?.string, eventName == nil || eventName == type else { throw invalidStream("事件类型不一致") }
        let nativeEvent = event["item"]?["type"]?.string == "image_generation_call" ||
            (event["response"]?["output"]?.array ?? []).contains { $0["type"]?.string == "image_generation_call" }
        guard eventData.count <= Self.ordinaryEventLimit || nativeEvent else { throw invalidStream("普通事件过大") }
        guard terminal == nil else { throw invalidStream("终态后仍有响应事件") }
        switch type {
        case "response.output_item.added", "response.output_item.done":
            guard let item = event["item"], let index = index(event), let kind = item["type"]?.string else { throw invalidStream("输出条目缺少标识") }
            if kind == "image_generation_call" { captureNative([item]) }
            let id = item["id"]?.string ?? ""
            guard !id.isEmpty, id.count < 256, items.count < 64 || items[index] != nil else { throw invalidStream("输出条目标识无效") }
            let name = item["name"]?.string ?? ""
            let callID = item["call_id"]?.string ?? ""
            if let previous = items[index] {
                guard previous.id == id, previous.kind == kind, previous.name == name, previous.callID == callID else { throw invalidStream("输出条目标识改变") }
            } else {
                guard !items.values.contains(where: { $0.id == id }) else { throw invalidStream("输出条目标识重复") }
                items[index] = .init(id: id, kind: kind, name: name, callID: callID)
            }
            if kind == "function_call", let arguments = item["arguments"]?.string, !arguments.isEmpty {
                return try updateArguments(arguments, index: index, complete: type.hasSuffix(".done"), replacement: true)
            }
            return []
        case "response.function_call_arguments.delta", "response.function_call_arguments.done":
            guard let index = index(event), let item = items[index], item.id == event["item_id"]?.string, item.kind == "function_call" else { throw invalidStream("函数参数不属于已知条目") }
            if item.name != "prepare_image_request" { return [] }
            let complete = type.hasSuffix(".done")
            guard let arguments = event[complete ? "arguments" : "delta"]?.string else { throw invalidStream("缺少函数参数片段") }
            return try updateArguments(arguments, index: index, complete: complete, replacement: complete)
        case "response.completed", "response.failed", "response.incomplete":
            guard let response = event["response"], let output = response["output"]?.array else { throw invalidStream("终态缺少完整响应") }
            captureNative(output)
            let expected = String(type.dropFirst("response.".count))
            terminal = .init(output: output, status: response["status"]?.string, failureDetail: response["incomplete_details"]?["reason"]?.string ?? response["error"]?["message"]?.string)
            guard terminal?.status == expected else { throw invalidStream("终态与响应状态不一致") }
            if expected == "completed" { return try previewFromFinal(terminal!) }
            return []
        case "error": throw invalidStream(event["message"]?.string ?? "服务返回错误事件")
        default: return [] // Text, reasoning, encrypted data and unrelated events are never previews.
        }
    }

    private func index(_ event: JSONValue) -> Int? {
        guard case .number(let value) = event["output_index"], value.isFinite, value >= 0, value < 64, value.rounded() == value else { return nil }
        return Int(value)
    }

    private func updateArguments(_ fragment: String, index: Int, complete: Bool, replacement: Bool) throws -> [String] {
        guard var item = items[index] else { throw invalidStream("未知函数条目") }
        guard !item.argumentsDone || (replacement && fragment == item.arguments) else { throw invalidStream("完整参数后仍有片段") }
        let addition: String
        if replacement {
            guard item.arguments.isEmpty || fragment == item.arguments else { throw invalidStream("完整参数与增量不一致") }
            addition = item.arguments.isEmpty ? fragment : ""
        } else { addition = fragment }
        guard item.arguments.utf8.count + addition.utf8.count <= 200_000 else { throw invalidStream("函数参数过大") }
        item.arguments += addition; item.argumentsDone = complete
        if item.name == "prepare_image_request" { try item.scanner.append(addition) }
        items[index] = item
        return changedPreview(item.scanner.prompt)
    }

    private func previewFromFinal(_ response: ResponseResult, force: Bool = false) throws -> [String] {
        guard response.toolCalls.count == 1, response.toolCalls[0].name == "prepare_image_request" else { return [] }
        if !items.isEmpty {
            for (index, tracked) in items where tracked.kind == "function_call" {
                guard response.output.indices.contains(index) else { throw invalidStream("完整响应缺少函数条目") }
                let final = response.output[index]
                guard final["id"]?.string == tracked.id, final["name"]?.string == tracked.name,
                      final["call_id"]?.string == tracked.callID,
                      tracked.arguments.isEmpty || final["arguments"]?.string == tracked.arguments else { throw invalidStream("完整响应与函数增量不一致") }
            }
        }
        var scanner = PromptArgumentScanner()
        let arguments = response.toolCalls[0].arguments
        guard arguments.utf8.count <= 200_000 else { throw invalidStream("函数参数过大") }
        try scanner.append(arguments)
        if force { return scanner.prompt.isEmpty ? [] : [scanner.prompt] }
        return changedPreview(scanner.prompt)
    }

    private func changedPreview(_ text: String) -> [String] {
        guard !text.isEmpty, text != lastPreview else { return [] }
        lastPreview = text
        return [text]
    }
    private func captureNative(_ output: [JSONValue]) {
        for item in output where item["type"]?.string == "image_generation_call" {
            guard !native.contains(where: { equivalentNative(item, $0) }) else { continue }
            if let id = item["id"]?.string, let index = native.firstIndex(where: { $0["id"]?.string == id }) {
                if ResponseResult(output: [native[index]]).recoverBase64ImageOutput().images.isEmpty {
                    native[index] = item; continue
                }
                // Preserve every different complete result, even if the provider reuses its ID.
                if ResponseResult(output: [item]).recoverBase64ImageOutput().images.isEmpty { continue }
            }
            native.append(item)
        }
    }
    private func equivalentNative(_ first: JSONValue, _ second: JSONValue) -> Bool {
        guard second["type"]?.string == "image_generation_call" else { return false }
        if first["id"] == second["id"], first["result"] == second["result"] { return true }
        guard let firstBytes = nativeBytes(first), let secondBytes = nativeBytes(second) else { return false }
        return firstBytes == secondBytes
    }
    private func nativeBytes(_ item: JSONValue) -> Data? {
        guard var base64 = item["result"]?.string else { return nil }
        if base64.hasPrefix("data:image/"), let comma = base64.firstIndex(of: ",") { base64 = String(base64[base64.index(after: comma)...]) }
        base64.removeAll(where: \.isWhitespace)
        return Data(base64Encoded: base64)
    }
}

/// Only a top-level `prompt` JSON string is decoded. The final strict plan is validated elsewhere.
private struct PromptArgumentScanner {
    private var stack: [Unicode.Scalar] = []
    private var expectsKey = false
    private var expectsValue = false
    private var key: String?
    private var keys: Set<String> = []
    private enum Role { case key, prompt, ignored }
    private var role: Role?
    private var string = JSONStringPrefixDecoder()
    private(set) var prompt = ""
    mutating func append(_ fragment: String) throws {
        for scalar in fragment.unicodeScalars {
            if let role {
                let ended = try string.append(scalar)
                if ended {
                    if role == .prompt { prompt = string.text }
                    if role == .key {
                        guard keys.insert(string.text).inserted else { throw invalidStream("重复的顶层参数") }
                        key = string.text; expectsKey = false
                    }
                    self.role = nil; expectsValue = false
                }
                continue
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            if scalar == "\"" {
                role = stack.count == 1 && expectsKey ? .key : (stack.count == 1 && expectsValue && key == "prompt" ? .prompt : .ignored)
                string = JSONStringPrefixDecoder()
            } else if scalar == "{" || scalar == "[" {
                if stack.isEmpty, scalar != "{" { throw invalidStream("函数参数不是对象") }
                if expectsValue, key == "prompt", stack.count == 1 { throw invalidStream("prompt 不是字符串") }
                stack.append(scalar)
                if stack.count == 1 { expectsKey = true }
            } else if scalar == "}" || scalar == "]" {
                guard let opening = stack.popLast(), (opening == "{" && scalar == "}") || (opening == "[" && scalar == "]") else { throw invalidStream("函数参数括号不匹配") }
            } else if scalar == ":", stack.count == 1 { expectsValue = true }
            else if scalar == ",", stack.count == 1 { expectsKey = true; expectsValue = false; key = nil }
            else if expectsValue, key == "prompt", stack.count == 1 { throw invalidStream("prompt 不是字符串") }
        }
        if role == .prompt { prompt = string.text }
        guard prompt.utf8.count <= 128_000, prompt.count <= 32_000 else { throw invalidStream("提示词超过长度上限") }
    }
}

/// Holds incomplete escapes and high surrogates, so no replacement characters reach the preview.
private struct JSONStringPrefixDecoder {
    private enum State { case normal, escape, unicode, lowSlash, lowU, lowUnicode }
    private var state = State.normal
    private var digits = ""
    private var high: UInt32 = 0
    private(set) var text = ""
    mutating func append(_ scalar: Unicode.Scalar) throws -> Bool {
        switch state {
        case .normal:
            if scalar == "\"" { return true }
            if scalar == "\\" { state = .escape }
            else { guard scalar.value >= 32 else { throw invalidStream("JSON 字符串含控制字符") }; text.unicodeScalars.append(scalar) }
        case .escape:
            state = .normal
            switch scalar {
            case "\"", "\\", "/": text.unicodeScalars.append(scalar)
            case "n": text.append("\n")
            case "r": text.append("\r")
            case "t": text.append("\t")
            case "b": text.append("\u{8}")
            case "f": text.append("\u{c}")
            case "u": state = .unicode; digits = ""
            default: throw invalidStream("JSON 转义无效")
            }
        case .unicode, .lowUnicode:
            guard scalar.isASCII, scalar.properties.isHexDigit else { throw invalidStream("Unicode 转义无效") }
            digits.unicodeScalars.append(scalar)
            if digits.count == 4 {
                guard let value = UInt32(digits, radix: 16) else { throw invalidStream("Unicode 转义无效") }
                if state == .lowUnicode {
                    guard (0xDC00...0xDFFF).contains(value), let decoded = Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + value - 0xDC00) else { throw invalidStream("Unicode 代理对无效") }
                    text.unicodeScalars.append(decoded); state = .normal
                } else if (0xD800...0xDBFF).contains(value) { high = value; state = .lowSlash }
                else {
                    guard let decoded = Unicode.Scalar(value), !(0xDC00...0xDFFF).contains(value) else { throw invalidStream("Unicode 代理对无效") }
                    text.unicodeScalars.append(decoded); state = .normal
                }
            }
        case .lowSlash:
            guard scalar == "\\" else { throw invalidStream("缺少 Unicode 低代理项") }; state = .lowU
        case .lowU:
            guard scalar == "u" else { throw invalidStream("缺少 Unicode 低代理项") }; state = .lowUnicode; digits = ""
        }
        guard text.utf8.count <= 200_000 else { throw invalidStream("JSON 字符串过大") }
        return false
    }
}
