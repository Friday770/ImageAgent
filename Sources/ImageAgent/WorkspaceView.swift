import SwiftUI
import ImageAgentCore

struct WorkspaceView: View {
    @ObservedObject var model: AppModel
    @State private var deleteID: String?
    @State private var confirmDelete = false
    @State private var composerHeight: CGFloat = 48
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "square.stack.3d.up.fill").foregroundStyle(Brand.accent)
                    Text("ImageAgent").font(.system(.title3, design: .rounded, weight: .semibold))
                    Spacer()
                }.padding(.horizontal, 20).padding(.top, 22)
                Button(action: model.newConversation) { Label("新建会话", systemImage: "square.and.pencil").frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5) }
                    .buttonStyle(.bordered).padding(.horizontal, 16)
                List(selection: $model.selectedID) {
                    Section("你的创作") {
                        ForEach(model.conversations) { conversation in
                            HStack(spacing: 9) {
                                Image(systemName: "bubble.left").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(conversation.title).lineLimit(1).font(.callout)
                                    Text(conversation.updatedAt, format: .dateTime.month(.abbreviated).day()).font(.caption2).foregroundStyle(.tertiary)
                                }
                                if model.isBusy && model.activeConversationID == conversation.id { ProgressView().controlSize(.mini) }
                            }.padding(.vertical, 5).tag(conversation.id)
                                .contextMenu {
                                    Button("删除会话…", role: .destructive) { deleteID = conversation.id; confirmDelete = true }.disabled(model.isBusy && model.activeConversationID == conversation.id)
                                }
                        }
                    }
                }.listStyle(.sidebar)
                HStack {
                    Circle().fill(model.isDemo ? .orange : Brand.accent).frame(width: 7, height: 7)
                    Text(model.isDemo ? "离线演示" : "已连接到你的服务").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.showSettings = true } label: { Image(systemName: "gearshape") }.buttonStyle(.plain).help("设置")
                }.padding(18)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 300)
        } detail: {
            VStack(spacing: 0) {
                if model.isStreamingDemo {
                    HStack {
                        Button("离线流式演示") { model.startStreamingDemo() }.disabled(model.isBusy)
                        Button("模拟中断") { model.startStreamingDemo(interrupt: true) }.disabled(model.isBusy)
                        Spacer()
                    }.padding(.horizontal, 28).padding(.vertical, 18)
                }
                timeline
                composer
            }.background(Brand.canvas)
        }
        .disabled(model.imageWorkspace != nil)
        .allowsHitTesting(model.imageWorkspace == nil)
        .accessibilityHidden(model.imageWorkspace != nil)
        .overlay {
            if let session = model.imageWorkspace {
                ImageEditorView(app: model, session: session).id(session.id)
            }
        }
        .onChange(of: model.selectedID) { _, _ in model.selectionChanged() }
        .confirmationDialog("删除此会话及其本地图片？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除会话", role: .destructive) { if let id = deleteID { model.deleteConversation(id) } }
            Button("取消", role: .cancel) {}
        } message: { Text("此操作会移除会话历史和原始图片。") }
    }
    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if model.messages.isEmpty {
                        VStack(spacing: 18) {
                            Image(systemName: "sparkles").font(.system(size: 38, weight: .light)).foregroundStyle(Brand.accent)
                            Text("从一个想法开始").font(.system(size: 27, weight: .medium))
                            HStack {
                                suggestion("暖色的山间湖泊插画")
                                suggestion("极简咖啡品牌海报")
                            }
                        }.frame(maxWidth: .infinity).padding(.vertical, 78)
                    }
                    ForEach(model.messages) { message in MessageView(model: model, message: message).id(message.id) }
                    ForEach(model.pendingAssets) { asset in ImageCard(model: model, asset: asset) }
                    if let prompt = model.visiblePlanningPrompt {
                        EnhancedPromptCard(text: prompt.text, status: prompt.status, initiallyExpanded: true).id(prompt.runID)
                    }
                    if model.isBusy, model.activeConversationID == model.selectedID {
                        HStack(spacing: 10) { ProgressView().controlSize(.small); Text(model.isCancelling ? "正在取消；已返回的图片会保留…" : (model.activeRun?.stage.label ?? "正在记录任务…")).font(.callout).foregroundStyle(.secondary) }.padding(.vertical, 8)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(.horizontal, 32).padding(.vertical, 28).frame(maxWidth: 900).frame(maxWidth: .infinity)
            }
            .onChange(of: model.messages.count) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: model.pendingAssets.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.visiblePlanningPrompt?.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
    private func suggestion(_ text: String) -> some View {
        Button(text) { model.draft = text }.buttonStyle(.bordered).controlSize(.small)
    }
    private var composer: some View {
        VStack(spacing: 12) {
            if let error = model.error { ErrorBanner(text: error) }
            if model.failedEditorTarget?.conversationID == model.selectedID {
                HStack {
                    Text("上次编辑的要求与选区已保留。").font(.caption).foregroundStyle(.secondary)
                    Button("重新打开编辑", action: model.reopenFailedEdit).font(.caption)
                    Spacer()
                }
            }
            if let reference = model.selectedReference {
                HStack {
                    if let image = model.image(reference) {
                        Button { model.openImageWorkspace(reference) } label: {
                            Image(nsImage: image).resizable().scaledToFit().frame(width: 38, height: 38).background(TransparencyGrid()).clipShape(RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain).help("查看与编辑参考图")
                    }
                    Spacer()
                    Button { model.referenceID = nil; model.error = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                }.padding(10).background(Brand.paper, in: RoundedRectangle(cornerRadius: 10))
            }
            VStack(spacing: 10) {
                ComposerTextView(text: $model.draft, focusID: model.composerFocusID, conversationID: model.selectedID,
                                 onPaste: { _ = model.pasteReference(from: $0) }, onSubmit: model.send, height: $composerHeight)
                    .frame(height: composerHeight).padding(.horizontal, 4)
                HStack(spacing: 10) {
                    Button(action: model.uploadReference) { Image(systemName: "paperclip").font(.system(size: 17)) }.buttonStyle(.borderless).help("上传参考图片").disabled(model.isBusy)
                    Picker("图片模型", selection: $model.settings.selection.model) {
                        ForEach(ImageModel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().frame(width: 193)
                    Picker("尺寸", selection: $model.settings.selection.size) { ForEach(ImageSize.allCases, id: \.self) { Text($0.rawValue == "auto" ? "自动尺寸" : $0.rawValue).tag($0) } }.labelsHidden().frame(width: 125)
                    Picker("质量", selection: $model.settings.selection.quality) { ForEach(ImageQuality.allCases, id: \.self) { Text(qualityLabel($0)).tag($0) } }.labelsHidden().frame(width: 102)
                    Spacer(minLength: 0)
                    if model.isBusy {
                        Button(action: model.cancel) { Label("取消", systemImage: "stop.fill") }.disabled(model.isCancelling).buttonStyle(.bordered)
                    } else {
                        Button(action: model.send) { Image(systemName: "arrow.up").font(.body.weight(.semibold)).frame(width: 20, height: 22) }.keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent).disabled(!model.canSend).help("发送（⌘↩）")
                    }
                }.controlSize(.small)
            }.padding(14).background(.background, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.1)))
        }.padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 18)
    }
    private func qualityLabel(_ quality: ImageQuality) -> String {
        switch quality { case .auto: return "自动质量"; case .low: return "低质量"; case .medium: return "中等质量"; case .high: return "高质量" }
    }
}
