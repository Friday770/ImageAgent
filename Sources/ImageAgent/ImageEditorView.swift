import SwiftUI
import ImageAgentCore

/// A presentation layer inside the chat window. Accepted work is owned by AppModel.
struct ImageEditorView: View {
    @ObservedObject var app: AppModel
    @StateObject private var editor: ImageEditorModel
    @FocusState private var promptFocused: Bool
    private let sessionID: UUID

    init(app: AppModel, session: ImageWorkspaceSession) {
        self.app = app; sessionID = session.id
        _editor = StateObject(wrappedValue: ImageEditorModel(app: app, target: session.target, sessionID: session.id))
    }
    var body: some View {
        ZStack {
            Color(white: 0.065).ignoresSafeArea()
            if let image = editor.image {
                EditorCanvas(image: image, selection: $editor.selection, tool: editor.tool,
                             command: editor.command, zoom: $editor.zoom, enabled: !editor.isSubmitting,
                             onEscape: close)
                    .padding(.top, 76).padding(.bottom, editor.tool == .pan ? 184 : 232)
            } else {
                ContentUnavailableView("图片不可用", systemImage: "photo.badge.exclamationmark", description: Text(editor.error ?? "无法打开原始图片。"))
            }
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 20)
                VStack(spacing: 12) { imageActions; editBar }
            }.padding(20)
        }
        .preferredColorScheme(.dark)
        .tint(.blue)
        .task { editor.load(); promptFocused = true }
        .onChange(of: app.conversations) { _, _ in editor.validateTarget() }
        .onExitCommand(perform: close)
        .accessibilityIdentifier("image-workspace")
    }
    private func close() { app.closeImageWorkspace(sessionID: sessionID) }
    private var topBar: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("图像").font(.callout.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 14)
            Spacer(minLength: 12)
            HStack(spacing: 14) {
                Button { editor.perform(.zoomOut) } label: { Image(systemName: "minus.magnifyingglass") }.help("缩小")
                Menu {
                    Button("适应窗口") { editor.perform(.fit) }
                    Button("100%") { editor.perform(.actualSize) }
                } label: { Text("\(Int((editor.zoom * 100).rounded()))%") .font(.callout.monospacedDigit()).frame(minWidth: 48) }
                    .menuStyle(.borderlessButton).fixedSize().help("缩放")
                Button { editor.perform(.zoomIn) } label: { Image(systemName: "plus.magnifyingglass") }.help("放大")
                Divider().frame(height: 18)
                Button { if let asset = editor.currentAsset { app.export(asset) } } label: { Image(systemName: "arrow.down.to.line") }
                    .disabled(editor.currentAsset == nil).help("下载图片")
                Button(action: close) { Image(systemName: "xmark") }.help("关闭（Esc）").accessibilityLabel("关闭图片工作区")
            }.padding(.horizontal, 18).padding(.vertical, 14).floatingPanel()
        }.buttonStyle(.plain).font(.callout)
    }
    private var imageActions: some View {
        HStack(spacing: 20) {
            Button { editor.annotate(); promptFocused = true } label: { Label("标注", systemImage: "pencil.tip.crop.circle") }
            Button(action: editor.addComment) { Label("添加评论", systemImage: "text.bubble") }
            Button { editor.erase(); promptFocused = true } label: { Label("擦除", systemImage: "eraser") }
        }.disabled(editor.isSubmitting).buttonStyle(.plain).font(.callout)
            .padding(.horizontal, 20).padding(.vertical, 13).floatingPanel()
    }
    private var editBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = editor.error { ErrorBanner(text: error) }
            if let warning = editor.currentAsset?.modelWarning { ErrorBanner(text: warning) }
            if let run = editor.lastRun, run.stage != .completed, run.recoveryRelativePath != nil {
                Button("查看已保留的局部结果…") { app.revealRecovery(run) }
            }
            if editor.tool != .pan {
                HStack(spacing: 14) {
                    ForEach(EditorTool.allCases, id: \.self) { tool in
                        Button { editor.tool = tool } label: {
                            Label(tool.title, systemImage: tool.symbol).padding(.horizontal, 9).padding(.vertical, 6)
                                .background(editor.tool == tool ? Color.white.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        }.help(tool.hint)
                    }
                    Spacer(minLength: 8)
                    Button { editor.selection.undo() } label: { Image(systemName: "arrow.uturn.backward") }.help("撤销选区").disabled(!editor.selection.canUndo)
                    Button("清空") { editor.selection.clear() }.disabled(editor.selection.isEmpty)
                }.disabled(editor.isSubmitting).buttonStyle(.plain).font(.callout)
                Text(editor.tool.hint).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 14) {
                TextField("选择区域，描述想怎样修改…", text: $editor.prompt, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...4).focused($promptFocused)
                    .disabled(editor.isSubmitting).padding(.vertical, 7)
                if editor.isSubmitting {
                    ProgressView().controlSize(.small).padding(9)
                } else {
                    Button(action: editor.submit) { Image(systemName: "arrow.up").font(.body.weight(.semibold)).frame(width: 22, height: 24) }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                        .disabled(!editor.canSubmit).help("修改选区（⌘↩）")
                }
            }
        }.padding(16).frame(maxWidth: 700).floatingPanel()
    }
}

private extension View {
    func floatingPanel() -> some View {
        background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.10)))
            .shadow(color: .black.opacity(0.24), radius: 16, y: 6)
    }
}
