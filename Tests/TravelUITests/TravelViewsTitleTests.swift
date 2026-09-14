import XCTest
import TravelCore
@testable import TravelUI

final class TravelViewsTitleTests: XCTestCase {
    func testDetailAndAlbumTitleContractUsesCompactResolvedLocation() {
        let location = Location(
            country: "China",
            city: "Suzhou",
            place: "Master of the Nets Garden"
        )
        let displayLocation = PostcardDisplayLocation()

        XCTAssertEqual(displayLocation.resolveCompact(location), "苏州·网师园")
        XCTAssertEqual(
            displayLocation.resolveSpoken(location),
            "China · Suzhou · Master of the Nets Garden"
        )
    }

    func testBothProductionTitlesUseTheResolverInsteadOfRawPlace() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/TravelUI/TravelViews.swift"))
        XCTAssertEqual(source.components(separatedBy: "Text(PostcardDisplayLocation().resolveCompact(event.location))").count - 1, 2)
        XCTAssertFalse(source.contains("Text(event.location?.place ??"))
    }
}
