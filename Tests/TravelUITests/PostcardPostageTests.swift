import Foundation
import XCTest
import TravelCore
import TravelStorage
@testable import TravelUI

final class PostcardPostageTests: XCTestCase {
    func testFoshanToGuangzhouUsesNearbyFareAndOfflineCoordinates() throws {
        let postage = PostcardPostage.resolve(location: .init(country: "中国", city: "佛山市", place: "岭南天地"), home: home("广州市"))
        let distance = try XCTUnwrap(postage.distanceKilometers)
        XCTAssertTrue((10...30).contains(distance))
        XCTAssertEqual(postage.fare, 2)
        XCTAssertEqual(postage.denominations.reduce(0, +), postage.fare)
        XCTAssertTrue(postage.accessibilityDescription.contains("虚拟邮资"))
    }

    func testDistanceBoundariesAndDenominations() {
        for (distance, sameCity, expected) in [(0.0, true, 1), (0, false, 2), (500, false, 2),
            (500.01, false, 3), (2000, false, 3), (2000.01, false, 5)] {
            let fare = PostcardPostage.fare(distanceKilometers: distance, sameCity: sameCity)
            XCTAssertEqual(fare, expected)
            XCTAssertEqual(PostcardPostage.denominations(for: fare).reduce(0, +), fare)
        }
        XCTAssertEqual(PostcardPostage.denominations(for: 5).count, 3)
    }

    func testSameCityAliasesAndDistantInternationalCity() {
        let same = PostcardPostage.resolve(location: .init(country: "China", city: "Guangzhou", place: "河边"), home: home("广州"))
        XCTAssertEqual(same.fare, 1)
        XCTAssertEqual(same.distanceKilometers, 0)
        let far = PostcardPostage.resolve(location: .init(country: "日本", city: "京都", place: "灯笼旁"), home: home("广州"))
        XCTAssertEqual(far.fare, 5)
        XCTAssertGreaterThan(far.distanceKilometers ?? 0, 2000)
    }

    func testMissingAmbiguousOrConflictingLocationsDoNotInventPostage() {
        for (location, destination) in [
            (Location(country: "中国", city: "佛山", place: "窗旁"), nil),
            (.init(country: "中国", city: "地图上不存在的小镇", place: "桥边"), home("广州")),
            (.init(country: "法国", city: "广州", place: "桥边"), home("广州")),
            (.init(country: "中国", city: "佛山", place: "窗旁"), home("London"))
        ] {
            let postage = PostcardPostage.resolve(location: location, home: destination)
            XCTAssertNil(postage.fare)
            XCTAssertNil(postage.distanceKilometers)
            XCTAssertTrue(postage.denominations.isEmpty)
            XCTAssertTrue(postage.accessibilityDescription.contains("纪念"))
        }
        XCTAssertNil(PostcardPostage.resolve(location: nil, home: home("广州")).fare)
    }

    func testArtVariesByOriginButNotPrivateStoryOrDestination() {
        let foshan = Location(country: "中国", city: "佛山", place: "岭南天地")
        let kyoto = Location(country: "日本", city: "京都", place: "寺院")
        let original = PostcardPostage.resolve(location: foshan, home: home("广州"))
        XCTAssertEqual(original.design, PostcardPostage.resolve(location: foshan, home: home("北京")).design)
        XCTAssertEqual(original, PostcardPostage.resolve(location: foshan, home: home("广州")))
        XCTAssertNotEqual(original.design, PostcardPostage.resolve(location: kyoto, home: home("广州")).design)
    }

    func testHomeSnapshotDoesNotCreateMissingRootAndDoesNotWriteExistingState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(PostcardPostage.homeLocation(rootURL: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let store = HomeLocationStore(root: root)
        try store.save(.init(location: home("广州")))
        let before = try Data(contentsOf: store.url)
        XCTAssertEqual(PostcardPostage.homeLocation(rootURL: root)?.city, "广州")
        XCTAssertEqual(try Data(contentsOf: store.url), before)
    }

    private func home(_ city: String) -> HomeLocation {
        .init(city: city, source: .manual, updatedAt: Date(timeIntervalSince1970: 0))
    }
}
