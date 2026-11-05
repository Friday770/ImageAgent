import Foundation

public enum ImageModel: String, Codable, CaseIterable, Sendable {
    case standard = "gpt-image-2"
    case flare = "gpt-image-2.5-flare"
    case image25 = "gpt-image-2.5"
    case sunburst = "gpt-image-2.5-sunburst"
    public static let `default` = ImageModel.standard
}

public enum ImageSize: String, Codable, CaseIterable, Sendable {
    case auto, square = "1024x1024", landscape = "1536x1024", portrait = "1024x1536"
}

public enum ImageQuality: String, Codable, CaseIterable, Sendable { case auto, low, medium, high }

public struct ImageSelection: Codable, Equatable, Sendable {
    public var model: ImageModel
    public var size: ImageSize
    public var quality: ImageQuality
    public init(model: ImageModel = .default, size: ImageSize = .square, quality: ImageQuality = .auto) {
        self.model = model; self.size = size; self.quality = quality
    }
}

public struct MemoryPolicy: Codable, Equatable, Sendable {
    public var hours: Int
    public var turns: Int
    public var maxCharacters: Int
    public init(hours: Int = 24, turns: Int = 12, maxCharacters: Int = 24_000) {
        self.hours = min(max(hours, 1), 720)
        self.turns = min(max(turns, 1), 100)
        self.maxCharacters = min(max(maxCharacters, 256), 100_000)
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var endpoint: String
    public var plannerModel: String
    public var selection: ImageSelection
    public var memory: MemoryPolicy
    public init(endpoint: String = "https://api.example.com/v1", plannerModel: String = PlannerModel.default, selection: ImageSelection = .init(), memory: MemoryPolicy = .init()) {
        self.endpoint = endpoint; self.plannerModel = plannerModel; self.selection = selection; self.memory = memory
    }
    private enum CodingKeys: String, CodingKey { case endpoint, plannerModel, selection, memory }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try values.decode(String.self, forKey: .endpoint)
        plannerModel = try values.decodeIfPresent(String.self, forKey: .plannerModel) ?? PlannerModel.default
        selection = try values.decode(ImageSelection.self, forKey: .selection)
        memory = try values.decode(MemoryPolicy.self, forKey: .memory)
    }
}

public enum PlannerModel {
    public static let `default` = "gpt-6.1-sol"
    public static func validated(_ input: String) throws -> String {
        let model = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.count <= 200,
              !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              ImageModel(rawValue: model) == nil else {
            throw ImageAgentError.invalidInput("请输入有效的文字规划模型 ID（1–200 个字符，不能包含控制字符或使用图片模型）。")
        }
        return model
    }
}

public struct Conversation: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date
    public var memoryResetAt: Date?
    public init(id: String = UUID().uuidString.lowercased(), title: String = "新会话", createdAt: Date = Date(), updatedAt: Date? = nil, memoryResetAt: Date? = nil) {
        self.id = id; self.title = title; self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt; self.memoryResetAt = memoryResetAt
    }
}

public enum MessageRole: String, Codable, Sendable { case user, assistant }
public struct MessageRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let conversationID: String
    public let role: MessageRole
    public let text: String
    public let assetIDs: [String]
    public let detailedPrompt: String?
    public let runID: String?
    public let createdAt: Date
    public init(id: String = UUID().uuidString.lowercased(), conversationID: String, role: MessageRole, text: String, assetIDs: [String] = [], detailedPrompt: String? = nil, runID: String? = nil, createdAt: Date = Date()) {
        self.id = id; self.conversationID = conversationID; self.role = role; self.text = text
        self.assetIDs = assetIDs; self.detailedPrompt = detailedPrompt; self.runID = runID; self.createdAt = createdAt
    }
}

public enum AssetSource: String, Codable, Sendable { case generated, edited, imported }
public struct AssetRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let conversationID: String
    public let relativePath: String
    public let mediaType: String
    public let width: Int
    public let height: Int
    public let parentAssetID: String?
    public let runID: String?
    public let source: AssetSource
    public let prompt: String
    public let model: String?
    /// False means bytes were recovered from an unexpected provider-native tool, not our image endpoint.
    public let modelVerified: Bool?
    public let requestedSize: String?
    public let createdAt: Date
    public var dimensionWarning: String? {
        guard let requestedSize, requestedSize != "auto", requestedSize != "\(width)x\(height)" else { return nil }
        return "请求尺寸 \(requestedSize)，服务实际返回 \(width)×\(height)。已保留原图。"
    }
    public var modelWarning: String? {
        modelVerified == false ? "服务返回了未预期的内置图片输出，实际图片模型和提示词未验证。已保留现有图片，没有额外调用图片接口。" : nil
    }
    public init(id: String = UUID().uuidString.lowercased(), conversationID: String, relativePath: String, mediaType: String, width: Int, height: Int, parentAssetID: String? = nil, runID: String? = nil, source: AssetSource, prompt: String = "", model: String? = nil, modelVerified: Bool? = nil, requestedSize: String? = nil, createdAt: Date = Date()) {
        self.id = id; self.conversationID = conversationID; self.relativePath = relativePath
        self.mediaType = mediaType; self.width = width; self.height = height
        self.parentAssetID = parentAssetID; self.runID = runID; self.source = source
        self.prompt = prompt; self.model = model; self.modelVerified = modelVerified; self.requestedSize = requestedSize; self.createdAt = createdAt
    }
}

public enum RunStage: String, Codable, Sendable {
    case planning, generating, editing, saving, finalizing, completed, failed, cancelled, interrupted
    public var isTerminal: Bool { [.completed, .failed, .cancelled, .interrupted].contains(self) }
    public var label: String {
        switch self {
        case .planning: return "正在理解需求、整理提示词…"
        case .generating: return "正在生成图片…"
        case .editing: return "正在编辑参考图片…"
        case .saving: return "正在验证并保存图片…"
        case .finalizing: return "图片已保存，正在整理回复…"
        case .completed: return "已完成"
        case .failed: return "任务未完成"
        case .cancelled: return "已取消；不会自动重试"
        case .interrupted: return "任务已中断；不会自动重试"
        }
    }
}

public struct RunRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let conversationID: String
    public var stage: RunStage
    public let request: String
    public var detailedPrompt: String?
    public let selection: ImageSelection
    /// Actual immutable client choice; absent in legacy records and hidden from the normal UI.
    public var plannerModel: String?
    public var resultAssetIDs: [String]
    public var error: String?
    /// Private, relative path to a received regional patch, retained even if compositing fails.
    public var recoveryRelativePath: String?
    public let regionEdit: RegionEditRequest?
    public let createdAt: Date
    public var updatedAt: Date
    public init(id: String = UUID().uuidString.lowercased(), conversationID: String, stage: RunStage = .planning, request: String, detailedPrompt: String? = nil, selection: ImageSelection = .init(), plannerModel: String? = nil, resultAssetIDs: [String] = [], error: String? = nil, recoveryRelativePath: String? = nil, regionEdit: RegionEditRequest? = nil, createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id; self.conversationID = conversationID; self.stage = stage; self.request = request
        self.detailedPrompt = detailedPrompt; self.selection = selection; self.plannerModel = plannerModel; self.resultAssetIDs = resultAssetIDs
        self.error = error; self.recoveryRelativePath = recoveryRelativePath; self.regionEdit = regionEdit; self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
    }
}

public struct AgentRequest: Sendable {
    public let conversationID: String
    public let text: String
    public let selection: ImageSelection
    public let referenceAssetID: String?
    public let regionEdit: RegionEditRequest?
    public init(conversationID: String, text: String, selection: ImageSelection = .init(), referenceAssetID: String? = nil, regionEdit: RegionEditRequest? = nil) {
        self.conversationID = conversationID; self.text = text; self.selection = selection; self.referenceAssetID = referenceAssetID; self.regionEdit = regionEdit
    }
}

public struct RunOutcome: Sendable {
    public let run: RunRecord
    public let message: MessageRecord
    public let assets: [AssetRecord]
}

/// Transient planner text. It is never stored as a final prompt or included in memory.
public struct PlanningPreview: Equatable, Sendable {
    public let conversationID: String
    public let runID: String
    public let text: String
    public init(conversationID: String, runID: String, text: String) {
        self.conversationID = conversationID; self.runID = runID; self.text = text
    }
}
