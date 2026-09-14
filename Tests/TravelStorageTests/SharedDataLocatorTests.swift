import Foundation
import XCTest
@testable import TravelStorage

final class SharedDataLocatorTests: XCTestCase {
    func testEnvironmentPathTakesPrecedenceOverBookmark() throws {
        let resolved = try SharedDataLocator().resolve(
            environment: ["TRAVEL_CAT_DATA": "/tmp/one/../chosen"],
            bookmarkData: Data("not a bookmark".utf8)
        )

        XCTAssertEqual(resolved, URL(fileURLWithPath: "/tmp/chosen").standardizedFileURL)
    }

    func testMissingEnvironmentAndBookmarkRequiresSelection() {
        XCTAssertThrowsError(try SharedDataLocator().resolve(environment: [:], bookmarkData: nil)) { error in
            guard case DataLocationError.selectionRequired = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}
