import Foundation
import XCTest
import TravelCore
@testable import TravelStorage

final class TravelSettingsTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TravelSettingsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testBootstrapRoundTripAndDoesNotOverwrite() throws {
        let root = try temporaryDirectory()
        let store = TravelSettingsStore(root: root)
        XCTAssertEqual(try store.load(), TravelSettings())

        let changed = TravelSettings(mode: .fast, quietStart: 20, quietEnd: 7)
        try store.save(changed)
        XCTAssertEqual(try TravelSettingsStore(root: root).load(), changed)
        _ = try TravelRepository(root: root)
        XCTAssertEqual(try store.load(), changed)
    }

    func testFastTestEnabledProjectsOnlyFromModeAndIsNotPersistedSeparately() throws {
        XCTAssertFalse(TravelSettings(mode: .daily).isFastTestEnabled)
        XCTAssertTrue(TravelSettings(mode: .fast).isFastTestEnabled)

        let encoded = try XCTUnwrap(
            String(data: JSONEncoder().encode(TravelSettings(mode: .fast)), encoding: .utf8)
        )
        XCTAssertFalse(encoded.contains("isFastTestEnabled"))

        let legacy = Data(
            #"{"schemaVersion":1,"mode":"daily","quietStart":22,"quietEnd":8,"isFastTestEnabled":true}"#.utf8
        )
        XCTAssertFalse(try JSONDecoder().decode(TravelSettings.self, from: legacy).isFastTestEnabled)
    }

    func testRejectsCorruptionAndCanonicalizesHours() throws {
        let root = try temporaryDirectory()
        let store = TravelSettingsStore(root: root)
        _ = try store.load()
        try Data("not json".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(TravelSettings(mode: .daily, quietStart: -1, quietEnd: 27).quietStart, 23)
        XCTAssertEqual(TravelSettings(mode: .daily, quietStart: -1, quietEnd: 27).quietEnd, 3)
        let decoded = try JSONDecoder().decode(
            TravelSettings.self,
            from: Data(#"{"schemaVersion":1,"mode":"daily","quietStart":-1,"quietEnd":27}"#.utf8)
        )
        XCTAssertEqual(decoded.quietStart, 23)
        XCTAssertEqual(decoded.quietEnd, 3)
    }

    func testCLIEnvironmentModeOverridesSettingsAndAbsentEnvironmentUsesSettings() throws {
        let root = try temporaryDirectory()
        try TravelSettingsStore(root: root).save(.init(mode: .fast))
        let config = try TravelCLIConfiguration(
            environment: ["TRAVEL_CAT_DATA": root.path],
            currentDirectory: root
        )
        XCTAssertEqual(try config.resolvedMode(), .fast)

        let override = try TravelCLIConfiguration(
            environment: ["TRAVEL_CAT_DATA": root.path, "TRAVEL_CAT_MODE": "daily"],
            currentDirectory: root
        )
        XCTAssertEqual(try override.resolvedMode(), .daily)
    }

    func testVersionOneSettingsWithoutFollowFlagMigratesEnabled() throws {
        let data = Data(#"{"schemaVersion":1,"mode":"daily","quietStart":22,"quietEnd":8}"#.utf8)

        XCTAssertTrue(try JSONDecoder().decode(TravelSettings.self, from: data).followCodexPet)
    }

    func testFollowCodexPetRoundTripsFalse() throws {
        let settings = TravelSettings(followCodexPet: false)

        XCTAssertEqual(
            try JSONDecoder().decode(
                TravelSettings.self,
                from: JSONEncoder().encode(settings)
            ),
            settings
        )
    }
}
