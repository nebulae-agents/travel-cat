import Foundation
import XCTest
@testable import TravelStorage

final class PostcardPreparationRequestTests: XCTestCase {
    let event = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    var source: String { "postcards/\(event)/scene.png" }
    func testActionSpecificStrictRequestAndBoundedInput() throws {
        let begin = "{\"action\":\"begin\",\"eventId\":\"\(event)\",\"sourceRelativePath\":\"\(source)\"}"
        XCTAssertEqual(try PostcardPreparationRequest.decode(Data(begin.utf8)).eventId.uuidString.lowercased(), event)
        let ref = "{\"relativePath\":\"postcards/\(event)/fallback.json\",\"sha256\":\"\(String(repeating: "a", count: 64))\"}"
        let finish = "{\"action\":\"finish\",\"eventId\":\"\(event)\",\"sourceRelativePath\":\"\(source)\",\"fallbackReference\":\(ref),\"generatedImagePath\":\"/trusted/ink.png\"}"
        XCTAssertNoThrow(try PostcardPreparationRequest.decode(Data(finish.utf8)))
        for bad in [begin.replacingOccurrences(of: "\"begin\"", with: "\"other\""),
                    begin.replacingOccurrences(of: "\"action\":", with: "\"root\":\"/tmp\",\"action\":"),
                    begin.replacingOccurrences(of: "\"action\":", with: "\"action\":\"finish\",\"action\":"),
                    finish.replacingOccurrences(of: "\"sha256\":", with: "\"extra\":0,\"sha256\":"),
                    finish.replacingOccurrences(of: "\"sha256\":", with: "\"sha256\":\"a\",\"sha256\":"),
                    finish.replacingOccurrences(of: ref, with: "null"),
                    finish.replacingOccurrences(of: "\"finish\"", with: "\"begin\""),
                    begin + String(repeating: " ", count: 65_537)] {
            XCTAssertThrowsError(try PostcardPreparationRequest.decode(Data(bad.utf8)), bad.prefix(100).description)
        }
    }
}
