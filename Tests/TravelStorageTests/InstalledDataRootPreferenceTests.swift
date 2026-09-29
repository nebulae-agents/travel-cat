import Foundation
import XCTest
@testable import TravelStorage

final class InstalledDataRootPreferenceTests: XCTestCase {
    func testMissingValidAndInvalidPreferences() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        XCTAssertNil(try InstalledDataRootPreference.load(applicationSupportDirectory: support))
        let directory = support.appendingPathComponent("TravelCat")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("data-location.json")
        try Data(#"{"schemaVersion":1,"path":"/old history/TravelPetData"}"#.utf8).write(to: file)
        XCTAssertEqual(try InstalledDataRootPreference.load(applicationSupportDirectory: support)?.path, "/old history/TravelPetData")
        for invalid in ["broken", #"{"schemaVersion":2,"path":"/old"}"#, #"{"schemaVersion":1,"path":"relative"}"#, #"{"schemaVersion":1,"path":"/"}"#] {
            try Data(invalid.utf8).write(to: file)
            XCTAssertThrowsError(try InstalledDataRootPreference.load(applicationSupportDirectory: support))
        }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: "/nonexistent")
        XCTAssertThrowsError(try InstalledDataRootPreference.load(applicationSupportDirectory: support))
    }
}
