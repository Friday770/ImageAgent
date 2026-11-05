import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct ImageAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("ImageAgent") {
            Group {
                if let failure = model.startupError {
                    ContentUnavailableView("无法打开本地数据", systemImage: "externaldrive.badge.exclamationmark", description: Text(failure))
                } else if model.hasConnection { WorkspaceView(model: model) }
                else { ConnectionView(model: model) }
            }
            .frame(minWidth: 960, minHeight: 660)
            .tint(Brand.accent)
            .task { await model.start() }
            .onChange(of: model.settings) { _, _ in model.persistSettings() }
            .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
        }
        .defaultSize(width: 1180, height: 830)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建会话") { model.newConversation() }.keyboardShortcut("n").disabled(!model.hasConnection || model.imageWorkspace != nil)
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { model.showSettings = true }.keyboardShortcut(",").disabled(model.imageWorkspace != nil)
            }
        }
    }
}
