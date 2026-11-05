import Foundation
import Testing
@testable import ImageAgentCore

@Suite struct CredentialsTests {
    @Test func ordinaryLaunchNeverReadsEnvironmentCredentials() throws {
        var reads: [String] = []; var clears: [String] = []
        let connection = try EnvironmentConnection.consumeIfRequested(arguments: ["ImageAgent"], read: { name in reads.append(name); return "unexpected" }, clear: { clears.append($0) })
        #expect(connection == nil && reads.isEmpty && clears.isEmpty)
    }
    @Test func explicitConfigurationConsumesAndClearsOnlyItsTwoVariables() throws {
        var values = ["OPENAI_BASE_URL": "https://api.example.com/v1", "OPENAI_API_KEY": "dummy-test-credential", "OTHER": "retained"]
        let consumed = try EnvironmentConnection.consumeIfRequested(arguments: ["ImageAgent", "--configure-from-environment"], read: { values[$0] }, clear: { values.removeValue(forKey: $0) })
        let connection = try #require(consumed)
        #expect(connection.baseURL == "https://api.example.com/v1")
        #expect(connection.apiKey == "dummy-test-credential")
        #expect(values == ["OTHER": "retained"])
    }
    @Test func invalidBootstrapStillClearsConsumedVariables() {
        var values = ["OPENAI_BASE_URL": "https://api.example.com/v1"]
        #expect(throws: (any Error).self) {
            try EnvironmentConnection.consumeIfRequested(arguments: ["--configure-from-environment"], read: { values[$0] }, clear: { values.removeValue(forKey: $0) })
        }
        #expect(values.isEmpty)
    }
}
