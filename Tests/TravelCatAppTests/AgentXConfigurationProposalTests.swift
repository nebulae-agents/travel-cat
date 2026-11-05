import XCTest
@testable import TravelCatApp

final class AgentXConfigurationProposalTests: XCTestCase {
    func testParsesBodyAndCharacterChangesWithReasons() throws {
        let value = try AgentXConfigurationProposal.parse(#"{"summary":"更简短","changes":[{"id":"a","dimension":"body","value":"Answer briefly.","reason":"用户要求"},{"id":"b","dimension":"voice","value":"简洁","reason":"统一语气"}]}"#)
        XCTAssertEqual(value.changes.map(\.dimension), ["body", "voice"])
        XCTAssertEqual(value.changes.last?.reason, "统一语气")
    }
    func testLegacyBodyIsOneReviewableChange() throws {
        let value = try AgentXConfigurationProposal.parse("Be concise.")
        XCTAssertEqual(value.changes.count, 1)
        XCTAssertEqual(value.changes[0].dimension, "body")
        XCTAssertEqual(value.changes[0].value, "Be concise.")
    }
    func testRejectsUnknownFieldsDimensionsDuplicatesAndEmptyChanges() {
        for text in [
            #"{"summary":"x","changes":[],"permissions":"all"}"#,
            #"{"summary":"x","changes":[]}"#,
            #"{"summary":"x","changes":[{"id":"a","dimension":"permissions","value":"x","reason":"x"}]}"#,
            #"{"summary":"x","changes":[{"id":"a","dimension":"voice","value":"x","reason":"x","tool":"exec"}]}"#,
            #"{"summary":"x","changes":[{"id":"a","dimension":"voice","value":"x","reason":"x"},{"id":"a","dimension":"body","value":"y","reason":"y"}]}"#,
            #"{"summary":"x","changes":[{"id":"a","dimension":"voice","value":"x","reason":"x"},{"id":"b","dimension":"voice","value":"y","reason":"y"}]}"#,
            "{invalid JSON", "   "
        ] { XCTAssertThrowsError(try AgentXConfigurationProposal.parse(text), text) }
    }
    func testAllThirteenSupportedDimensionsAndCountLimit() throws {
        let dimensions = ["body"] + AgentXCharacterDimension.allCases.map(\.rawValue)
        let entries = dimensions.enumerated().map { index, dimension in
            ["id": "change-\(index)", "dimension": dimension, "value": "value", "reason": "reason"]
        }
        func encoded(_ changes: [[String: String]]) throws -> String {
            String(data: try JSONSerialization.data(withJSONObject: ["summary": "all", "changes": changes]), encoding: .utf8)!
        }
        XCTAssertEqual(try AgentXConfigurationProposal.parse(encoded(entries)).changes.count, 13)
        XCTAssertThrowsError(try AgentXConfigurationProposal.parse(encoded(entries + [["id": "extra", "dimension": "body", "value": "x", "reason": "x"]])))
    }
    func testParsesJSONCodeFenceButDoesNotTreatMalformedJSONAsBody() throws {
        let json = #"{"summary":"x","changes":[{"id":"a","dimension":"model","value":"偏好严谨推理","reason":"人物偏好"}]}"#
        XCTAssertEqual(try AgentXConfigurationProposal.parse("```json\n" + json + "\n```").changes.first?.dimension, "model")
        XCTAssertThrowsError(try AgentXConfigurationProposal.parse("```json\ninvalid\n```"))
    }
}
