import XCTest
@testable import Stocked

final class AIResponseDecoderTests: XCTestCase {
    func testExtractsJSONFromMarkdownFenceAndProse() throws {
        let text = "Result:\n```json\n{\"schemaVersion\":2,\"changes\":[]}\n```"
        let object = try AIResponseDecoder.jsonObject(from: text)
        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
    }

    func testBalancedExtractionIgnoresBracesInsideStrings() throws {
        let text = "prefix {\"title\":\"Use {carefully}\",\"steps\":[\"mix\"]} suffix"
        let object = try AIResponseDecoder.jsonObject(from: text)
        XCTAssertEqual(object["title"] as? String, "Use {carefully}")
    }

    func testTruncatedAnthropicEnvelopeThrows() throws {
        let envelope: [String: Any] = [
            "content": [["type": "text", "text": "{\"incomplete\":" ]],
            "stop_reason": "max_tokens",
            "schemaVersion": 2
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        XCTAssertThrowsError(try AIResponseDecoder.textResponse(from: data)) { error in
            XCTAssertEqual(error as? StockedServiceError, .truncatedResponse)
        }
    }

    func testReadsAllTextBlocks() throws {
        let envelope: [String: Any] = [
            "content": [
                ["type": "text", "text": "{\"a\":"],
                ["type": "tool_use", "name": "ignored"],
                ["type": "text", "text": "1}"]
            ],
            "stop_reason": "end_turn"
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let response = try AIResponseDecoder.textResponse(from: data)
        XCTAssertEqual((try AIResponseDecoder.jsonObject(from: response.text))["a"] as? Int, 1)
    }
}
