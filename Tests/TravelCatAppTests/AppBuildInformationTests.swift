import Foundation
import XCTest
@testable import TravelCatApp

final class AppBuildInformationTests: XCTestCase {
    func testSourcePackagingBuildDoesNotDowngradeCurrentMainline() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("packaging/Info.plist"))
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let build = try XCTUnwrap(Int(try XCTUnwrap(info["CFBundleVersion"] as? String)))
        XCTAssertGreaterThanOrEqual(build, 42)
    }

    func testSourceRevisionUsesOnlyValidatedPackagedMetadata() {
        let revision = String(repeating: "a1", count: 20)
        XCTAssertEqual(AppBuildInformation(infoDictionary: ["TravelCatSourceRevision": revision]).sourceDescription, "a1a1a1a1a1a1")
        XCTAssertEqual(AppBuildInformation(infoDictionary: ["TravelCatSourceRevision": String(repeating: "b2", count: 32)]).sourceDescription, "b2b2b2b2b2b2")
        for value: Any in [revision + "\n", String(repeating: "A", count: 40), String(repeating: "a", count: 39), String(repeating: "a", count: 41), String(repeating: "a", count: 63), String(repeating: "a", count: 65), "private-account/path", "https://example.com/token", String(repeating: "z", count: 40), 42, NSNull()] {
            XCTAssertEqual(AppBuildInformation(infoDictionary: ["TravelCatSourceRevision": value]).sourceDescription, "未记录")
        }
    }

    func testVersionDescriptionIncludesVersionAndBuild() {
        let information = AppBuildInformation(infoDictionary: [
            "CFBundleShortVersionString": "1.4.1",
            "CFBundleVersion": "42",
        ])

        XCTAssertEqual(information.versionDescription, "1.4.1（构建42）")
    }

    func testMissingFieldsKeepAvailableVersionOrBuild() {
        XCTAssertEqual(AppBuildInformation(infoDictionary: [:]).versionDescription, "未知版本")
        XCTAssertEqual(AppBuildInformation(infoDictionary: [:]).buildDateDescription(), "未记录")
        XCTAssertEqual(
            AppBuildInformation(infoDictionary: ["CFBundleVersion": "42"]).versionDescription,
            "未知版本（构建42）"
        )
        XCTAssertEqual(
            AppBuildInformation(infoDictionary: ["CFBundleShortVersionString": "1.4.1"]).versionDescription,
            "1.4.1"
        )
    }

    func testBuildTimestampConvertsFromUTCToRequestedTimeZone() throws {
        let information = AppBuildInformation(infoDictionary: [
            "TravelCatBuildTimestamp": "2026-10-14T09:30:00Z",
        ])

        XCTAssertEqual(
            information.buildDateDescription(timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))),
            "2026-10-14 17:30"
        )
        XCTAssertEqual(
            information.buildDateDescription(timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0))),
            "2026-10-14 09:30"
        )
    }

    func testInvalidTimestampAndFieldTypesAreNotInvented() {
        for timestamp: Any in [
            "not-a-date", "2026-10-14", "2026-10-14T09:30:00", "2026-10-14T09:30:00+08:00",
            "2026-02-30T09:30:00Z", "2026-10-14T09:30:00Z trailing", 1_792_000_000, Date(), NSNull(),
        ] {
            let information = AppBuildInformation(infoDictionary: ["TravelCatBuildTimestamp": timestamp])
            XCTAssertEqual(information.buildDateDescription(), "未记录", "Invalid timestamp: \(timestamp)")
        }
        let information = AppBuildInformation(infoDictionary: [
            "CFBundleShortVersionString": 1.4,
            "CFBundleVersion": 32,
            "TravelCatBuildTimestamp": ["date": "2026-10-14T09:30:00Z"],
        ])
        XCTAssertEqual(information.versionDescription, "未知版本")
        XCTAssertEqual(information.buildDateDescription(), "未记录")
    }

    func testBlankVersionFieldsAreTreatedAsMissing() {
        XCTAssertEqual(
            AppBuildInformation(infoDictionary: [
                "CFBundleShortVersionString": " ",
                "CFBundleVersion": "42",
            ]).versionDescription,
            "未知版本（构建42）"
        )
        XCTAssertEqual(
            AppBuildInformation(infoDictionary: [
                "CFBundleShortVersionString": "1.4.1",
                "CFBundleVersion": " ",
            ]).versionDescription,
            "1.4.1"
        )
    }
}
