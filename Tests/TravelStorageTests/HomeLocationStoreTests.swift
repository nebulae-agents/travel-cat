import Foundation
import XCTest
import TravelCore
import TravelStorage

final class HomeLocationStoreTests: XCTestCase {
    func testHomeLocationSurvivesExportAndHistoryClear() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: destination) }
        let repository = try TravelRepository(root: root)
        let store = HomeLocationStore(root: root)
        let home = HomeLocation(city: "广州", source: .manual, updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try store.save(.init(location: home, ipLookupEnabled: true))
        _ = try repository.export(to: destination)
        XCTAssertEqual(try HomeLocationStore(root: destination).load().location, home)
        _ = try repository.clearHistory()
        XCTAssertEqual(try store.load().location, home, "clearing a trip must not reset the user's home")
    }

    func testInvalidLocationFailsClosedWithoutRewritingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try TravelRepository(root: root)
        let store = HomeLocationStore(root: root)
        let broken = Data(#"{"schemaVersion":99,"location":null}"#.utf8)
        try broken.write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.url), broken)
        XCTAssertThrowsError(try store.save(.init(location: .init(city: "\n", source: .manual, updatedAt: Date()))))
        XCTAssertEqual(try Data(contentsOf: store.url), broken)
    }
}
