import SwiftUI
import ImageAgentCore

enum Brand {
    static let accent = Color(red: 0.19, green: 0.40, blue: 0.33)
    static let paper = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(calibratedWhite: 0.16, alpha: 1) : NSColor(calibratedRed: 0.94, green: 0.93, blue: 0.88, alpha: 1) })
    static let canvas = Color(nsColor: .textBackgroundColor)
}
struct ErrorBanner: View {
    let text: String
    var body: some View { Label(text, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 9)).textSelection(.enabled) }
}
struct MessageView: View {
    @ObservedObject var model: AppModel
    let message: MessageRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if message.role == .user {
                HStack {
                    Spacer(minLength: 55)
                    VStack(alignment: .trailing, spacing: 9) {
                        if !message.assetIDs.isEmpty {
                            HStack(spacing: 8) {
                                ForEach(message.assetIDs, id: \.self) { id in
                                    if let asset = model.asset(id) { ImageReferenceThumbnail(model: model, asset: asset) }
                                }
                            }
                        }
                        Text(message.text).textSelection(.enabled).padding(15).foregroundStyle(.white)
                            .background(Color.blue, in: RoundedRectangle(cornerRadius: 16))
                        HStack(spacing: 14) {
                            Button { model.copyMessage(message) } label: { Label("复制", systemImage: "doc.on.doc") }
                                .accessibilityLabel("复制用户原话")
                            if model.canReturnToEdit(message) {
                                Button { model.returnToEdit(message) } label: { Label("返回编辑", systemImage: "arrow.uturn.backward") }
                                    .accessibilityLabel("返回编辑已取消的请求")
                            }
                        }.buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: 620, alignment: .trailing)
                }
            } else {
                Label("ImageAgent", systemImage: "sparkles").font(.caption.weight(.semibold)).foregroundStyle(Brand.accent)
                Text(message.text).textSelection(.enabled).font(.body).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading)
                if let prompt = message.detailedPrompt, !prompt.isEmpty {
                    EnhancedPromptCard(text: prompt, status: .validated)
                }
            }
            if message.role != .user {
                ForEach(message.assetIDs, id: \.self) { id in if let asset = model.asset(id) { ImageCard(model: model, asset: asset) } }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shared by the live planner and persisted assistant history, including pre-existing prompts.
struct EnhancedPromptCard: View {
    let text: String
    let status: PlanningPromptState.Status
    @State private var expanded: Bool
    init(text: String, status: PlanningPromptState.Status, initiallyExpanded: Bool = false) {
        self.text = text; self.status = status; _expanded = State(initialValue: initiallyExpanded)
    }
    private var statusText: String {
        switch status {
        case .planning: return "正在整理"
        case .validated: return "完整提示词"
        case .unfinished: return "未完成 · 未用于图片请求"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption.weight(.semibold))
                        Text("增强后的提示词").font(.callout.weight(.medium))
                    }
                }.buttonStyle(.plain).accessibilityLabel("增强后的提示词，\(expanded ? "收起" : "展开")")
                if status == .planning { ProgressView().controlSize(.mini) }
                Text(statusText).font(.caption).foregroundStyle(status == .unfinished ? .orange : .secondary)
                Spacer(minLength: 0)
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                } label: { Label(status == .validated ? "复制提示词" : "复制预览", systemImage: "doc.on.doc") }
                    .buttonStyle(.borderless).font(.caption)
            }
            if expanded {
                ScrollView {
                    Text(text).font(.callout).lineSpacing(5).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
                }.frame(minHeight: 55, maxHeight: 240)
                    .accessibilityLabel(status == .unfinished ? "未完成的提示词预览" : "增强后的提示词正文")
            }
        }.padding(14).background(Brand.paper.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.07)))
    }
}
struct ImageReferenceThumbnail: View {
    @ObservedObject var model: AppModel
    let asset: AssetRecord
    var body: some View {
        Button { model.openImageWorkspace(asset) } label: {
            Group {
                if let image = model.image(asset) { Image(nsImage: image).resizable().scaledToFit() }
                else { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary) }
            }.frame(width: 104, height: 88).background(TransparencyGrid())
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.10)))
        }.buttonStyle(.plain).help("查看与编辑参考图").accessibilityLabel("参考图，查看与编辑")
    }
}
struct TransparencyGrid: View {
    var body: some View {
        Canvas { context, size in
            let cell = 10.0
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.27)))
            for row in 0..<Int(ceil(size.height / cell)) {
                for column in 0..<Int(ceil(size.width / cell)) where (row + column).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: Double(column) * cell, y: Double(row) * cell, width: cell, height: cell)), with: .color(Color(white: 0.34)))
                }
            }
        }.accessibilityHidden(true)
    }
}
struct ImageCard: View {
    @ObservedObject var model: AppModel
    let asset: AssetRecord
    private func openEditor() { model.openImageWorkspace(asset) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let image = model.image(asset) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 520, maxHeight: 420).background(TransparencyGrid()).contentShape(Rectangle()).onTapGesture { openEditor() }.help("查看与编辑图片")
            } else { ContentUnavailableView("原始图片文件不可用", systemImage: "photo.badge.exclamationmark").frame(width: 460, height: 230) }
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Button { openEditor() } label: { Label("查看与编辑", systemImage: "arrow.up.left.and.arrow.down.right") }.help("在当前窗口中打开图片工作区")
                    Spacer()
                    Button { model.useReference(asset) } label: { Image(systemName: "photo.badge.plus") }.help("作为参考继续编辑")
                    Button { model.export(asset) } label: { Image(systemName: "square.and.arrow.up") }.help("保存副本")
                }.buttonStyle(.borderless)
                if let warning = asset.modelWarning { Label(warning, systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange) }
            }.padding(13).background(.background)
        }.frame(maxWidth: 520).clipShape(RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(0.09)))
    }
}
