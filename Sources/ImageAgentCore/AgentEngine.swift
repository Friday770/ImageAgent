import Foundation

public protocol ImageReplyFinalizer: Sendable {
    func finalize(assets: [AssetRecord], caption: String) throws -> String
}
public struct LocalImageReplyFinalizer: ImageReplyFinalizer {
    public init() {}
    public func finalize(assets: [AssetRecord], caption: String) throws -> String {
        guard !assets.isEmpty else { throw ImageAgentError.invalidInput("没有已保存的图片可供交付。") }
        let text = assets.first?.source == .edited ? "图片已编辑并保存在本机。" : "图片已生成并保存在本机。"
        let caption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        return caption.isEmpty ? text : text + "\n\n" + caption
    }
}

/// A forced, strictly validated plan chooses one fixed operation. Image completion is local.
public actor AgentEngine {
    private let store: SQLiteStore
    private let client: APIClient
    private let finalizer: any ImageReplyFinalizer
    private let clock: @Sendable () -> Date
    private var activeConversations: Set<String> = []
    public init(store: SQLiteStore, client: APIClient, clock: @escaping @Sendable () -> Date = { Date() }, finalizer: any ImageReplyFinalizer = LocalImageReplyFinalizer()) {
        self.store = store; self.client = client; self.clock = clock; self.finalizer = finalizer
    }

    public func submit(_ originalRequest: AgentRequest, policy: MemoryPolicy = .init(), progress: @escaping @Sendable (RunRecord) -> Void = { _ in }, planningPreview: @escaping @Sendable (PlanningPreview) -> Void = { _ in }) async throws -> RunOutcome {
        var selection = originalRequest.selection
        if originalRequest.regionEdit != nil { selection.size = .auto }
        let request = AgentRequest(conversationID: originalRequest.conversationID, text: originalRequest.text, selection: selection,
                                   referenceAssetID: originalRequest.regionEdit?.assetID ?? originalRequest.referenceAssetID, regionEdit: originalRequest.regionEdit)
        if let region = request.regionEdit, let reference = originalRequest.referenceAssetID, reference != region.assetID {
            throw ImageAgentError.invalidInput("局部编辑目标与参考图片不一致。")
        }
        guard !activeConversations.contains(request.conversationID) else { throw ImageAgentError.busy }
        let text = client.sanitized(request.text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty, text.count <= 8000 else { throw ImageAgentError.invalidInput("请输入 1–8000 字的需求。") }
        let context = try MemoryBuilder(store: store, clock: clock).build(conversationID: request.conversationID, policy: policy, explicitReferenceID: request.referenceAssetID)
        let regionSnapshot: RegionEditSnapshot?
        if let region = request.regionEdit {
            // Reject a context that could not be decoded after restart before accepting user history.
            _ = try JSONDecoder().decode(RegionEditRequest.self, from: JSONEncoder().encode(region))
            guard let asset = try store.asset(region.assetID), asset.conversationID == request.conversationID else {
                throw ImageAgentError.invalidInput("要编辑的图片已删除，或不属于原会话。")
            }
            regionSnapshot = try RegionEditSnapshot(base: PixelImage(data: Data(contentsOf: store.assetURL(asset))), selection: region.selection)
        } else { regionSnapshot = nil }
        activeConversations.insert(request.conversationID)
        defer { activeConversations.remove(request.conversationID) }
        let now = clock()
        var run = RunRecord(conversationID: request.conversationID, request: text, selection: request.selection, plannerModel: client.selectedPlannerModel, regionEdit: request.regionEdit, createdAt: now)
        try store.addMessage(.init(conversationID: request.conversationID, role: .user, text: client.sanitized(request.text), assetIDs: request.referenceAssetID.map { [$0] } ?? [], runID: run.id, createdAt: now))
        try store.saveRun(run); progress(run)
        let runID = run.id
        var savedAssets: [AssetRecord] = []
        var planningWasCancelled = false
        do {
            try Task.checkCancellation()
            let response: ResponseResult
            do {
                response = try await client.respond(input: makeInput(context: context, request: request, text: text), selection: request.selection, promptPreview: { text in
                    planningPreview(.init(conversationID: request.conversationID, runID: runID, text: text))
                })
            } catch let failure as ResponseStreamError {
                // Recovery precedes cancellation/error handling: known native bytes must survive.
                planningWasCancelled = failure.wasCancelled
                try recoverUnexpectedImages(failure.partialResponse, request: request, snapshot: regionSnapshot, run: &run, assets: &savedAssets, progress: progress)
                throw failure
            }
            if !response.nativeImageOutputs.isEmpty {
                try recoverUnexpectedImages(response, request: request, snapshot: regionSnapshot, run: &run, assets: &savedAssets, progress: progress)
            }
            try Task.checkCancellation()
            guard response.toolCalls.count == 1 else { throw ImageAgentError.invalidInput("规划模型必须返回一个 prepare_image_request 函数计划；未执行图片请求。") }
            let plan = try validate(response.toolCalls[0], selection: request.selection, context: context, regionAssetID: request.regionEdit?.assetID)
            let finalText: String
            if plan.action == "reply" { finalText = plan.reply }
            else {
                run.detailedPrompt = plan.prompt
                run.stage = plan.action == "edit" ? .editing : .generating
                run.updatedAt = clock(); try store.saveRun(run); progress(run)
                try Task.checkCancellation()
                let image: DecodedImage
                if let reference = plan.reference {
                    guard let current = try store.asset(reference.id), current.conversationID == request.conversationID,
                          try store.conversation(request.conversationID) != nil else { throw ImageAgentError.invalidInput("要编辑的图片或原会话已删除；未执行图片请求。") }
                    image = try await client.edit(prompt: plan.prompt, selection: request.selection,
                                                  reference: regionSnapshot?.imagePNG ?? Data(contentsOf: store.assetURL(reference)), mask: regionSnapshot?.maskPNG)
                } else {
                    image = try await client.generate(prompt: plan.prompt, selection: request.selection)
                }
                // A known image is committed even if cancellation arrived with its response.
                let savedData: Data
                if let snapshot = regionSnapshot, let region = request.regionEdit {
                    // Record the deterministic recovery path before any further fallible local work.
                    run.recoveryRelativePath = "recovery/\(run.id)/patch.\(image.fileExtension)"
                    _ = try store.saveRegionPatch(image.data, run: run, sourceAssetID: region.assetID, snapshot: snapshot)
                    run.stage = .saving; run.updatedAt = clock(); try store.saveRun(run); progress(run)
                    savedData = try snapshot.composite(patch: PixelImage(data: image.data)).pngData()
                } else {
                    savedData = image.data
                    run.stage = .saving; run.updatedAt = clock(); try store.saveRun(run); progress(run)
                }
                let asset = try store.saveImage(savedData, conversationID: request.conversationID, parentAssetID: plan.reference?.id, source: plan.reference == nil ? .generated : .edited, prompt: plan.prompt, selection: request.selection, run: run, now: clock())
                savedAssets = [asset]; run.resultAssetIDs = [asset.id]
                run.stage = .finalizing; run.updatedAt = clock(); try store.saveRun(run); progress(run)
                try Task.checkCancellation()
                // No second Responses request: completion cannot trigger another native image call.
                finalText = try finalizer.finalize(assets: savedAssets, caption: plan.reply)
            }
            run.stage = .completed; run.updatedAt = clock(); try store.saveRun(run)
            let message = MessageRecord(conversationID: request.conversationID, role: .assistant, text: client.sanitized(finalText), assetIDs: run.resultAssetIDs, detailedPrompt: run.detailedPrompt, runID: run.id, createdAt: clock())
            try store.addMessage(message); progress(run)
            return .init(run: run, message: message, assets: savedAssets)
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled || planningWasCancelled
            run.stage = cancelled ? .cancelled : .failed; run.updatedAt = clock()
            run.error = cancelled ? "任务已取消。远端请求可能已执行；不会自动重试。" : client.safeDescription(error)
            if planningWasCancelled { run.error! += "\n已收到的内置图片模型和提示词未验证；有效字节已保留。" }
            if run.recoveryRelativePath != nil, (try? store.recoveryURL(run)) != nil {
                run.error! += "\n已返回的局部图片已保留，可在图片工作区查看恢复文件；请勿重复提交本次请求。"
            }
            if savedAssets.isEmpty {
                savedAssets = try store.assets(in: request.conversationID).filter { $0.runID == run.id }
                run.resultAssetIDs = savedAssets.map(\.id)
            }
            try store.saveRun(run)
            let text = savedAssets.isEmpty ? run.error! : "图片已保存。\(cancelled ? "后续回复已取消。" : "最终回复未完成。")\n\(run.error!)"
            let message = MessageRecord(conversationID: request.conversationID, role: .assistant, text: text, assetIDs: run.resultAssetIDs, detailedPrompt: run.detailedPrompt, runID: run.id, createdAt: clock())
            try store.addMessage(message); progress(run)
            return .init(run: run, message: message, assets: savedAssets)
        }
    }

    private func recoverUnexpectedImages(_ response: ResponseResult, request: AgentRequest, snapshot: RegionEditSnapshot?, run: inout RunRecord, assets: inout [AssetRecord], progress: @Sendable (RunRecord) -> Void) throws {
        let recovery = response.recoverBase64ImageOutput()
        do {
            if let snapshot, let region = request.regionEdit {
                // Preserve every known regional-native response before run/asset registration can fail.
                for (index, image) in recovery.images.enumerated() {
                    let name = "native-\(index + 1)"
                    run.recoveryRelativePath = "recovery/\(run.id)/\(name).\(image.fileExtension)"
                    _ = try store.saveRegionPatch(image.data, run: run, sourceAssetID: region.assetID, snapshot: snapshot, name: name, modelVerified: false)
                }
            }
            for image in recovery.images {
                run.stage = .saving; run.updatedAt = clock()
                try store.saveRun(run); progress(run)
                let asset = try store.saveImage(image.data, conversationID: request.conversationID, parentAssetID: request.referenceAssetID, source: .generated, selection: request.selection, modelVerified: false, run: run, now: clock())
                assets.append(asset); run.resultAssetIDs.append(asset.id)
            }
        } catch {
            throw ImageAgentError.storage("服务返回了未验证的内置图片，局部编辑未完成。保存恢复图片时失败：\(client.safeDescription(error))")
        }
        let suffix = recovery.failures.isEmpty ? "" : "\n" + recovery.failures.joined(separator: "\n")
        let regional = request.regionEdit == nil ? "" : "此输出未完成局部合成，不是已完成的选区编辑。"
        throw ImageAgentError.invalidInput("服务返回了未预期的内置图片工具输出，实际图片模型未验证。\(regional)\(recovery.images.isEmpty ? "没有可恢复的有效图片。" : "现有图片已保存。")未额外调用图片接口。\(suffix)")
    }
    private func makeInput(context: MemoryContext, request: AgentRequest, text: String) -> [JSONValue] {
        let references = context.assets.map { "\($0.id) (\($0.width)×\($0.height))" }.joined(separator: "\n")
        let system = """
        你仅是 ImageAgent 的文字规划器，不直接生成图片。必须且只能调用一次 prepare_image_request 函数，禁止使用 image_generation 或任何其他内置图片工具。
        理解自然语言需求与当前会话记忆后选择 action：新画面用 generate，修改已有作品/保留参考内容用 edit，普通讨论用 reply。App 负责校验计划、调用图片 API、保存图片和本地完成回复。
        model=\(request.selection.model.rawValue)、size=\(request.selection.size.rawValue)、quality=\(request.selection.quality.rawValue) 必须原样传入，不得替换。
        generate/edit 的 prompt 必须是完整、明确、可直接执行的详细提示词，保留用户限制、主体特征和连续编辑意图。generate 的 reference_image_id=null；edit 必须使用下列有效 ID。reply 的 prompt 为空，reply_text 为完整讨论回复；图片任务的 reply_text 仅填写简短作品说明，完成保存后 App 才展示。
        主动选定的参考图：\(request.referenceAssetID ?? "无；按上下文选择最近有效作品")。
        有效参考图：\n\(references.isEmpty ? "无" : references)
        不得编造图片 ID、文件路径、模型名或命令。不使用服务器会话存储。用用户的语言回复。
        """
        let regional: String
        if let region = request.regionEdit {
            regional = "\n本次是固定目标的局部编辑。必须 action=edit，reference_image_id=\(region.assetID)，禁止 generate/reply 或改用任何其他图片。App 只发送用户选区及少量周边的裁图与 alpha 遮罩；透明部分为允许修改区域，其他像素保留。请将用户修改要求扩写为裁图内的编辑提示词，并保持未选中的上下文一致。最终由 App 合成到完整原图。"
        } else { regional = "" }
        var input: [JSONValue] = [.object(["role": .string("system"), "content": .string(system + regional)])]
        input.append(contentsOf: context.entries.map { .object(["role": .string($0.role.rawValue), "content": .string(client.sanitized($0.text))]) })
        input.append(.object(["role": .string("user"), "content": .string(text)]))
        return input
    }
    private struct ValidatedPlan { let action: String; let prompt: String; let reference: AssetRecord?; let reply: String }
    private func validate(_ call: ToolCall, selection: ImageSelection, context: MemoryContext, regionAssetID: String? = nil) throws -> ValidatedPlan {
        guard call.name == "prepare_image_request", !call.callID.isEmpty, call.callID.count < 256,
              let data = call.arguments.data(using: .utf8), data.count <= 200_000,
              let object = try? JSONDecoder().decode(JSONValue.self, from: data).object else { throw ImageAgentError.invalidInput("规划模型未返回有效的 prepare_image_request 计划。") }
        guard Set(object.keys) == Set(["action", "prompt", "model", "size", "quality", "reference_image_id", "reply_text"]),
              let action = object["action"]?.string, ["generate", "edit", "reply"].contains(action),
              let prompt = object["prompt"]?.string, prompt.count <= 32_000,
              let reply = object["reply_text"]?.string, reply.count <= 4000,
              object["model"]?.string == selection.model.rawValue,
              object["size"]?.string == selection.size.rawValue,
              object["quality"]?.string == selection.quality.rawValue else {
            throw ImageAgentError.invalidInput("图片计划参数无效，或与所选模型、尺寸、质量不一致；未执行图片请求。")
        }
        var reference: AssetRecord?
        if let id = object["reference_image_id"]?.string {
            guard let asset = context.assets.first(where: { $0.id == id }), FileManager.default.fileExists(atPath: try store.assetURL(asset).path) else {
                throw ImageAgentError.invalidInput("计划引用了未知、过期或其他会话的图片；未执行编辑请求。")
            }
            reference = asset
        } else if object["reference_image_id"] != .null { throw ImageAgentError.invalidInput("参考图片参数必须是有效 ID 或 null。") }
        if let regionAssetID {
            guard action == "edit", reference?.id == regionAssetID else { throw ImageAgentError.invalidInput("局部编辑计划必须编辑工作区对应的原图，不能更换目标或动作；未执行图片请求。") }
        }
        if action == "generate", reference != nil { throw ImageAgentError.invalidInput("生成计划不能附带编辑参考 ID。") }
        if action == "edit", reference == nil { throw ImageAgentError.invalidInput("编辑计划缺少有效参考图片。") }
        if action != "reply", prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ImageAgentError.invalidInput("图片计划缺少完整提示词。") }
        if action == "reply", reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ImageAgentError.invalidInput("讨论计划没有回复内容。") }
        if action == "reply", !prompt.isEmpty { throw ImageAgentError.invalidInput("讨论计划不能包含图片提示词；未执行图片请求。") }
        return .init(action: action, prompt: client.sanitized(prompt), reference: reference, reply: client.sanitized(reply))
    }
}
