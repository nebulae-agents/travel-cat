import CoreGraphics
import Foundation
import XCTest
import TravelCore
@testable import TravelUI

@MainActor
final class TravelAlbumPreviewTests: XCTestCase {
    func testCatalogResolvesEveryPreviewAssetFromTheSwiftPMResourceBundle() throws {
        for definition in TravelAlbumPreviewCatalog.definitions {
            let url = try XCTUnwrap(
                TravelAlbumPreviewCatalog.resourceURL(for: definition, in: TravelUIResources.bundle)
            )
            XCTAssertEqual(url.lastPathComponent, definition.filename)
        }
    }

    func testPreviewEventDatesKeepLocalClockScheduleAcrossLosAngelesDSTTransitions() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let components: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        let testCases: [(now: Date, expected: [DateComponents])] = [
            (
                now: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 8))),
                expected: [
                    DateComponents(year: 2026, month: 3, day: 5, hour: 10, minute: 0, second: 0),
                    DateComponents(year: 2026, month: 3, day: 5, hour: 10, minute: 30, second: 0),
                    DateComponents(year: 2026, month: 3, day: 6, hour: 10, minute: 0, second: 0),
                    DateComponents(year: 2026, month: 3, day: 7, hour: 10, minute: 0, second: 0),
                    DateComponents(year: 2026, month: 3, day: 7, hour: 10, minute: 30, second: 0),
                    DateComponents(year: 2026, month: 3, day: 7, hour: 11, minute: 0, second: 0),
                ]
            ),
            (
                now: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 8))),
                expected: [
                    DateComponents(year: 2026, month: 10, day: 29, hour: 10, minute: 0, second: 0),
                    DateComponents(year: 2026, month: 10, day: 29, hour: 10, minute: 30, second: 0),
                    DateComponents(year: 2026, month: 10, day: 30, hour: 10, minute: 0, second: 0),
                    DateComponents(year: 2026, month: 10, day: 31, hour: 10, minute: 0, second: 0),
                    DateComponents(year: 2026, month: 10, day: 31, hour: 10, minute: 30, second: 0),
                    DateComponents(year: 2026, month: 10, day: 31, hour: 11, minute: 0, second: 0),
                ]
            ),
        ]

        for testCase in testCases {
            let dates = try TravelAlbumPreviewFactory.previewEventDates(
                now: testCase.now,
                calendar: calendar
            )
            XCTAssertEqual(dates, dates.sorted())
            XCTAssertTrue(dates.allSatisfy { $0 < testCase.now })
            XCTAssertEqual(
                dates.map { calendar.dateComponents(components, from: $0) },
                testCase.expected
            )
        }
    }

    func testFactoryCreatesSixOrderedReadyEventsInIsolatedTemporaryRoot() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("travel-cat-preview-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let resourceURLs = try TravelAlbumPreviewCatalog.definitions.map { definition in
            try makeResourceURL(for: definition.filename)
        }
        let now = Date(timeIntervalSince1970: 1_786_449_600)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let session = try TravelAlbumPreviewFactory.make(
            temporaryDirectory: parent,
            resourceURLs: resourceURLs,
            catResourceURLs: try catResourceURLs(),
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(session.events.count, 6)
        XCTAssertEqual(session.events.map(\.postcardStatus), Array(repeating: .ready, count: 6))
        XCTAssertEqual(session.events.map(\.tripID), Array(repeating: session.tripID, count: 6))
        let sorted = session.events.map(\.occurredAt)
        XCTAssertEqual(sorted, sorted.sorted())
        let groups = TripAlbumDateGrouping.groups(orderedEvents: session.events, calendar: calendar)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.map { $0.events.count }, [2, 1, 3])
        XCTAssertTrue(zip(groups.map(\.day), groups.map(\.day).dropFirst()).allSatisfy(<))
        XCTAssertTrue(session.events.allSatisfy { $0.occurredAt < now })
        for (day, nextDay) in zip(groups.map(\.day), groups.map(\.day).dropFirst()) {
            XCTAssertEqual(calendar.date(byAdding: .day, value: 1, to: day), nextDay)
        }
        for group in groups where group.events.count > 1 {
            for (event, nextEvent) in zip(group.events, group.events.dropFirst()) {
                XCTAssertEqual(
                    calendar.dateComponents([.minute], from: event.occurredAt, to: nextEvent.occurredAt).minute,
                    30
                )
            }
        }
        XCTAssertEqual(session.model.presentation, .album(session.tripID))
        XCTAssertTrue(session.model.snapshot.phase == .exploring)

        for event in session.events {
            let relativePath = try XCTUnwrap(event.postcardRelativePath)
            let components = relativePath.split(separator: "/").map(String.init)
            let expected = [
                "postcards",
                session.tripID.uuidString,
                String(event.postcardRelativePath?.split(separator: "/").last ?? "")
            ]
            XCTAssertEqual(components, expected)
            XCTAssertNoThrow(try PostcardImageLoader.loadData(relativePath: relativePath, rootURL: session.rootURL))
        }

        session.cleanUp()
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.rootURL.path))
    }

    func testCleanupRemovesOnlyOwnedPreviewDirectory() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("travel-cat-preview-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let keep = parent.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: keep)

        let resourceURLs = try TravelAlbumPreviewCatalog.definitions.map { definition in
            try makeResourceURL(for: definition.filename)
        }
        let session = try TravelAlbumPreviewFactory.make(
            temporaryDirectory: parent,
            resourceURLs: resourceURLs,
            catResourceURLs: try catResourceURLs()
        )

        session.cleanUp()
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.rootURL.path))
    }

    func testFactoryFailsIfAssetMissing() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("travel-cat-preview-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        var resourceURLs = try TravelAlbumPreviewCatalog.definitions.map { definition in
            try makeResourceURL(for: definition.filename)
        }
        resourceURLs[2] = parent.appendingPathComponent("missing.png")

        XCTAssertThrowsError(try TravelAlbumPreviewFactory.make(
            temporaryDirectory: parent,
            resourceURLs: resourceURLs,
            catResourceURLs: try catResourceURLs()
        ))
        let children = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        XCTAssertTrue(children.allSatisfy { !$0.contains("travel-cat-preview-") })
    }

    func testFactoryRejectsNonSystemTemporaryParentBeforeWriting() throws {
        let parent = URL(fileURLWithPath: "/", isDirectory: true)
        let before = try FileManager.default.contentsOfDirectory(atPath: parent.path)
            .filter { $0.hasPrefix("travel-cat-preview-") }.sorted()

        XCTAssertThrowsError(try TravelAlbumPreviewFactory.make(
            temporaryDirectory: parent,
            resourceURLs: [],
            catResourceURLs: []
        )) { error in
            XCTAssertEqual(error as? TravelAlbumPreviewError, .unsafeTemporaryRoot)
        }
        let after = try FileManager.default.contentsOfDirectory(atPath: parent.path)
            .filter { $0.hasPrefix("travel-cat-preview-") }.sorted()
        XCTAssertEqual(after, before)
    }

    func testEveryPreviewUsesApprovedCloseUpScaleAndRemainsFullyVisible() {
        let expectedHeightFractions: [String: CGFloat] = [
            "preview-kamakura-coast.png": 0.46,
            "preview-kyoto-lanterns.png": 0.52,
            "preview-dali-lake.png": 0.46,
            "preview-iceland-aurora.png": 0.46,
            "preview-hangzhou-garden.png": 0.60,
            "preview-paris-dusk.png": 0.50,
        ]
        let sizes = [CGSize(width: 360, height: 230), CGSize(width: 218, height: 120)]

        XCTAssertEqual(
            Set(TravelAlbumPreviewCatalog.definitions.map(\.filename)),
            Set(expectedHeightFractions.keys)
        )
        XCTAssertEqual(TravelAlbumPreviewCatalog.definitions.count, expectedHeightFractions.count)
        for definition in TravelAlbumPreviewCatalog.definitions {
            guard let expectedHeightFraction = expectedHeightFractions[definition.filename] else {
                XCTFail("unexpected preview definition: \(definition.filename)")
                continue
            }
            XCTAssertEqual(
                definition.catPlacement.heightFraction,
                expectedHeightFraction,
                definition.filename
            )
            XCTAssertTrue((0.46...0.60).contains(definition.catPlacement.heightFraction))
            for size in sizes {
                let rect = definition.catPlacement.frame(
                    in: size,
                    sourceAspectRatio: PreviewBlackCatPlacement.authorizedSourceAspectRatio
                )
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(rect), definition.filename)
            }
        }
    }

    func testPreviewCatPlacementAcceptsOnlyApprovedCloseUpHeightRange() {
        func placement(heightFraction: CGFloat) -> PreviewBlackCatPlacement {
            PreviewBlackCatPlacement(
                pose: .sitting,
                anchor: CGPoint(x: 0.5, y: 0.9),
                heightFraction: heightFraction,
                isMirrored: false
            )
        }

        XCTAssertFalse(placement(heightFraction: 0.459).isValid)
        XCTAssertTrue(placement(heightFraction: 0.46).isValid)
        XCTAssertTrue(placement(heightFraction: 0.60).isValid)
        XCTAssertFalse(placement(heightFraction: 0.601).isValid)
    }

    func testFactoryCopiesValidatedCatAssetsIntoOwnedPreviewRoot() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("travel-cat-preview-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let session = try TravelAlbumPreviewFactory.make(
            temporaryDirectory: parent,
            resourceURLs: try TravelAlbumPreviewCatalog.definitions.map { try makeResourceURL(for: $0.filename) },
            catResourceURLs: try catResourceURLs()
        )
        defer { session.cleanUp() }

        for pose in PreviewBlackCatPose.allCases {
            let copied = try XCTUnwrap(session.catAssetURL(for: pose))
            XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
            XCTAssertEqual(
                try Data(contentsOf: copied),
                try Data(contentsOf: makeCatResourceURL(for: pose))
            )
        }
    }

    func testPreviewResolverRejectsProductionRootEvenWhenFilenameMatches() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("travel-cat-preview-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let session = try TravelAlbumPreviewFactory.make(
            temporaryDirectory: parent,
            resourceURLs: try TravelAlbumPreviewCatalog.definitions.map { try makeResourceURL(for: $0.filename) },
            catResourceURLs: try catResourceURLs()
        )
        defer { session.cleanUp() }

        let event = try XCTUnwrap(session.events.first)
        let productionRoot = parent.appendingPathComponent("ordinary-root", isDirectory: true)
        let productionCatRoot = productionRoot.appendingPathComponent("preview-cat", isDirectory: true)
        try FileManager.default.createDirectory(at: productionCatRoot, withIntermediateDirectories: true)
        let definition = try XCTUnwrap(TravelAlbumPreviewCatalog.definitions.first)
        let sourceCatURL = try XCTUnwrap(
            TravelAlbumPreviewCatalog.catResourceURL(
                for: definition.catPlacement.pose,
                in: TravelUIResources.bundle
            )
        )
        try FileManager.default.copyItem(
            at: sourceCatURL,
            to: productionCatRoot.appendingPathComponent(definition.catPlacement.pose.assetFilename)
        )
        XCTAssertNil(TravelAlbumPreviewCatalog.overlayDescriptor(event: event, rootURL: productionRoot))
        XCTAssertNotNil(TravelAlbumPreviewCatalog.overlayDescriptor(event: event, rootURL: session.rootURL))
    }

    func testFactoryFailsAndCleansUpWhenCatAssetIsMissing() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("travel-cat-preview-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        var catURLs = try catResourceURLs()
        catURLs[1] = parent.appendingPathComponent("missing-cat.png")
        XCTAssertThrowsError(try TravelAlbumPreviewFactory.make(
            temporaryDirectory: parent,
            resourceURLs: try TravelAlbumPreviewCatalog.definitions.map { try makeResourceURL(for: $0.filename) },
            catResourceURLs: catURLs
        ))
        let children = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        XCTAssertTrue(children.allSatisfy { !$0.hasPrefix(TravelAlbumPreviewFactory.previewRootPrefix) })
    }

    private func makeResourceURL(for filename: String) throws -> URL {
        let parts = filename.split(separator: ".", maxSplits: 1).map(String.init)
        if let bundledURL = TravelUIResources.bundle.url(
            forResource: parts.first ?? "",
            withExtension: parts.count > 1 ? parts[1] : nil,
            subdirectory: TravelAlbumPreviewCatalog.directory
        ) {
            return bundledURL
        }
        let directPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
            .appendingPathComponent("TravelUI")
            .appendingPathComponent("Resources")
            .appendingPathComponent(TravelAlbumPreviewCatalog.directory)
            .appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: directPath.path) {
            return directPath
        }
        return try XCTUnwrap(
            nil as URL?,
            "Missing bundled resource: \(filename)"
        )
    }

    private func catResourceURLs() throws -> [URL] {
        try PreviewBlackCatPose.allCases.map(makeCatResourceURL)
    }

    private func makeCatResourceURL(for pose: PreviewBlackCatPose) throws -> URL {
        if let bundledURL = TravelAlbumPreviewCatalog.catResourceURL(
            for: pose,
            in: TravelUIResources.bundle
        ) {
            return bundledURL
        }
        let directPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TravelUI/Resources/PreviewBlackCat", isDirectory: true)
            .appendingPathComponent(pose.assetFilename)
        return try XCTUnwrap(
            FileManager.default.fileExists(atPath: directPath.path) ? directPath : nil,
            "Missing bundled cat resource: \(pose.assetFilename)"
        )
    }
}
