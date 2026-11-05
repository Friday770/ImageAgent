import Foundation
import Testing
@testable import ImageAgentCore

@Suite struct ModelsTests {
    @Test func exactImageModelsAndDefault() {
        #expect(ImageModel.allCases.map(\.rawValue) == [
            "gpt-image-2", "gpt-image-2.5-flare", "gpt-image-2.5", "gpt-image-2.5-sunburst"
        ])
        #expect(ImageModel.default.rawValue == "gpt-image-2")
    }

    @Test func responsesOutputJSONRoundtrip() throws {
        let raw = Data(#"{"type":"reasoning","id":"rs_1","summary":[],"encrypted_content":"opaque==","extra":{"flag":true,"count":2,"nil":null}}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: raw)
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) == value)
        #expect(value["encrypted_content"]?.string == "opaque==")
    }
}
