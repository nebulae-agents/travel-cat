import Foundation
import XCTest
import TravelCore
@testable import TravelCatApp

final class TravelGenerationPromptSnapshotTests: XCTestCase {
    private let legacyCommit = "67b6db7b9b6e4809a59c1a5483918293cf81d521"
    private let laterCommit = "25c2258405e1f95324869aad2ac3b6d703404484"
    private let categories: Set<String> = ["waterside", "heritage", "market", "mountain", "garden", "urban", "everyday"]

    func testFixedSnapshotsCoverEveryHistoricalSceneAndComposition() throws {
        let fixture = try snapshots()
        XCTAssertEqual(fixture.format, "travel-cat-historical-image-prompts-v1")
        XCTAssertEqual(Set(fixture.baselines.map(\.commit)), [legacyCommit, laterCommit])
        for baseline in fixture.baselines {
            XCTAssertEqual(Set(baseline.sources.map(\.path)), [
                "Sources/TravelCore/PostcardSceneStyle.swift", "Sources/TravelCatApp/TravelGenerationPrompts.swift",
            ])
            for source in baseline.sources {
                XCTAssertEqual(source.gitBlob.count, 40)
                XCTAssertEqual(source.sha256.count, 64)
            }
        }
        XCTAssertEqual(fixture.cases.count, 65)
        XCTAssertEqual(Set(fixture.cases.map(\.name)).count, 65)
        XCTAssertEqual(fixture.cases.filter { $0.version == nil }.map(\.name), ["legacy"])
        XCTAssertEqual(fixture.cases.filter { $0.version == 99 }.map(\.name), ["unknown-99"])
        XCTAssertEqual(Set(fixture.cases.compactMap(\.version)), [1, 2, 3, 99])
        for version in 1...3 {
            let styled = fixture.cases.filter { $0.version == version }
            XCTAssertEqual(styled.count, 21)
            XCTAssertEqual(Set(styled.compactMap(\.category)), categories)
            for category in categories {
                XCTAssertEqual(Set(styled.filter { $0.category == category }.compactMap(\.compositionVariant)),
                    [0, 1, 2], "v\(version)-\(category)")
            }
        }
        for item in fixture.cases {
            XCTAssertEqual(item.sourceCommit, (item.version == 2 || item.version == 3) ? laterCommit : legacyCommit)
        }
    }

    func testBothImageEntrypointsMatchHistoricalUTF8Snapshots() throws {
        for item in try snapshots().cases {
            let event = event(for: item)
            let style = PostcardSceneStyle.resolve(event: event)
            XCTAssertEqual(style?.category.rawValue, item.category, item.name)
            XCTAssertEqual(style?.compositionVariant, item.compositionVariant, item.name)
            assertPrompts(event: event, snapshot: item)
        }
    }

    func testSerializedImageRetriesMatchTheSameHistoricalSnapshots() throws {
        for item in try snapshots().cases {
            for status in [PostcardStatus.pendingImage, .imageUnavailable, .ready] {
                var card = event(for: item)
                card.postcardStatus = status
                card.postcardRelativePath = status == .ready
                    ? "postcards/00000000-0000-0000-0000-000000000100/\(card.id.uuidString.lowercased()).png" : nil
                let reopened = try JSONDecoder.travelCat.decode(TripEvent.self, from: JSONEncoder.travelCat.encode(card))
                XCTAssertEqual(reopened.postcardStyleVersion, item.version, "\(item.name)-\(status)")
                XCTAssertEqual(reopened.postcardStatus, status, "\(item.name)-\(status)")
                XCTAssertEqual(reopened.postcardRelativePath, card.postcardRelativePath, "\(item.name)-\(status)")
                assertPrompts(event: reopened, snapshot: item, context: status.rawValue)
            }
        }
    }

    private func assertPrompts(event: TripEvent, snapshot: PromptSnapshot, context: String = "published",
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Data(TravelGenerationPrompts.image(for: event).utf8), Data(snapshot.imagePrompt.utf8),
            "\(snapshot.name)-\(context): API prompt UTF-8 changed", file: file, line: line)
        XCTAssertEqual(Data(TravelGenerationPrompts.codexImage(for: event).utf8), Data(snapshot.codexPrompt.utf8),
            "\(snapshot.name)-\(context): Codex prompt UTF-8 changed", file: file, line: line)
    }

    private func event(for snapshot: PromptSnapshot) -> TripEvent {
        TripEvent(id: snapshot.eventID, tripID: UUID(uuidString: "00000000-0000-0000-0000-000000000100")!,
            previousEventID: nil, occurredAt: Date(timeIntervalSince1970: 0), phase: .postcardReady,
            location: Location(country: snapshot.country, city: snapshot.city, place: snapshot.place), transport: nil,
            summary: snapshot.summary, mood: Mood(level: 0, label: "平静", quote: "慢慢走真好"),
            continuityReferences: [], openHook: nil, consumedItemID: nil,
            postcardStatus: .pendingImage, postcardRelativePath: nil, postcardStyleVersion: snapshot.version)
    }

    private func snapshots() throws -> SnapshotFixture {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/TravelGenerationPrompts/historical-image-prompts.json"))
        return try JSONDecoder().decode(SnapshotFixture.self, from: data)
    }

    private struct SnapshotFixture: Decodable {
        let format: String
        let baselines: [Baseline]
        let cases: [PromptSnapshot]
    }

    private struct Baseline: Decodable {
        let commit: String
        let sources: [Source]
    }

    private struct Source: Decodable {
        let path: String
        let gitBlob: String
        let sha256: String
    }

    private struct PromptSnapshot: Decodable {
        let name: String
        let sourceCommit: String
        let eventID: UUID
        let country: String
        let city: String
        let place: String
        let summary: String
        let version: Int?
        let category: String?
        let compositionVariant: Int?
        let imagePrompt: String
        let codexPrompt: String
    }
}
