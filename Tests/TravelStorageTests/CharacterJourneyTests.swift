import Foundation
import XCTest
import TravelCore
@testable import TravelStorage

final class CharacterJourneyTests: XCTestCase {
    func testExportPreservesSelectedAndFrozenProfilesWithAllImmutableCharacterAssets() throws {
        let fixture = JourneyCharacterFixture()
        let a = try fixture.importProfile(id: "export-a", name: "A")
        let repository = try TravelRepository(root: fixture.dataRoot, clock: FixedClock(now: fixture.now))
        XCTAssertEqual(try repository.claimDue(mode: .fast, now: fixture.now).characterProfile, a)
        let b = try fixture.importProfile(id: "export-b", name: "B")
        let markers = try fixture.addHiddenAndTemporaryNamedAssets(to: b)
        let destination = fixture.root.appendingPathComponent("exported")

        _ = try repository.export(to: destination)

        for marker in markers {
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(marker).path))
        }
        let reopened = try TravelRepository(root: destination, clock: FixedClock(now: fixture.now))
        let configuration = try reopened.characterConfiguration()
        XCTAssertEqual(configuration.effectiveProfile, a)
        XCTAssertEqual(configuration.selectedProfile, b)
    }

    func testClearBackupRestoresProfilesAndAssetsWhileLiveSelectionAndSettingsRemain() throws {
        let fixture = JourneyCharacterFixture()
        let a = try fixture.importProfile(id: "clear-a", name: "A")
        let repository = try TravelRepository(root: fixture.dataRoot, clock: FixedClock(now: fixture.now))
        XCTAssertEqual(try repository.claimDue(mode: .fast, now: fixture.now).characterProfile, a)
        let b = try fixture.importProfile(id: "clear-b", name: "B")
        let markers = try fixture.addHiddenAndTemporaryNamedAssets(to: b)
        let settings = TravelSettings(mode: .fast, quietStart: 21, quietEnd: 6)
        try TravelSettingsStore(root: fixture.dataRoot).save(settings)

        let backup = try repository.clearHistory(now: fixture.now)

        XCTAssertEqual(try repository.characterConfiguration().selectedProfile, b)
        XCTAssertEqual(try repository.characterConfiguration().effectiveProfile, b)
        XCTAssertEqual(try TravelSettingsStore(root: fixture.dataRoot).load(), settings)
        for marker in markers {
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.dataRoot.appendingPathComponent(marker).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent(marker).path))
        }
        let reopenedBackup = try TravelRepository(root: backup, clock: FixedClock(now: fixture.now))
        XCTAssertEqual(try reopenedBackup.characterConfiguration().effectiveProfile, a)
        XCTAssertEqual(try reopenedBackup.characterConfiguration().selectedProfile, b)
        XCTAssertEqual(try TravelSettingsStore(root: backup).load(), settings)
    }

    func testExplicitDefaultProfilePublishIsIdempotentAfterCanonicalStorage() throws {
        let fixture = JourneyCharacterFixture()
        let repository = try TravelRepository(root: fixture.dataRoot, clock: FixedClock(now: fixture.now))
        let event = TripEvent.fixture(occurredAt: fixture.now, characterProfile: .defaultBlackCat)
        let next = TripSnapshot.fixture(stateVersion: 1, tripID: event.tripID, lastEventID: event.id,
                                        phase: .preparing, lastUpdatedAt: fixture.now)
        XCTAssertEqual(try repository.publish(event: event, next: next), 1)
        XCTAssertNil(try repository.events().first?.characterProfile)
        XCTAssertEqual(try repository.publish(event: event, next: next), 1)
        XCTAssertEqual(try repository.events().count, 1)
    }

    func testResetOfTemporaryFixtureInvalidatesClaimAtSameClock() throws {
        // This owns only a unique temporary fixture; never the user's TravelPetData.
        let fixture = JourneyCharacterFixture()
        let a = try fixture.importProfile(id: "reset-a", name: "A")
        let repository = try TravelRepository(root: fixture.dataRoot, clock: FixedClock(now: fixture.now))
        XCTAssertEqual(try repository.claimDue(mode: .fast, now: fixture.now).characterProfile, a)
        let b = try fixture.importProfile(id: "reset-b", name: "B")
        let backup = try repository.clearHistory(now: fixture.now)
        XCTAssertEqual(try repository.claimDue(mode: .fast, now: fixture.now).characterProfile, b)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("state/frozen-character.json").path))
    }

    func testClaimFreezesSelectedProfileAcrossSelectionChangeAndPublish() throws {
        let fixture = JourneyCharacterFixture()
        let a = try fixture.importProfile(id: "cat-a", name: "A")
        let repository = try TravelRepository(root: fixture.dataRoot, clock: FixedClock(now: fixture.now))

        let first = try repository.claimDue(mode: .fast, now: fixture.now)
        let b = try fixture.importProfile(id: "cat-b", name: "B")
        XCTAssertEqual(first.characterProfile, a)
        XCTAssertEqual(try repository.claimDue(mode: .fast, now: fixture.now).characterProfile, a)

        let candidate = TripEvent.fixture(occurredAt: fixture.now)
        try repository.publish(event: candidate, next: .fixture(stateVersion: 1, tripID: candidate.tripID, lastEventID: candidate.id, phase: .preparing, lastUpdatedAt: fixture.now))
        XCTAssertEqual(try XCTUnwrap(repository.events().first).characterProfile, a)
        XCTAssertEqual(try repository.publish(event: candidate, next: .fixture(stateVersion: 1, tripID: candidate.tripID, lastEventID: candidate.id, phase: .preparing, lastUpdatedAt: fixture.now)), 1)
        let wrongDefault = TripEvent.fixture(id: candidate.id, tripID: candidate.tripID,
            occurredAt: fixture.now, characterProfile: .defaultBlackCat)
        XCTAssertThrowsError(try repository.publish(event: wrongDefault,
            next: .fixture(stateVersion: 1, tripID: candidate.tripID, lastEventID: candidate.id,
                           phase: .preparing, lastUpdatedAt: fixture.now)))
        XCTAssertNotEqual(a, b)
    }

    func testForgedPreparingProfileIsRejected() throws {
        let fixture = JourneyCharacterFixture()
        let trusted = try fixture.importProfile(id: "trusted", name: "Trusted")
        let repository = try TravelRepository(root: fixture.dataRoot, clock: FixedClock(now: fixture.now))
        XCTAssertEqual(try repository.claimDue(mode: .fast, now: fixture.now).characterProfile, trusted)
        let forged = CharacterProfile(id: "forged", displayName: "Forged", description: "No", spriteVersionNumber: 2, sprite: .bundled("x"), referenceImages: [], source: .bundledDefault)
        let event = TripEvent.fixture(occurredAt: fixture.now, characterProfile: forged)
        XCTAssertThrowsError(try repository.publish(event: event, next: .fixture(stateVersion: 1, tripID: event.tripID, lastEventID: event.id, phase: .preparing, lastUpdatedAt: fixture.now)))
    }

    func testLaterPhaseCannotSupplyEvenTheTrustedProfile() throws {
        let fixture = JourneyCharacterFixture()
        let trusted = try fixture.importProfile(id: "later-trusted", name: "Trusted")
        let repository = try TravelRepository(root: fixture.dataRoot, clock: FixedClock(now: fixture.now))
        _ = try repository.claimDue(mode: .fast, now: fixture.now)
        let first = TripEvent.fixture(occurredAt: fixture.now)
        try repository.publish(event: first, next: .fixture(stateVersion: 1, tripID: first.tripID, lastEventID: first.id, phase: .preparing, lastUpdatedAt: fixture.now))
        let injected = TripEvent.fixture(tripID: first.tripID, previousEventID: first.id, occurredAt: fixture.now, phase: .transit, characterProfile: trusted)
        XCTAssertThrowsError(try repository.publish(event: injected, next: .fixture(stateVersion: 2, tripID: first.tripID, lastEventID: injected.id, phase: .transit, lastUpdatedAt: fixture.now)))
    }

    func testEventFirstRecoveryKeepsFrozenProfile() throws {
        let fixture = JourneyCharacterFixture()
        let a = try fixture.importProfile(id: "recovery-a", name: "A")
        var repository = try TravelRepository(root: fixture.dataRoot, clock: FixedClock(now: fixture.now))
        _ = try repository.claimDue(mode: .fast, now: fixture.now)
        let event = TripEvent.fixture(occurredAt: fixture.now)
        repository.publishAfterJournalHook = { throw CocoaError(.fileWriteUnknown) }
        XCTAssertThrowsError(try repository.publish(event: event, next: .fixture(stateVersion: 1, tripID: event.tripID, lastEventID: event.id, phase: .preparing, lastUpdatedAt: fixture.now)))
        _ = try fixture.importProfile(id: "recovery-b", name: "B")
        repository = try TravelRepository(root: fixture.dataRoot, clock: FixedClock(now: fixture.now))
        XCTAssertEqual(try repository.loadSnapshot().lastEventID, event.id)
        XCTAssertEqual(try repository.events().first?.characterProfile, a)
        XCTAssertEqual(try repository.claimDue(mode: .fast, now: fixture.now).characterProfile, a)
    }

    func testLegacyEventDecodesWithoutCharacterKeyAndReencodesWithoutIt() throws {
        let event = TripEvent.fixture()
        let data = try JSONEncoder.travelCat.encode(event)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["characterProfile"])
        XCTAssertEqual(try JSONDecoder.travelCat.decode(TripEvent.self, from: data).characterProfile, nil)
    }

    func testOldPendingPostcardKeepsOriginalProfileAfterSelectionAndReopen() throws {
        let fixture = JourneyCharacterFixture()
        let a = try fixture.importProfile(id: "journey-a", name: "A")
        var repository = try TravelRepository(root: fixture.dataRoot, clock: FixedClock(now: fixture.now))
        _ = try repository.claimDue(mode: .fast, now: fixture.now)
        let tripID = UUID()
        var previous: UUID?
        var version = 0
        for phase in [TravelPhase.preparing, .transit, .exploring, .postcardReady, .returning, .resting] {
            let event = TripEvent.fixture(tripID: tripID, previousEventID: previous, occurredAt: fixture.now, phase: phase, postcardStatus: phase == .postcardReady ? .pendingImage : .none)
            version += 1
            try repository.publish(event: event, next: .fixture(stateVersion: version, tripID: tripID, lastEventID: event.id, phase: phase, lastUpdatedAt: fixture.now))
            previous = event.id
        }
        let b = try fixture.importProfile(id: "journey-b", name: "B")
        XCTAssertEqual(try repository.claimDue(mode: .fast, now: fixture.now).characterProfile, b)
        repository = try TravelRepository(root: fixture.dataRoot, clock: FixedClock(now: fixture.now))
        XCTAssertEqual(try XCTUnwrap(repository.pendingImages(mode: .fast).first).characterProfile, a)
    }

    func testCorruptAnchorFailsClosed() throws {
        let fixture = JourneyCharacterFixture()
        let repository = try TravelRepository(root: fixture.dataRoot, clock: FixedClock(now: fixture.now))
        _ = try repository.claimDue(mode: .fast, now: fixture.now)
        let anchor = fixture.dataRoot.appendingPathComponent("state/frozen-character.json")
        try Data("not-json".utf8).write(to: anchor)
        XCTAssertThrowsError(try repository.claimDue(mode: .fast, now: fixture.now))
    }

    func testSymlinkAnchorFailsClosed() throws {
        let fixture = JourneyCharacterFixture()
        let repository = try TravelRepository(root: fixture.dataRoot, clock: FixedClock(now: fixture.now))
        _ = try repository.claimDue(mode: .fast, now: fixture.now)
        let anchor = fixture.dataRoot.appendingPathComponent("state/frozen-character.json")
        try FileManager.default.removeItem(at: anchor)
        try FileManager.default.createSymbolicLink(at: anchor, withDestinationURL: fixture.root.appendingPathComponent("missing-anchor"))
        XCTAssertThrowsError(try repository.claimDue(mode: .fast, now: fixture.now))
    }

    func testCorruptImportedTripProfileDoesNotConsumePendingLease() throws {
        let fixture = JourneyCharacterFixture()
        let imported = try fixture.importProfile(id: "corrupt-trip", name: "Corrupt")
        let repository = try TravelRepository(root: fixture.dataRoot, clock: FixedClock(now: fixture.now))
        _ = try finishTripWithPendingPostcard(repository, now: fixture.now)
        let retries = fixture.dataRoot.appendingPathComponent("state/image-retries.json")
        let before = try Data(contentsOf: retries)
        guard case let .importedManifest(sourcePath) = imported.source else { return XCTFail() }
        try Data("{}".utf8).write(to: fixture.dataRoot.appendingPathComponent(sourcePath))

        XCTAssertThrowsError(try repository.pendingImages(mode: .fast))
        XCTAssertEqual(try Data(contentsOf: retries), before)
    }

    func testLegacyDueClaimDefaultsToBlackCat() throws {
        let json = #"{"due":false,"snapshot":{"schemaVersion":1,"stateVersion":0,"phase":"resting","nextActionAt":"1970-01-01T00:00:00.000Z","lastUpdatedAt":"1970-01-01T00:00:00.000Z","usedItemIDs":[],"visitedPlaces":[],"mood":{"level":0,"label":"calm","quote":"hi"}}}"#
        XCTAssertEqual(try JSONDecoder.travelCat.decode(DueClaim.self, from: Data(json.utf8)).characterProfile, .defaultBlackCat)
    }

    func testTerminalPostcardJournalRewriteDoesNotInvalidateNewTripClaim() throws {
        let fixture = JourneyCharacterFixture()
        let a = try fixture.importProfile(id: "rewrite-a", name: "A")
        let clock = JourneyClock(now: fixture.now)
        let repository = try TravelRepository(root: fixture.dataRoot, clock: clock)
        let pending = try finishTripWithPendingPostcard(repository, now: fixture.now)
        XCTAssertEqual(try repository.claimDue(mode: .fast, now: clock.now).characterProfile, a)
        _ = try fixture.importProfile(id: "rewrite-b", name: "B")
        for delay in [0.0, 60.0, 180.0] {
            clock.now = fixture.now.addingTimeInterval(delay)
            let work = try XCTUnwrap(repository.pendingImages(mode: .fast).first)
            let result = ImageResultEnvelope(eventId: pending.id, status: .failed, attemptedAt: clock.now,
                relativePath: nil, reason: "network", attemptToken: work.attemptToken,
                attemptCount: work.imageAttemptCount, publishedNarrativeHash: work.publishedNarrativeHash)
            _ = try repository.markImage(result, mode: .fast)
        }
        XCTAssertEqual(try repository.claimDue(mode: .fast, now: clock.now).characterProfile, a)
        let next = TripEvent.fixture(previousEventID: try repository.loadSnapshot().lastEventID, occurredAt: clock.now)
        try repository.publish(event: next, next: .fixture(stateVersion: 7, tripID: next.tripID, lastEventID: next.id, phase: .preparing, lastUpdatedAt: clock.now))
        XCTAssertEqual(try repository.events().last?.characterProfile, a)
    }

    private func finishTripWithPendingPostcard(_ repository: TravelRepository, now: Date) throws -> TripEvent {
        let tripID = UUID(); var previous: UUID?; var postcard: TripEvent!
        for (offset, phase) in [TravelPhase.preparing, .transit, .exploring, .postcardReady, .returning, .resting].enumerated() {
            let event = TripEvent.fixture(tripID: tripID, previousEventID: previous, occurredAt: now, phase: phase,
                postcardStatus: phase == .postcardReady ? .pendingImage : .none)
            try repository.publish(event: event, next: .fixture(stateVersion: offset + 1, tripID: tripID, lastEventID: event.id, phase: phase, lastUpdatedAt: now))
            if phase == .postcardReady { postcard = event }; previous = event.id
        }
        return postcard
    }
}

private final class JourneyClock: TravelClock, @unchecked Sendable {
    var now: Date
    init(now: Date) { self.now = now }
}

private final class JourneyCharacterFixture {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("CharacterJourneyTests-\(UUID().uuidString)")
    let now = Date(timeIntervalSince1970: 1_000)
    var dataRoot: URL { root.appendingPathComponent("data") }
    deinit { try? FileManager.default.removeItem(at: root) }

    func importProfile(id: String, name: String) throws -> CharacterProfile {
        let source = root.appendingPathComponent("sources/\(id)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["id": id, "displayName": name, "description": "A travelling cat.", "spriteVersionNumber": 2, "spritesheetPath": "sprite.webp"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: source.appendingPathComponent("pet.json"))
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(at: project.appendingPathComponent("Sources/TravelUI/Resources/cute-black-cat-spritesheet.webp"), to: source.appendingPathComponent("sprite.webp"))
        return try CharacterProfileStore(dataRoot: dataRoot).importProfile(from: source)
    }

    func addHiddenAndTemporaryNamedAssets(to profile: CharacterProfile) throws -> [String] {
        guard case let .dataRootRelative(spritePath) = profile.sprite else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let assets = dataRoot.appendingPathComponent(spritePath).deletingLastPathComponent()
        let relativeAssets = String(assets.path.dropFirst(dataRoot.path.count + 1))
        let names = [".identity-note", "reference.tmp"]
        for name in names {
            try Data(name.utf8).write(to: assets.appendingPathComponent(name))
        }
        return names.map { "\(relativeAssets)/\($0)" }
    }
}
