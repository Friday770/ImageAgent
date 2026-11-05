import SwiftUI

/// A settings-only draft; saved credentials never enter published application settings.
@MainActor final class APIKeyFieldModel: ObservableObject {
    @Published var address: String { didSet { if address != oldValue { clear() } } }
    @Published var key = "" { didSet { revision = UUID(); onSourceChange?(address, key) } }
    @Published var revealed = false
    private var revision = UUID()
    var onSourceChange: ((String, String) -> Void)?

    init(address: String) { self.address = address }
    func clear() { key = ""; revealed = false }

    func loadSavedKey(from app: AppModel) async {
        let address = address, revision = revision
        guard address == app.settings.endpoint else { return }
        do {
            let saved = try await app.savedAPIKeyForSettings(for: address)
            guard !Task.isCancelled, self.address == address, self.revision == revision else { return }
            key = saved ?? ""; revealed = false
        } catch {
            guard !Task.isCancelled, self.address == address, self.revision == revision else { return }
            app.connectionError = error.localizedDescription
        }
    }
}
