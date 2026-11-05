import Foundation
import SwiftUI
import ImageAgentCore

struct ImageEditorTarget: Hashable, Codable {
    let conversationID: String
    let assetID: String
}
struct ImageWorkspaceSession: Identifiable, Equatable {
    let id = UUID()
    let target: ImageEditorTarget
}
struct ImageEditorDraft: Equatable {
    var selection: RegionSelection
    var prompt: String
    var tool: EditorTool
}
enum EditorTool: String, CaseIterable {
    case pan, pen, rectangle
    var title: String { switch self { case .pan: return "平移"; case .pen: return "钢笔圈选"; case .rectangle: return "方框" } }
    var symbol: String { switch self { case .pan: return "hand.draw"; case .pen: return "pencil.tip.crop.circle"; case .rectangle: return "rectangle" } }
    var hint: String { switch self { case .pan: return "拖动画面以平移"; case .pen: return "松开后自动闭合，修改圈内区域"; case .rectangle: return "拖动方框，修改框内区域" } }
}
enum CanvasAction { case fit, actualSize, zoomIn, zoomOut }
struct CanvasCommand: Equatable {
    var id = UUID()
    var action: CanvasAction = .fit
}

@MainActor final class ImageEditorModel: ObservableObject {
    let conversationID: String
    private let initialAssetID: String
    private unowned let app: AppModel
    private let sessionID: UUID?
    @Published private(set) var currentAsset: AssetRecord?
    @Published private(set) var image: PixelImage?
    @Published var selection = RegionSelection(width: 0, height: 0) { didSet { retainDraft() } }
    @Published var prompt = "" { didSet { retainDraft() } }
    @Published var tool = EditorTool.pan { didSet { retainDraft() } }
    @Published var zoom = 1.0
    @Published var command = CanvasCommand()
    @Published private(set) var isSubmitting = false
    @Published private(set) var lastRun: RunRecord?
    @Published var error: String?
    private var loaded = false
    init(app: AppModel, target: ImageEditorTarget, sessionID: UUID? = nil) {
        self.app = app; conversationID = target.conversationID; initialAssetID = target.assetID; self.sessionID = sessionID
    }
    var canSubmit: Bool {
        image != nil && !selection.isEmpty && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSubmitting && !app.isBusy && !app.isConnecting && app.hasConnection && (!app.isDemo || app.isFrontendDemo)
    }
    func load() {
        guard !loaded else { return }
        do {
            let saved = app.editorDraft(for: target)
            try display(app.editorAsset(initialAssetID, conversationID: conversationID))
            if let saved, saved.selection.width == selection.width, saved.selection.height == selection.height {
                selection = saved.selection; prompt = saved.prompt; tool = saved.tool
            }
            lastRun = app.editorFailure(for: target)
            error = lastRun?.error
        }
        catch { self.error = error.localizedDescription }
        loaded = true
    }
    private func display(_ asset: AssetRecord) throws {
        let pixels = try app.editorPixels(asset)
        currentAsset = asset; image = pixels
        selection = RegionSelection(width: pixels.width, height: pixels.height)
        command = CanvasCommand(action: .fit)
    }
    func validateTarget() {
        guard let currentAsset else { return }
        do { _ = try app.editorAsset(currentAsset.id, conversationID: conversationID) }
        catch { self.error = error.localizedDescription }
    }
    func perform(_ action: CanvasAction) { command = CanvasCommand(action: action) }
    private var target: ImageEditorTarget { .init(conversationID: conversationID, assetID: initialAssetID) }
    private func retainDraft() {
        guard loaded, image != nil else { return }
        app.retainEditorDraft(.init(selection: selection, prompt: prompt, tool: tool), for: target, sessionID: sessionID)
    }
    func annotate() { tool = .pen }
    func erase() {
        tool = .pen
        let instruction = "移除选中的内容，并自然补全背景，保持其余部分不变。"
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { prompt = instruction }
        else if !prompt.contains(instruction) { prompt += "\n" + instruction }
    }
    func addComment() {
        if let sessionID, app.imageWorkspace?.id != sessionID { return }
        guard let currentAsset else { return }
        if app.useReference(currentAsset) { app.closeImageWorkspace(sessionID: sessionID) }
        else { error = app.error }
    }
    func submit() {
        guard !isSubmitting, let currentAsset else { return }
        isSubmitting = true; error = nil; lastRun = nil
        retainDraft()
        app.submitRegionEdit(conversationID: conversationID, assetID: currentAsset.id, selection: selection, instruction: prompt,
                             workspaceSessionID: sessionID) { [weak self] result in
            guard let self else { return }
            isSubmitting = false
            switch result {
            case .failure(let error): self.error = error.localizedDescription
            case .success(let outcome):
                lastRun = outcome.run
                if outcome.run.stage != .completed { error = outcome.run.error ?? "局部编辑未完成。修改要求和选区已保留。" }
            }
        }
    }
}
