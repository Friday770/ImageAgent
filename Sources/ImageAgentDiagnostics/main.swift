import Foundation
import ImageAgentCore

struct DiagnosticEvent: Codable {
    let name: String
    let status: String
    let detail: String
    let imagePaths: [String]
}
struct DiagnosticReport: Codable {
    var application = "ImageAgent 1.5.0"
    var build = 8
    let createdAt: Date
    var status = "running"
    var endpoint: String?
    var events: [DiagnosticEvent] = []
}

final class Diagnostics {
    let arguments: [String]
    let output: URL
    let store: SQLiteStore
    var report: DiagnosticReport
    var client: APIClient?
    init(arguments: [String]) throws {
        self.arguments = arguments
        func option(_ name: String) -> String? { guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }; return arguments[index + 1] }
        let location = option("--output") ?? "artifacts/diagnostics-\(UUID().uuidString.lowercased())"
        output = URL(fileURLWithPath: location, isDirectory: true).standardizedFileURL
        store = try SQLiteStore(paths: AppPaths(root: output.appendingPathComponent("data")))
        try store.recoverInterruptedRuns()
        report = .init(createdAt: Date())
    }
    func option(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    func writeReport() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let destination = output.appendingPathComponent("report.json")
        try encoder.encode(report).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
    func record(_ name: String, status: String = "passed", detail: String, images: [AssetRecord] = []) throws {
        report.events.append(.init(name: name, status: status, detail: detail, imagePaths: try images.map { try store.assetURL($0).path }))
        try writeReport()
        print("\(name): \(status) — \(detail)")
        for asset in images { print("image: \(try store.assetURL(asset).path)") }
    }
    func run() async throws {
        do {
            guard ImageModel.allCases.map(\.rawValue) == ["gpt-image-2", "gpt-image-2.5-flare", "gpt-image-2.5", "gpt-image-2.5-sunburst"] else { throw ImageAgentError.invalidInput("Model contract failed") }
            try record("model-contract", detail: "Four exact image model identifiers; gpt-image-2 default; planner gpt-6.1-sol")
            let generate = arguments.contains("--live-generate")
            let edit = arguments.contains("--live-edit")
            let region = arguments.contains("--region")
            let liveRegion = arguments.contains("--live-region")
            let streaming = arguments.contains("--streaming")
            guard [generate || edit, region, liveRegion, streaming, option("--recover-response") != nil].filter({ $0 }).count <= 1 else { throw ImageAgentError.invalidInput("Choose one diagnostic mode; diagnostics never chain another image operation.") }
            if streaming { try await runStreaming() }
            else if region || liveRegion { try await runRegion(live: liveRegion) }
            else if let filename = option("--recover-response") { try recoverSavedResponse(filename) }
            else if !generate && !edit { try runLocal() }
            else { try await runLive(generate: generate, edit: edit) }
            report.status = option("--recover-response") == nil ? "passed" : "recovered-unverified"; try writeReport()
            print("report: \(output.appendingPathComponent("report.json").path)")
        } catch {
            report.status = "failed"
            let safe = client?.safeDescription(error) ?? error.localizedDescription
            try? record("failure", status: "failed", detail: safe)
            try? writeReport()
            throw ImageAgentError.invalidInput(safe)
        }
    }
    func recoverSavedResponse(_ filename: String) throws {
        let response = try ResponseResult.decode(Data(contentsOf: URL(fileURLWithPath: filename)))
        let recovery = response.recoverBase64ImageOutput()
        guard !recovery.images.isEmpty else { throw ImageAgentError.invalidImage("保存的 Responses JSON 没有可恢复的有效图片。\(recovery.failures.joined(separator: " "))") }
        let conversation: Conversation
        if let existing = try store.conversations().first { conversation = existing }
        else { conversation = try store.createConversation(title: "恢复服务已有图片") }
        let existing = try store.assets(in: conversation.id).filter { $0.modelVerified == false }
        if !existing.isEmpty {
            try record("native-output-recovery", status: "retained-unverified", detail: "Existing recovered images retained; no HTTP request was made; actual model remains unverified", images: existing)
            return
        }
        var selection: ImageSelection?
        if let raw = option("--model") {
            guard let model = ImageModel(rawValue: raw) else { throw ImageAgentError.invalidInput("Unsupported --model") }
            selection = .init(model: model)
        }
        var run = RunRecord(conversationID: conversation.id, stage: .saving, request: "从已有 Responses JSON 离线恢复图片；实际模型未验证。", selection: selection ?? .init())
        try store.saveRun(run)
        var images: [AssetRecord] = []
        for image in recovery.images {
            let asset = try store.saveImage(image.data, conversationID: conversation.id, source: .generated, selection: selection, modelVerified: false, run: run)
            images.append(asset); run.resultAssetIDs.append(asset.id)
        }
        run.stage = .failed; run.updatedAt = Date(); run.error = "已有图片已恢复，实际图片模型未验证。未调用图片接口或规划接口。"
        try store.saveRun(run)
        try store.addMessage(.init(conversationID: conversation.id, role: .assistant, text: run.error!, assetIDs: run.resultAssetIDs))
        try record("native-output-recovery", status: "recovered-unverified", detail: "Decoded \(images.count) existing image(s); no HTTP request was made; actual model remains unverified. \(recovery.failures.joined(separator: " "))", images: images)
    }
    func runLocal() throws {
        let now = Date()
        let conversation = try store.createConversation(title: "Local diagnostics", now: now)
        try store.addMessage(.init(conversationID: conversation.id, role: .user, text: "A local memory check", createdAt: now))
        guard try MemoryBuilder(store: store, clock: { now }).build(conversationID: conversation.id).entries.count == 1 else { throw ImageAgentError.storage("Local memory check failed") }
        try store.resetMemory(conversation.id, at: now)
        let reopened = try SQLiteStore(paths: store.paths)
        guard try MemoryBuilder(store: reopened, clock: { now }).build(conversationID: conversation.id).entries.isEmpty,
              try reopened.messages(in: conversation.id).count == 1 else { throw ImageAgentError.storage("Memory reset/reopen failed") }
        try record("sqlite-memory", detail: "SQLite reopened; memory reset excludes context and preserves history")
        let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a0X8AAAAASUVORK5CYII=")!
        let image = try store.saveImage(bytes, conversationID: conversation.id, source: .imported)
        try record("image-decode-save", detail: "ImageIO decoded \(image.width)×\(image.height); original bytes saved", images: [image])
    }
    func runStreaming() async throws {
        let image = try PixelImage(width: 8, height: 8, rgba: [UInt8](repeating: 180, count: 8 * 8 * 4)).pngData()
        for interrupted in [false, true] {
            let conversation = try store.createConversation(title: interrupted ? "Offline interrupted stream" : "Offline completed stream")
            let transport = SimulatedPlanningTransport(imageData: image, delay: .milliseconds(2), interruptAfterPreview: interrupted)
            let api = try APIClient(baseURL: "https://offline.invalid", apiKey: "offline-stream-diagnostic", transport: transport)
            let previews = DiagnosticPromptLog()
            let outcome = try await AgentEngine(store: store, client: api).submit(.init(conversationID: conversation.id, text: "离线合成图片的流式提示词验证。"), planningPreview: { preview in
                previews.append(preview.text)
            })
            let lengths = previews.lengths
            let stats = await transport.statistics()
            guard lengths.count >= 3, lengths.first! < lengths.last!, stats.plans == 1,
                  stats.images == (interrupted ? 0 : 1), outcome.run.stage == (interrupted ? .failed : .completed) else {
                throw ImageAgentError.invalidInput("Offline stream growth, terminal gate or request-count check failed")
            }
            if interrupted {
                guard outcome.run.detailedPrompt == nil, outcome.message.detailedPrompt == nil, outcome.assets.isEmpty else { throw ImageAgentError.invalidInput("Unfinished preview was promoted to a final prompt") }
            } else {
                let reopened = try SQLiteStore(paths: store.paths)
                guard outcome.run.detailedPrompt == SimulatedPlanningTransport.prompt,
                      outcome.message.detailedPrompt == outcome.assets.first?.prompt,
                      try reopened.messages(in: conversation.id).last?.detailedPrompt == outcome.run.detailedPrompt else {
                    throw ImageAgentError.invalidInput("Final prompt persistence/equality check failed")
                }
            }
            try record(interrupted ? "streaming-interrupted" : "streaming-completed", detail: "Offline incremental SSE: \(lengths.count) real preview updates (\(lengths.map(String.init).joined(separator: ",")) chars); one planner, \(stats.images) image calls; \(interrupted ? "unfinished text never persisted" : "validated final prompt and reopened history match image asset")", images: outcome.assets)
        }
    }
    func runRegion(live: Bool) async throws {
        let conversation: Conversation
        if let existing = try store.conversations().first { conversation = existing }
        else { conversation = try store.createConversation(title: live ? "Live regional validation" : "Isolated regional validation") }
        let previousRuns = try store.runs(in: conversation.id)
        if !previousRuns.isEmpty {
            let previousAssets = try store.assets(in: conversation.id).filter { $0.source == .edited }
            if previousRuns.last?.stage == .completed, !previousAssets.isEmpty {
                try record(live ? "live-region" : "region", status: "retained", detail: "Existing completed regional result retained; no HTTP request or image replay", images: previousAssets)
                return
            }
            throw ImageAgentError.invalidInput("This output directory contains an attempted region task. Inspect saved/recovery images; it will not be replayed.")
        }
        guard let model = ImageModel(rawValue: option("--model") ?? ImageModel.default.rawValue),
              let quality = ImageQuality(rawValue: option("--quality") ?? ImageQuality.low.rawValue) else { throw ImageAgentError.invalidInput("Invalid --model or --quality") }
        let selection = ImageSelection(model: model, size: .auto, quality: quality)
        let reference: AssetRecord
        if let filename = option("--reference") {
            reference = try store.saveImage(Data(contentsOf: URL(fileURLWithPath: filename)), conversationID: conversation.id, source: .imported)
        } else if live { throw ImageAgentError.invalidInput("--live-region requires --reference /absolute/path.png; it never generates a new base image.") }
        else {
            var bytes = [UInt8]()
            for y in 0..<64 { for x in 0..<96 { bytes += [UInt8(x * 2), UInt8(y * 3), UInt8((x + y) % 256), 255] } }
            reference = try store.saveImage(PixelImage(width: 96, height: 64, rgba: bytes).pngData(), conversationID: conversation.id, source: .imported)
        }
        let originalData = try Data(contentsOf: store.assetURL(reference))
        let base = try PixelImage(data: originalData)
        var region = RegionSelection(width: base.width, height: base.height)
        if let rawRect = option("--region-rect") {
            let values = rawRect.split(separator: ",").compactMap { Double($0) }
            guard values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else { throw ImageAgentError.invalidInput("--region-rect must be x,y,width,height in oriented source pixels") }
            region.addRectangle(from: .init(x: values[0], y: values[1]), to: .init(x: values[0] + values[2], y: values[1] + values[3]))
        } else {
            region.addRectangle(from: .init(x: Double(base.width) * 0.4, y: Double(base.height) * 0.3), to: .init(x: Double(base.width) * 0.6, y: Double(base.height) * 0.5))
        }
        let snapshot = try RegionEditSnapshot(base: base, selection: region)
        for (name, data) in [("region-crop.png", snapshot.imagePNG), ("region-mask.png", snapshot.maskPNG)] {
            let url = output.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let patch = try PixelImage(width: 9, height: 5, rgba: Array(repeating: [UInt8(220), 30, 90, 255], count: 45).flatMap { $0 }).pngData()
        let transport = RegionDiagnosticTransport(live: live, reference: reference.id, selection: selection, snapshot: snapshot, patch: patch)
        let api: APIClient
        if live {
            let environment = ProcessInfo.processInfo.environment
            guard let key = environment["OPENAI_API_KEY"], !key.isEmpty,
                  let address = environment["OPENAI_BASE_URL"], !address.isEmpty else { throw ImageAgentError.credential("Live regional diagnostics require parent-supplied OPENAI_BASE_URL and OPENAI_API_KEY in process environment only.") }
            api = try APIClient(baseURL: address, apiKey: key, transport: transport)
            report.endpoint = api.endpoint.string
        } else { api = try APIClient(baseURL: "https://isolated.example.test", apiKey: "offline-diagnostic", transport: transport) }
        client = api
        let outcome = try await AgentEngine(store: store, client: api).submit(.init(conversationID: conversation.id,
            text: option("--edit-prompt") ?? "将选中的部分改成柔和的蓝色，保持周围构图与其他内容。", selection: selection,
            regionEdit: .init(assetID: reference.id, selection: region)))
        try record(live ? "live-region-request" : "region-request", status: outcome.run.stage.rawValue,
                   detail: "Pinned source \(reference.id); model \(model.rawValue); ROI \(snapshot.roi.width)×\(snapshot.roi.height); alpha PNG mask \(snapshot.maskPNG.count) bytes; run \(outcome.run.id)", images: outcome.assets)
        guard outcome.run.stage == .completed, let asset = outcome.assets.first, asset.parentAssetID == reference.id else { throw ImageAgentError.invalidInput(outcome.run.error ?? "Regional plan did not complete") }
        let result = try PixelImage(data: Data(contentsOf: store.assetURL(asset)))
        guard result.width == base.width, result.height == base.height,
              try Data(contentsOf: store.assetURL(reference)) == originalData else { throw ImageAgentError.invalidImage("Source size, original bytes or lineage changed") }
        var outsidePixels = 0, changedSelectedPixels = 0
        for index in snapshot.coverage.indices {
            let offset = index * 4
            let equal = base.rgba[offset..<(offset + 4)] == result.rgba[offset..<(offset + 4)]
            if snapshot.coverage[index] == 0 {
                guard equal else { throw ImageAgentError.invalidImage("Outside-selection pixel changed at \(index)") }
                outsidePixels += 1
            } else if !equal { changedSelectedPixels += 1 }
        }
        let stats = await transport.stats()
        guard stats.images == 1, stats.plans == 1, stats.validMultipart else { throw ImageAgentError.invalidInput("Unexpected request count or image/mask multipart") }
        guard let recovery = try store.recoveryURL(outcome.run) else { throw ImageAgentError.storage("Returned patch recovery file missing") }
        _ = try DecodedImage(data: Data(contentsOf: recovery))
        try record(live ? "live-region-preservation" : "region-preservation", detail: "One plan and one masked edit; matching image/mask multipart verified; full result \(result.width)×\(result.height); \(outsidePixels) outside pixels exactly equal; \(changedSelectedPixels) selected pixels changed; original and raw returned patch retained", images: [reference, asset])
    }

    func runLive(generate: Bool, edit: Bool) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let key = environment["OPENAI_API_KEY"], !key.isEmpty,
              let address = environment["OPENAI_BASE_URL"], !address.isEmpty else {
            throw ImageAgentError.credential("Live diagnostics require OPENAI_BASE_URL and OPENAI_API_KEY in the calling process environment. Credentials are never read from other apps.")
        }
        let api = try APIClient(baseURL: address, apiKey: key); client = api; report.endpoint = api.endpoint.string
        guard let model = ImageModel(rawValue: option("--model") ?? ImageModel.default.rawValue),
              let size = ImageSize(rawValue: option("--size") ?? ImageSize.square.rawValue),
              let quality = ImageQuality(rawValue: option("--quality") ?? ImageQuality.low.rawValue) else { throw ImageAgentError.invalidInput("Invalid --model, --size or --quality value; no model substitution is allowed.") }
        let selection = ImageSelection(model: model, size: size, quality: quality)
        let models = try await api.validateConnection()
        try record("connection", detail: "GET /v1/models returned \(models.count) model identifiers; credentials excluded from report")
        let conversation: Conversation
        if let existing = try store.conversations().first { conversation = existing }
        else { conversation = try store.createConversation(title: "Live NewAPI validation") }
        let engine = AgentEngine(store: store, client: api)
        if generate {
            let existing = try store.assets(in: conversation.id).filter { $0.source == .generated }
            if !existing.isEmpty {
                try record("live-generation", status: "retained", detail: "Existing generated result reused without another image request", images: existing)
            } else {
                guard try store.runs(in: conversation.id).isEmpty else { throw ImageAgentError.invalidInput("This output directory already contains an attempted live request. It will not be replayed. Inspect existing results or choose a new output directory for an explicit new task.") }
                let prompt = option("--prompt") ?? "请画一幅极简的山间湖泊插画，柔和晨光、层叠远山、湖畔小屋，森林绿和温暖米色，纸张质感，画面无文字。"
                let outcome = try await engine.submit(.init(conversationID: conversation.id, text: prompt, selection: selection))
                try record("live-generation", status: outcome.run.stage.rawValue, detail: "Requested \(model.rawValue) at \(size.rawValue); decoded \(outcome.assets.map { "\($0.width)×\($0.height)" }.joined(separator: ", ")); run \(outcome.run.id)", images: outcome.assets)
                guard outcome.run.stage == .completed, !outcome.assets.isEmpty else { throw ImageAgentError.invalidInput(outcome.run.error ?? "Planner did not produce an image") }
            }
        }
        if edit {
            let all = try store.assets(in: conversation.id)
            if let existing = all.last(where: { $0.source == .edited }) {
                try record("live-edit", status: "retained", detail: "Existing edited result reused without another image request", images: [existing])
            } else {
                if let last = try store.runs(in: conversation.id).last, last.stage != .completed { throw ImageAgentError.invalidInput("The previous live task did not finish cleanly. Inspect its saved images; no automatic replay or edit will be made.") }
                let reference: AssetRecord
                if let filename = option("--reference") { reference = try store.saveImage(Data(contentsOf: URL(fileURLWithPath: filename)), conversationID: conversation.id, source: .imported) }
                else if let recent = all.last { reference = recent }
                else { throw ImageAgentError.invalidInput("--live-edit requires an existing saved image or --reference /absolute/path.png") }
                let prompt = option("--edit-prompt") ?? "请编辑这张参考图：保持构图、小屋和山体不变，把天空改成柔和的黄昏粉紫色，湖面保留安静的反光。"
                let outcome = try await engine.submit(.init(conversationID: conversation.id, text: prompt, selection: selection, referenceAssetID: reference.id))
                try record("live-edit", status: outcome.run.stage.rawValue, detail: "Reference \(reference.id); exact model \(model.rawValue); decoded \(outcome.assets.map { "\($0.width)×\($0.height)" }.joined(separator: ", ")); result lineage \(outcome.assets.first?.parentAssetID ?? "none")", images: outcome.assets)
                guard outcome.run.stage == .completed, outcome.assets.first?.parentAssetID == reference.id else { throw ImageAgentError.invalidInput(outcome.run.error ?? "Planner did not perform the requested edit") }
            }
        }
    }
}

/// Both paths exercise the exact core/multipart implementation. Only explicit live mode forwards HTTP.
private actor RegionDiagnosticTransport: HTTPTransport {
    private let live: Bool
    private let reference: String
    private let selection: ImageSelection
    private let snapshot: RegionEditSnapshot
    private let patch: Data
    private let network = URLSessionTransport()
    private var images = 0
    private var plans = 0
    private var validMultipart = false
    init(live: Bool, reference: String, selection: ImageSelection, snapshot: RegionEditSnapshot, patch: Data) {
        self.live = live; self.reference = reference; self.selection = selection; self.snapshot = snapshot; self.patch = patch
    }
    func stats() -> (images: Int, plans: Int, validMultipart: Bool) { (images, plans, validMultipart) }
    func stream(_ request: URLRequest, receive: @escaping @Sendable (HTTPStreamEvent) throws -> Void) async throws {
        if live, request.url?.path == "/v1/responses" {
            plans += 1
            guard plans == 1 else { throw ImageAgentError.invalidInput("Unexpected extra planning request") }
            try await network.stream(request, receive: receive)
        } else {
            let response = try await send(request)
            try receive(.response(statusCode: response.statusCode, contentType: nil))
            try receive(.bytes(response.data))
        }
    }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        switch request.url?.path {
        case "/v1/responses":
            plans += 1
            guard plans == 1 else { throw ImageAgentError.invalidInput("Unexpected extra planning request") }
            if live { return try await network.send(request) }
            let args: JSONValue = .object(["action": .string("edit"), "prompt": .string("Edit only the transparent masked pixels with a soft blue color; preserve the surrounding context."),
                "model": .string(selection.model.rawValue), "size": .string("auto"), "quality": .string(selection.quality.rawValue),
                "reference_image_id": .string(reference), "reply_text": .string("选区已修改。")])
            let response: JSONValue = .object(["status": .string("completed"), "output": .array([.object(["type": .string("function_call"), "name": .string("prepare_image_request"), "call_id": .string("region_diagnostic"), "arguments": .string(try args.encodedString())])])])
            return .init(data: try JSONEncoder().encode(response), statusCode: 200)
        case "/v1/images/edits":
            images += 1
            guard images == 1, let body = request.httpBody,
                  request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true,
                  body.range(of: snapshot.imagePNG) != nil, body.range(of: snapshot.maskPNG) != nil else { throw ImageAgentError.invalidInput("Regional request missing exact crop/mask or duplicate image request") }
            let text = String(decoding: body, as: UTF8.self)
            guard text.contains("name=\"mask\"; filename=\"mask.png\""), text.contains(selection.model.rawValue) else { throw ImageAgentError.invalidInput("Invalid regional multipart") }
            validMultipart = true
            if live { return try await network.send(request) }
            let response: JSONValue = .object(["data": .array([.object(["b64_json": .string(patch.base64EncodedString())])])])
            return .init(data: try JSONEncoder().encode(response), statusCode: 200)
        default:
            // Image result URLs can be downloaded once; they carry no API Authorization.
            if live, request.httpMethod == "GET", request.value(forHTTPHeaderField: "Authorization") == nil { return try await network.send(request) }
            throw ImageAgentError.invalidInput("Unexpected diagnostic endpoint; no request sent")
        }
    }
}

private final class DiagnosticPromptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func append(_ text: String) { lock.lock(); defer { lock.unlock() }; values.append(text.count) }
    var lengths: [Int] { lock.lock(); defer { lock.unlock() }; return values }
}

if CommandLine.arguments.contains("--help") {
    print("""
    ImageAgentDiagnostics [--output DIRECTORY]
      No live flags: isolated local SQLite, memory and ImageIO checks.
      --region              Isolated regional engine, fake transport, alpha mask and exact outside-pixel checks.
      --streaming           Offline chunked SSE growth, terminal gate, interruption and saved-prompt checks.
      --live-region         One planned masked edit of --reference FILE; billed, never replayed.
      --region-rect X,Y,W,H Optional selected rectangle in oriented source pixels.
      --live-generate       Plan and generate one image (billed, never automatically retried).
      --live-edit           Plan one edit of the saved result or --reference FILE (billed).
      --model MODEL        One of the four exact supported model names; default gpt-image-2.
      --size SIZE          auto, 1024x1024, 1536x1024, 1024x1536.
      --quality QUALITY    auto, low, medium, high; diagnostic default low.
      --prompt TEXT        Optional generation request.
      --edit-prompt TEXT   Optional editing request.
      --recover-response FILE  Offline recovery of existing image_generation_call Base64 results.
    Live mode requires process-only OPENAI_BASE_URL and OPENAI_API_KEY.
    Existing images in an output directory are retained and never regenerated.
    """)
} else {
    do { try await Diagnostics(arguments: CommandLine.arguments).run() }
    catch { fputs("ImageAgentDiagnostics: \(error.localizedDescription)\n", stderr); exit(1) }
}
