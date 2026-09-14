import Foundation
import XCTest
import TravelCore
@testable import TravelStorage

final class FastTripAcceptanceTests: XCTestCase {
    func testAllCanonicalFastTripsReachRestingWithAlignedRepository() throws {
        let fixtures = try FixtureLoader.fastTrips()
        XCTAssertEqual(fixtures.map(\.metadata.name), ["fast-trip-1", "fast-trip-2", "fast-trip-3"])

        for fixture in fixtures {
            let result = try FastTripRunner().run(fixture)

            XCTAssertEqual(result.finalSnapshot.phase, .resting, fixture.metadata.name)
            XCTAssertEqual(result.finalSnapshot.stateVersion, fixture.metadata.expectedEventCount, fixture.metadata.name)
            XCTAssertEqual(result.repositoryContents.events.count, fixture.metadata.expectedEventCount, fixture.metadata.name)
            XCTAssertEqual(result.repositoryContents.snapshot, result.finalSnapshot, fixture.metadata.name)
            XCTAssertEqual(result.repositoryContents.events.last?.phase, .resting, fixture.metadata.name)
            XCTAssertTrue(result.duplicateEventIDs.isEmpty, fixture.metadata.name)
            XCTAssertTrue(result.continuityViolations.isEmpty, fixture.metadata.name)
            XCTAssertEqual(result.postcards.count, fixture.metadata.expectedPostcardCount, fixture.metadata.name)
            XCTAssertGreaterThanOrEqual(result.postcards.filter { $0.terminalStatus == .ready }.count, 1, fixture.metadata.name)
            XCTAssertGreaterThanOrEqual(result.interestingPlaces.count, 2, fixture.metadata.name)
            XCTAssertEqual(result.delayGaps.count, fixture.metadata.expectedDelayCount, fixture.metadata.name)
            XCTAssertTrue(result.idempotentRetryVerified, fixture.metadata.name)
            XCTAssertEqual(result.idempotentlyRetriedEventIDs.count, fixture.metadata.expectedEventCount, fixture.metadata.name)
            XCTAssertEqual(result.readyImages.count, result.postcards.filter { $0.terminalStatus == .ready }.count, fixture.metadata.name)
            XCTAssertTrue(result.readyImages.allSatisfy { $0.isRegularFile && $0.width > 0 && $0.height > 0 }, fixture.metadata.name)
            XCTAssertTrue(result.temporaryRootRemoved, fixture.metadata.name)
            XCTAssertEqual(result.finalSnapshot.carriedItemID, nil, fixture.metadata.name)
            XCTAssertEqual(result.finalSnapshot.usedItemIDs, Set([try XCTUnwrap(fixture.metadata.carriedItemID)]), fixture.metadata.name)
            XCTAssertEqual(Set(result.repositoryContents.events.map(\.tripID)), Set([result.finalSnapshot.tripID!]), fixture.metadata.name)
        }
    }

    func testDelayedJourneyRecordsOneGapWithoutDuplicateAdvancement() throws {
        let fixture = try FixtureLoader.fastTrips()[1]
        let result = try FastTripRunner().run(fixture)

        XCTAssertEqual(result.delayGaps.count, 1)
        XCTAssertEqual(result.delayGaps[0].lateBySeconds, 1_680)
        XCTAssertEqual(result.delayGaps[0].delayedEventID, UUID(uuidString: "20000000-0000-0000-0000-000000000003"))
        XCTAssertTrue(result.idempotentlyRetriedEventIDs.contains(result.delayGaps[0].delayedEventID))
        XCTAssertEqual(result.finalSnapshot.stateVersion, fixture.metadata.expectedEventCount)
        XCTAssertTrue(result.duplicateEventIDs.isEmpty)
        XCTAssertEqual(Set(result.repositoryContents.events.map(\.id)).count, fixture.metadata.expectedEventCount)
    }

    func testPendingPostcardImageUpdatePreservesCompleteEventAndVersion() throws {
        let fixture = try FixtureLoader.fastTrips()[2]
        let result = try FastTripRunner().run(fixture)

        let evidence = try XCTUnwrap(result.imageUpdates.first)
        XCTAssertEqual(evidence.beforeStatus, .pendingImage)
        XCTAssertEqual(evidence.afterStatus, .ready)
        XCTAssertEqual(evidence.relativePath, "postcards/30000000-0000-0000-0000-000000000000/morning-market.png")
        XCTAssertEqual(evidence.stateVersionBefore, evidence.stateVersionAfter)
        XCTAssertEqual(evidence.eventCountBefore, evidence.eventCountAfter)
        XCTAssertTrue(evidence.completeImmutableEventUnchanged)
        XCTAssertEqual(result.postcards.first?.statusHistory, [.pendingImage, .ready])
    }

    func testReadyPostcardRequiresMaterializedDecodableRegularImage() throws {
        let preparing = eventJSON(id: "00000000-0000-0000-0000-000000009031", previous: nil, phase: "preparing", minute: 0)
        let transit = eventJSON(id: "00000000-0000-0000-0000-000000009032", previous: "00000000-0000-0000-0000-000000009031", phase: "transit", minute: 2)
        let exploring = eventJSON(id: "00000000-0000-0000-0000-000000009033", previous: "00000000-0000-0000-0000-000000009032", phase: "exploring", minute: 4)
        let readyWithoutImage = eventJSON(
            id: "00000000-0000-0000-0000-000000009034",
            previous: "00000000-0000-0000-0000-000000009033",
            phase: "postcardReady",
            minute: 6,
            postcardStatus: "ready",
            postcardPath: "inline/missing.png"
        )

        assertRunnerError(actions(preparing, transit, exploring, readyWithoutImage), contains: "action 5: ready postcard requires materializeFixtureImage")

        let invalid = FileManager.default.temporaryDirectory.appendingPathComponent("travel-cat-invalid-image-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: invalid) }
        try Data("not an image".utf8).write(to: invalid)
        XCTAssertThrowsError(try FastTripRunner.validateReadyImage(at: invalid)) { error in
            XCTAssertTrue(String(describing: error).contains("decodable PNG/WebP"), "\(error)")
        }
    }

    func testCompleteEventComparatorDetectsPreviouslyUncoveredMutation() {
        let before = TripEvent.fixture(phase: .postcardReady, postcardStatus: .pendingImage)
        let after = TripEvent(
            id: before.id,
            tripID: before.tripID,
            previousEventID: before.previousEventID,
            occurredAt: before.occurredAt,
            phase: before.phase,
            location: before.location,
            transport: "mutated transport",
            summary: before.summary,
            mood: before.mood,
            continuityReferences: before.continuityReferences,
            openHook: before.openHook,
            consumedItemID: before.consumedItemID,
            postcardStatus: .ready,
            postcardRelativePath: "safe.png"
        )

        XCTAssertFalse(FastTripRunner.completeEventIsImmutable(before: before, afterImageUpdate: after))
    }

    func testRunnerErrorsDoNotLeakTemporaryRepositoryRoots() throws {
        let fixtureName = "cleanup-\(UUID().uuidString)"
        let before = try fastTripTemporaryRoots(named: fixtureName)
        let invalid = eventJSON(id: "00000000-0000-0000-0000-000000009041", previous: nil, phase: "preparing", minute: 0, mood: 2)
        let fixture = try FixtureLoader.load(data: Data(actions(invalid, name: fixtureName).utf8), named: fixtureName)
        XCTAssertThrowsError(try FastTripRunner().run(fixture)) { error in
            XCTAssertTrue(String(describing: error).contains("continuity violation moodJump"), "\(error)")
        }
        XCTAssertEqual(try fastTripTemporaryRoots(named: fixtureName), before)
    }

    func testCanonicalFixturesAreStableAndSecondRunIsIdentical() throws {
        let fixtures = try FixtureLoader.fastTrips()
        let before = try fixtures.map { try Data(contentsOf: $0.sourceURL) }
        let first = try fixtures.map { try FastTripRunner().run($0) }
        let second = try FixtureLoader.fastTrips().map { try FastTripRunner().run($0) }
        let after = try fixtures.map { try Data(contentsOf: $0.sourceURL) }

        XCTAssertEqual(first, second)
        XCTAssertEqual(before, after)
        XCTAssertTrue(before.allSatisfy { $0.last == 0x0A })
    }

    func testParserRejectsBlankMalformedAndUnknownActionsWithLineNumbers() throws {
        assertFixtureError("{\"type\":\"metadata\",\"name\":\"bad\",\"seed\":1,\"expectedEventCount\":0,\"expectedPostcardCount\":0,\"expectedDelayCount\":0}\n\n", contains: "line 2: blank action")
        assertFixtureError("{\"type\":\"metadata\",\"name\":\"bad\",\"seed\":1,\"expectedEventCount\":0,\"expectedPostcardCount\":0,\"expectedDelayCount\":0}\nnot-json\n", contains: "line 2: malformed action")
        assertFixtureError("{\"type\":\"metadata\",\"name\":\"bad\",\"seed\":1,\"expectedEventCount\":0,\"expectedPostcardCount\":0,\"expectedDelayCount\":0}\n{\"type\":\"teleport\"}\n", contains: "line 2: unknown action type 'teleport'")
    }

    func testRunnerRejectsDuplicateBrokenChainAndIllegalTransition() throws {
        let preparing = eventJSON(id: "00000000-0000-0000-0000-000000009001", previous: nil, phase: "preparing", minute: 0)
        let duplicate = eventJSON(id: "00000000-0000-0000-0000-000000009001", previous: "00000000-0000-0000-0000-000000009001", phase: "transit", minute: 2)
        assertRunnerError(actions(preparing, duplicate), contains: "action 3: duplicate event ID")

        let broken = eventJSON(id: "00000000-0000-0000-0000-000000009002", previous: "00000000-0000-0000-0000-000000009099", phase: "transit", minute: 2)
        assertRunnerError(actions(preparing, broken), contains: "action 3: broken previousEventID")

        let illegal = eventJSON(id: "00000000-0000-0000-0000-000000009003", previous: "00000000-0000-0000-0000-000000009001", phase: "exploring", minute: 2)
        assertRunnerError(actions(preparing, illegal), contains: "action 3: illegal transition preparing -> exploring")
    }

    func testRunnerRejectsInvalidImageUpdates() throws {
        let preparing = eventJSON(id: "00000000-0000-0000-0000-000000009011", previous: nil, phase: "preparing", minute: 0)
        let update = "{\"type\":\"imageUpdate\",\"eventID\":\"00000000-0000-0000-0000-000000009011\",\"status\":\"ready\",\"postcardRelativePath\":\"bad.png\"}"
        assertRunnerError(actions(preparing, update), contains: "action 3: image update requires pendingImage")

        let pending = eventJSON(id: "00000000-0000-0000-0000-000000009012", previous: nil, phase: "preparing", minute: 0, postcardStatus: "pendingImage")
        let unsafe = "{\"type\":\"imageUpdate\",\"eventID\":\"00000000-0000-0000-0000-000000009012\",\"status\":\"ready\",\"postcardRelativePath\":\"../escape.png\"}"
        assertRunnerError(actions(pending, unsafe), contains: "action 3: unsafe postcard path")
    }

    func testRunnerRejectsMoodJumpReusedItemAndRepeatedPlace() throws {
        let first = eventJSON(id: "00000000-0000-0000-0000-000000009021", previous: nil, phase: "preparing", minute: 0, mood: 2)
        assertRunnerError(actions(first), contains: "action 2: continuity violation moodJump")

        let preparing = eventJSON(id: "00000000-0000-0000-0000-000000009022", previous: nil, phase: "preparing", minute: 0, item: "tea")
        let transit = eventJSON(id: "00000000-0000-0000-0000-000000009023", previous: "00000000-0000-0000-0000-000000009022", phase: "transit", minute: 2, item: "tea")
        assertRunnerError(actions(preparing, transit, carriedItem: "tea"), contains: "action 3: continuity violation itemAlreadyConsumed(tea)")

        let atGate = eventJSON(id: "00000000-0000-0000-0000-000000009024", previous: nil, phase: "preparing", minute: 0, place: "Gate")
        let sameGate = eventJSON(id: "00000000-0000-0000-0000-000000009025", previous: "00000000-0000-0000-0000-000000009024", phase: "transit", minute: 2, place: "Gate")
        assertRunnerError(actions(atGate, sameGate), contains: "action 3: continuity violation repeatedPlace")
    }

    private func assertFixtureError(_ text: String, contains expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try FixtureLoader.load(data: Data(text.utf8), named: "inline")) { error in
            XCTAssertTrue(String(describing: error).contains(expected), "\(error)", file: file, line: line)
        }
    }

    private func assertRunnerError(_ text: String, contains expected: String, file: StaticString = #filePath, line: UInt = #line) {
        do {
            let fixture = try FixtureLoader.load(data: Data(text.utf8), named: "inline")
            XCTAssertThrowsError(try FastTripRunner().run(fixture)) { error in
                XCTAssertTrue(String(describing: error).contains(expected), "\(error)", file: file, line: line)
            }
        } catch {
            XCTFail("Fixture setup failed: \(error)", file: file, line: line)
        }
    }

    private func actions(_ records: String..., carriedItem: String? = nil, name: String = "inline") -> String {
        let item = carriedItem.map { ",\"carriedItemID\":\"\($0)\"" } ?? ""
        let metadata = "{\"type\":\"metadata\",\"name\":\"\(name)\",\"seed\":99,\"expectedEventCount\":\(records.filter { $0.contains("\"type\":\"event\"") }.count),\"expectedPostcardCount\":0,\"expectedDelayCount\":0\(item)}"
        return ([metadata] + records).joined(separator: "\n") + "\n"
    }

    private func eventJSON(
        id: String,
        previous: String?,
        phase: String,
        minute: Int,
        mood: Int = 1,
        item: String? = nil,
        place: String? = nil,
        postcardStatus: String = "none",
        postcardPath: String? = nil,
        materializeFixtureImage: Bool = false
    ) -> String {
        let previousJSON = previous.map { "\"\($0)\"" } ?? "null"
        let itemJSON = item.map { "\"\($0)\"" } ?? "null"
        let locationJSON = place.map { "{\"city\":\"Test\",\"country\":\"Test\",\"place\":\"\($0)\"}" } ?? "null"
        let pathJSON = postcardPath.map { "\"\($0)\"" } ?? "null"
        return "{\"event\":{\"consumedItemID\":\(itemJSON),\"continuityReferences\":[\"anchor\"],\"id\":\"\(id)\",\"location\":\(locationJSON),\"mood\":{\"label\":\"test\",\"level\":\(mood),\"quote\":\"test quote\"},\"occurredAt\":\"2026-01-01T00:\(String(format: "%02d", minute)):00Z\",\"openHook\":\"test hook\",\"phase\":\"\(phase)\",\"postcardRelativePath\":\(pathJSON),\"postcardStatus\":\"\(postcardStatus)\",\"previousEventID\":\(previousJSON),\"summary\":\"test summary\",\"transport\":null,\"tripID\":\"00000000-0000-0000-0000-000000009000\"},\"materializeFixtureImage\":\(materializeFixtureImage),\"type\":\"event\"}"
    }

    private func fastTripTemporaryRoots(named name: String) throws -> Set<String> {
        let urls = try FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: nil
        )
        return Set(urls.map(\.lastPathComponent).filter { $0.hasPrefix("travel-cat-fast-trip-\(name)-") })
    }
}
