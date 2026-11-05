import SwiftUI
import ImageAgentCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var resetNotice = false
    @StateObject private var apiKey: APIKeyFieldModel
    @StateObject private var planner: PlannerModelFieldModel
    @State private var didAttemptSave = false
    init(model: AppModel) {
        self.model = model
        _apiKey = StateObject(wrappedValue: APIKeyFieldModel(address: model.settings.endpoint))
        _planner = StateObject(wrappedValue: PlannerModelFieldModel(value: model.settings.plannerModel, address: model.settings.endpoint))
    }
    private var connectionDisabled: Bool { model.isBusy || model.isConnecting || (model.isDemo && !model.isFrontendDemo) || (model.isConnectionDemo && !model.isFrontendDemo) }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("设置").font(.title2.weight(.semibold)); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.isConnecting) }.padding(22)
            Form {
                Section("API 连接") {
                    TextField("API URL", text: $apiKey.address).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("API URL")
                        .disabled(connectionDisabled)
                    HStack {
                        Group {
                            if apiKey.revealed { TextField("输入 API Key", text: $apiKey.key) }
                            else { SecureField("输入 API Key", text: $apiKey.key) }
                        }.textFieldStyle(.roundedBorder).accessibilityLabel("API Key")
                        Button { apiKey.revealed.toggle() } label: { Image(systemName: apiKey.revealed ? "eye.slash" : "eye") }
                            .buttonStyle(.borderless).disabled(apiKey.key.isEmpty)
                            .help(apiKey.revealed ? "隐藏 API Key" : "显示 API Key")
                            .accessibilityLabel(apiKey.revealed ? "隐藏 API Key" : "显示 API Key")
                    }.disabled(connectionDisabled)
                    LabeledContent("当前连接", value: model.settings.endpoint).textSelection(.enabled)
                    HStack {
                        Text("规划模型")
                        PlannerModelComboBox(text: $planner.value, options: planner.options, isEnabled: !connectionDisabled)
                            .frame(minWidth: 260, maxWidth: .infinity).frame(height: 26)
                        Button { Task { await planner.refresh(from: model) } } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("刷新规划模型").help("刷新模型列表")
                            .disabled(connectionDisabled || planner.isLoading)
                        if planner.isLoading { ProgressView().controlSize(.small) }
                    }
                    if let error = planner.error { ErrorBanner(text: error) }
                    if let error = model.connectionError { ErrorBanner(text: error) }
                    if model.isConnecting {
                        HStack { ProgressView().controlSize(.small); Text(model.connectionNote).font(.caption) }
                    } else if didAttemptSave, model.connectionError == nil, !model.connectionNote.isEmpty {
                        Label(model.connectionNote, systemImage: "checkmark.circle").font(.caption).foregroundStyle(Brand.accent)
                    }
                    HStack {
                        Button("验证并保存") {
                            didAttemptSave = true
                            let candidateAddress = apiKey.address, candidateKey = apiKey.key, candidatePlanner = planner.value
                            Task {
                                if await model.saveConnection(address: candidateAddress, key: candidateKey, plannerModel: candidatePlanner) {
                                    apiKey.address = model.settings.endpoint
                                    apiKey.revealed = false
                                    planner.reset(value: model.settings.plannerModel, address: apiKey.address, key: apiKey.key)
                                    await apiKey.loadSavedKey(from: model)
                                }
                            }
                        }.buttonStyle(.borderedProminent).disabled(connectionDisabled)
                        Button("取消编辑") {
                            apiKey.address = model.settings.endpoint; apiKey.clear(); didAttemptSave = false; model.connectionError = nil
                            planner.reset(value: model.settings.plannerModel, address: apiKey.address, key: apiKey.key)
                            Task { await apiKey.loadSavedKey(from: model) }
                        }
                            .disabled(model.isBusy || model.isConnecting)
                        Spacer()
                        Button("断开并移除 Key", role: .destructive) { model.disconnect() }.disabled(connectionDisabled)
                    }
                    if model.isBusy { Text("当前任务结束后可更改连接。").font(.caption).foregroundStyle(.secondary) }
                }
                Section("当前会话的短期记忆") {
                    Stepper("时间窗口：\(model.settings.memory.hours) 小时", value: $model.settings.memory.hours, in: 1...720)
                    Stepper("最多轮数：\(model.settings.memory.turns) 轮", value: $model.settings.memory.turns, in: 1...100)
                    HStack {
                        Button("清空当前会话记忆") { model.resetMemory(); resetNotice = true }.disabled(model.selectedID == nil || model.isBusy)
                        if resetNotice { Label("记忆已清空，历史已保留", systemImage: "checkmark.circle").font(.caption).foregroundStyle(Brand.accent) }
                    }
                    if let reset = model.currentConversation?.memoryResetAt { Text("上次清空：\(reset.formatted())").font(.caption2).foregroundStyle(.secondary) }
                }
                Section("本地数据") {
                    Text(model.dataPath).font(.caption.monospaced()).textSelection(.enabled)
                    Button("在 Finder 中打开") { model.openDataFolder() }
                }
            }.formStyle(.grouped)
        }.frame(width: 690, height: 740)
            .onAppear {
                model.connectionError = nil
                apiKey.address = model.settings.endpoint; apiKey.clear()
                planner.reset(value: model.settings.plannerModel, address: apiKey.address, key: apiKey.key)
                apiKey.onSourceChange = { address, key in planner.sourceChanged(address: address, key: key) }
            }
            .task {
                await apiKey.loadSavedKey(from: model)
                planner.sourceChanged(address: apiKey.address, key: apiKey.key)
                if !connectionDisabled, !apiKey.key.isEmpty { await planner.refresh(from: model) }
            }
            .onDisappear { planner.close(); apiKey.onSourceChange = nil; apiKey.clear() }
    }
}
