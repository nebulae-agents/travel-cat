import XCTest
@testable import AgentXAppSDK

final class FrontendContractTests: XCTestCase {
    func testModuleContractIsPortableAndRejectsInvalidActions() throws {
        let json = Data(#"{"schemaVersion":1,"title":"Writing room","modules":[{"id":"draft","title":"Draft","kind":"form","fields":[{"id":"topic","label":"Topic","multiline":false}],"submit":{"title":"Write","prompt":"Write about {{topic}}"}}]}"#.utf8)
        let contract = try JSONDecoder().decode(AppFrontendContract.self, from: json)
        try contract.validate()
        XCTAssertEqual(try contract.prompt(moduleID: "draft", values: ["topic":"rain"]), "Write about rain")
        XCTAssertThrowsError(try contract.prompt(moduleID: "draft", values: [:]))
        let unicode = AppFrontendContract(title: "Unicode", modules: [.init(id: "draft", title: "Draft", fields: [.init(id: "x", label: "X")], submit: .init(title: "Send", prompt: "{{x}}{{x}}"))])
        XCTAssertThrowsError(try unicode.prompt(moduleID: "draft", values: ["x": String(repeating: "汉", count: 20_000)]))
        let unknown = Data(String(decoding: json, as: UTF8.self).replacingOccurrences(of: "form", with: "execute-shell").utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AppFrontendContract.self, from: unknown).validate())
        let badPath = Data(String(decoding: json, as: UTF8.self).replacingOccurrences(of: "\"draft\"", with: "\"../draft\"").utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AppFrontendContract.self, from: badPath).validate())
        let unknownField = Data(String(decoding: json, as: UTF8.self).replacingOccurrences(of: "{{topic}}", with: "{{secret}}").utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AppFrontendContract.self, from: unknownField).validate())
    }
}
