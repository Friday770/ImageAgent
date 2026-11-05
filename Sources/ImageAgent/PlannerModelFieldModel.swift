import SwiftUI
import ImageAgentCore

/// A settings-only draft. Discovery can change suggestions, never the user's chosen ID.
@MainActor final class PlannerModelFieldModel: ObservableObject {
    @Published var value: String
    @Published private var suggestions: [String] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private struct Source: Equatable { let address: String; let key: String }
    private var source: Source
    private var savedValue: String
    private var requestID = UUID()
    private var fetchTask: Task<[String], Error>?
    private var isClosed = false

    init(value: String, address: String, key: String = "") {
        self.value = value; savedValue = value; source = .init(address: address, key: key)
    }
    var options: [String] {
        guard !isClosed else { return [] }
        var seen = Set<String>()
        return ([savedValue, PlannerModel.default, value] + suggestions).filter {
            guard (try? PlannerModel.validated($0)) == $0,
                  source.key.isEmpty || !$0.contains(source.key) else { return false }
            return seen.insert($0).inserted
        }
    }
    private func invalidate() {
        requestID = UUID(); fetchTask?.cancel(); fetchTask = nil
        suggestions = []; error = nil; isLoading = false
    }
    func sourceChanged(address: String, key: String) {
        let next = Source(address: address, key: key)
        guard source != next else { return }
        source = next; invalidate()
    }
    func reset(value: String, address: String, key: String) {
        invalidate(); isClosed = false; savedValue = value; self.value = value
        source = .init(address: address, key: key)
    }
    func close() {
        isClosed = true; invalidate(); source = .init(address: "", key: "")
    }
    func refresh(from app: AppModel) async {
        guard !isClosed else { return }
        invalidate()
        let source = source, requestID = requestID
        isLoading = true
        let fetch = Task { try await app.plannerModels(address: source.address, key: source.key) }
        fetchTask = fetch
        defer {
            if self.requestID == requestID { fetchTask = nil; isLoading = false }
        }
        do {
            let ids = try await withTaskCancellationHandler(operation: { try await fetch.value }, onCancel: { fetch.cancel() })
            guard !isClosed, !Task.isCancelled, self.source == source, self.requestID == requestID else { return }
            suggestions = ids
        } catch {
            guard !isClosed, !Task.isCancelled, !(error is CancellationError), self.source == source, self.requestID == requestID else { return }
            self.error = error.localizedDescription
        }
    }
}
