import SwiftUI

struct ConnectionView: View {
    @ObservedObject var model: AppModel
    @State private var revealKey = false
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                Label("ImageAgent", systemImage: "square.stack.3d.up.fill").font(.system(size: 22, weight: .semibold, design: .rounded))
                Spacer()
                Text("把想法，\n变成画面。").font(.system(size: 48, weight: .medium, design: .rounded)).lineSpacing(10)
                Text("说出你想看见的。\n从第一张图片，到每一次细微调整。")
                    .font(.title3).foregroundStyle(.secondary).lineSpacing(8)
                HStack(spacing: 12) {
                    ForEach(["自然语言创作", "连续编辑", "本地记忆"], id: \.self) { Text($0).font(.caption).padding(.horizontal, 12).padding(.vertical, 7).background(.white.opacity(0.7), in: Capsule()) }
                }
                Spacer()
                Text("原生 macOS · 图片与会话保存在你的 Mac").font(.caption).foregroundStyle(.secondary)
            }
            .padding(48).frame(maxWidth: .infinity, maxHeight: .infinity).background(Brand.paper)
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: "sparkles.rectangle.stack").font(.system(size: 34)).foregroundStyle(Brand.accent)
                VStack(alignment: .leading, spacing: 9) {
                    Text("连接你的图片服务").font(.system(size: 27, weight: .semibold))
                    Text("使用 API 地址和 Key 开始创作。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text("API 地址").font(.callout.weight(.medium))
                    TextField("https://api.example.com/v1", text: $model.endpointText).textFieldStyle(.roundedBorder).disabled(model.isConnecting)
                        .onChange(of: model.endpointText) { _, _ in model.keyText = "" }
                    Text("支持服务根地址或 /v1 地址").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text("API Key").font(.callout.weight(.medium))
                    HStack {
                        Group { if revealKey { TextField("输入此服务的 Key", text: $model.keyText) } else { SecureField("输入此服务的 Key", text: $model.keyText) } }.textFieldStyle(.roundedBorder).disabled(model.isConnecting)
                        Button { revealKey.toggle() } label: { Image(systemName: revealKey ? "eye.slash" : "eye") }.buttonStyle(.borderless).help(revealKey ? "隐藏 Key" : "显示 Key")
                    }
                    Text("Key 加密保存在 macOS 钥匙串，仅用于对应服务。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.error { ErrorBanner(text: error) }
                if model.isConnecting { HStack { ProgressView().controlSize(.small); Text(model.connectionNote).font(.caption) } }
                Button(action: model.connect) {
                    HStack { Text("验证并连接"); Spacer(); Image(systemName: "arrow.right") }.padding(.vertical, 7)
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.isConnecting || model.isConnectionDemo)
                Text(model.isConnectionDemo ? "离线连接页演示 · 不访问钥匙串或网络" : "规划模型 \(model.settings.plannerModel) · 四种图片模型可随时选择")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(48).frame(width: 470).frame(maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
