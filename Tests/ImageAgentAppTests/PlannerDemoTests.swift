import Foundation
import Testing
import ImageAgentCore
@testable import ImageAgent

private actor DemoRequestRecorder: HTTPTransport {
    let base: any HTTPTransport
    var requests: [URLRequest] = []
    init(_ base: any HTTPTransport) { self.base = base }
    func send(_ request: URLRequest) async throws -> HTTPResponse { requests.append(request); return try await base.send(request) }
    func stream(_ request: URLRequest, receive: @escaping @Sendable (HTTPStreamEvent) throws -> Void) async throws {
        requests.append(request); try await base.stream(request, receive: receive)
    }
}

@MainActor @Suite struct PlannerDemoTests {
    @Test func bothOfflineTransportsReceiveTheExactSelectedPlannerRequest() async throws {
        let selection = ImageSelection(model: .flare)
        let transports: [any HTTPTransport] = [FrontendDemoTransport(), SimulatedPlanningTransport(imageData: try frontendPNG(), selection: selection, delay: .zero)]
        for base in transports {
            let recorder = DemoRequestRecorder(base)
            let client = try APIClient(baseURL: "https://offline.invalid", apiKey: "fake-demo-key", plannerModel: "selected/demo-planner", transport: recorder)
            let task = Task { try await client.respond(input: [], selection: selection) }
            for _ in 0..<1000 { if await !recorder.requests.isEmpty { break }; try await Task.sleep(for: .milliseconds(1)) }
            if base is FrontendDemoTransport { task.cancel(); _ = try? await task.value }
            else { _ = try await task.value }
            let requests = await recorder.requests
            let request = try #require(requests.first)
            let json = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)
            #expect(requests.count == 1 && request.url?.path == "/v1/responses")
            #expect(json["model"]?.string == "selected/demo-planner" && json["reasoning"] == nil)
            #expect(json["tools"]?.array?.first?["parameters"]?["properties"]?["model"]?["enum"]?.array == [.string(ImageModel.flare.rawValue)])
        }
    }
    @Test func frontendAndStreamingAppLifecyclesUseSavedPlannerWithoutRealServices() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ImageAgentPlannerDemo-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore(paths: .init(root: root))
        try store.saveSettings(.init(plannerModel: "saved/demo-planner"))
        let unusedTransport = PlannerSettingsTransport(), unusedCredentials = FakeCredentials()
        let frontend = AppModel(store: store, arguments: ["ImageAgent", "--frontend-demo"], credentials: unusedCredentials, transport: unusedTransport, bundledDemoSession: nil)
        await frontend.start()
        #expect(frontend.hasConnection)
        #expect(try await frontend.plannerModels(address: frontend.settings.endpoint, key: "").contains("gpt-6-sol"))
        #expect(await frontend.saveConnection(address: "https://offline.invalid", key: "fake-demo-key", plannerModel: "changed/demo-planner"))
        let reopened = AppModel(store: try SQLiteStore(paths: .init(root: root)), arguments: ["ImageAgent", "--frontend-demo"], credentials: unusedCredentials, transport: unusedTransport, bundledDemoSession: nil)
        await reopened.start(); #expect(reopened.hasConnection && reopened.settings.plannerModel == "changed/demo-planner")
        reopened.draft = "offline selected planner"; reopened.send()
        for _ in 0..<1000 { if reopened.activeRun != nil { break }; try await Task.sleep(for: .milliseconds(1)) }
        #expect(reopened.activeRun?.plannerModel == "changed/demo-planner")
        reopened.cancel(); try await waitForIdle(reopened)
        let streaming = AppModel(store: try SQLiteStore(paths: .init(root: root)), arguments: ["ImageAgent", "--streaming-demo"], credentials: unusedCredentials, transport: unusedTransport, bundledDemoSession: nil)
        await streaming.start(); streaming.startStreamingDemo()
        for _ in 0..<1000 { if streaming.activeRun != nil { break }; try await Task.sleep(for: .milliseconds(1)) }
        #expect(streaming.activeRun?.plannerModel == "changed/demo-planner")
        streaming.cancel(); try await waitForIdle(streaming)
        #expect(await unusedTransport.requests.isEmpty)
        #expect(unusedCredentials.readsOnMain() == 0)
    }
    private func waitForIdle(_ app: AppModel) async throws {
        for _ in 0..<2000 { if !app.isBusy && !app.isConnecting { return }; try await Task.sleep(for: .milliseconds(1)) }
        Issue.record("Offline planner app did not finish")
    }
}
