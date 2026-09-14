import Darwin
import CryptoKit
import Foundation
import SQLite3
import XCTest
import TravelCore
@testable import TravelStorage

final class PetTravelPromptCoordinatorDurabilityTests: XCTestCase {
    @MainActor
    func testOfflineMultipleVersionCatchUpIsOldestFirstAndDeduplicated() throws {
        let harness = try makeHarness()
        let events = twoEventTrips(count: 3, seed: 10)
        try replaceRepository(harness.repository, events: events)

        try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        let expected = expectedPrompts(events)
        XCTAssertEqual(try harness.coordinator.pendingCount, expected.count)
        for prompt in expected {
            let delivery = PetTravelPromptDelivery.prompt(prompt)
            XCTAssertEqual(try harness.coordinator.nextDelivery(policy: openPolicy, hour: 12), [delivery])
            try harness.coordinator.deliverySucceeded(delivery)
        }
        try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        XCTAssertEqual(try harness.coordinator.nextDelivery(policy: openPolicy, hour: 12), [])
    }

    @MainActor
    func testPendingImageBecomesReadyAtSameRepositoryVersionExactlyOnce() throws {
        let harness = try makeHarness()
        let pending = postcardJourney(seed: 20, status: .pendingImage)
        try replaceRepository(harness.repository, events: pending)
        try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        try acknowledgeAll(harness.coordinator, policy: openPolicy)

        var ready = pending
        ready[3].postcardStatus = .ready
        ready[3].postcardRelativePath = "postcards/card.webp"
        try replaceRepository(harness.repository, events: ready)
        XCTAssertEqual(try harness.repository.loadSnapshot().stateVersion, pending.count)
        try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        let postcard = PetTravelPrompt.postcardReady(
            eventID: ready[3].id,
            tripID: ready[3].tripID,
            location: ready[3].location,
            mood: ready[3].mood.label,
            quote: ready[3].mood.quote
        )
        XCTAssertEqual(try harness.coordinator.nextDelivery(policy: openPolicy, hour: 12), [.prompt(postcard)])
        try harness.coordinator.deliverySucceeded(.prompt(postcard))
        try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        XCTAssertEqual(try harness.coordinator.nextDelivery(policy: openPolicy, hour: 12), [])
    }

    @MainActor
    func testClearAndRegrowBeyondOldCountStartsFreshGeneration() throws {
        let harness = try makeHarness()
        let old = twoEventTrips(count: 4, seed: 30)
        try replaceRepository(harness.repository, events: old)
        try harness.coordinator.ingestCurrent(policy: overnightPolicy, hour: 23)
        let oldSummary = try XCTUnwrap(try harness.coordinator.nextDelivery(policy: openPolicy, hour: 12).first)
        try harness.coordinator.deliverySucceeded(oldSummary)

        let replacement = twoEventTrips(count: 5, seed: 300)
        XCTAssertGreaterThan(replacement.count, old.count)
        try replaceRepository(harness.repository, events: replacement)
        try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        XCTAssertEqual(
            try harness.coordinator.nextDelivery(policy: openPolicy, hour: 12),
            [.prompt(expectedPrompts(replacement)[0])]
        )
    }

    @MainActor
    func testCapturedStaleContentsCannotBePassedToIngestCurrent() throws {
        let harness = try makeHarness()
        let staleEvents = twoEventTrips(count: 1, seed: 40)
        try replaceRepository(harness.repository, events: staleEvents)
        let stale = try harness.repository.loadContents()
        let currentEvents = twoEventTrips(count: 1, seed: 400)
        try replaceRepository(harness.repository, events: currentEvents)

        try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        XCTAssertNotEqual(stale, try harness.repository.loadContents())
        XCTAssertEqual(
            try harness.coordinator.nextDelivery(policy: openPolicy, hour: 12),
            [.prompt(expectedPrompts(currentEvents)[0])]
        )
    }

    @MainActor
    func testRepositoryLockContentionIsExposedAsCoordinatorStorageFailure() throws {
        let harness = try makeHarness()

        XCTAssertThrowsError(
            try harness.repository.withExclusiveLock {
                try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
            }
        ) { error in
            XCTAssertEqual(
                error as? PetTravelPromptCoordinatorError,
                .repositoryUnavailable("repository lock is unavailable")
            )
        }
        XCTAssertEqual(try harness.coordinator.pendingCount, 0)
    }

    @MainActor
    func testSameAnchorsButRewrittenPrefixResetsObservation() throws {
        let harness = try makeHarness()
        let original = postcardJourney(seed: 50, status: .pendingImage)
        try replaceRepository(harness.repository, events: original)
        try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        try acknowledgeAll(harness.coordinator, policy: openPolicy)

        var rewritten = original
        rewritten[1] = cloneEvent(
            rewritten[1],
            id: seededUUID(namespace: 9, seed: 501),
            previousEventID: rewritten[0].id
        )
        rewritten[2] = cloneEvent(rewritten[2], previousEventID: rewritten[1].id)
        try replaceRepository(harness.repository, events: rewritten)
        XCTAssertEqual(rewritten.first?.id, original.first?.id)
        XCTAssertEqual(rewritten.last?.id, original.last?.id)

        try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        XCTAssertEqual(
            try harness.coordinator.nextDelivery(policy: openPolicy, hour: 12),
            [.prompt(expectedPrompts(rewritten)[0])]
        )
    }

    @MainActor
    func testTenThousandEventLifecycleLeavesCompactCursorAfterAcknowledgement() throws {
        let harness = try makeHarness()
        let events = twoEventTrips(count: 5_001, seed: 1_000)
        XCTAssertGreaterThan(events.count, 10_000)
        try replaceRepository(harness.repository, events: events)
        try harness.coordinator.ingestCurrent(policy: overnightPolicy, hour: 23)
        let summary = try XCTUnwrap(try harness.coordinator.nextDelivery(policy: openPolicy, hour: 12).first)
        XCTAssertEqual(summary.identifiers.count, events.count)
        try harness.coordinator.deliverySucceeded(summary)

        let state = try promptPayload(harness.repository.root)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: state) as? [String: Any])
        let observation = try XCTUnwrap(object["observation"] as? [String: Any])
        XCTAssertEqual(observation["observedEventCount"] as? Int, events.count)
        XCTAssertNil(object["deliveredIdentifiers"])
        XCTAssertLessThan(state.count, 1_024)
    }

    @MainActor
    func testQuietSummaryAndNewOrdinaryPreserveUnifiedOrder() throws {
        let harness = try makeHarness()
        let firstTrip = twoEventTrips(count: 1, seed: 60)
        try replaceRepository(harness.repository, events: firstTrip)
        try harness.coordinator.ingestCurrent(policy: overnightPolicy, hour: 23)
        let summary = PetTravelPromptDelivery.summary(
            promptIDs: expectedPrompts(firstTrip).map(\.identifier),
            count: 2
        )

        let twoTrips = twoEventTrips(count: 2, seed: 60)
        try replaceRepository(harness.repository, events: twoTrips)
        try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        XCTAssertEqual(try harness.coordinator.nextDelivery(policy: openPolicy, hour: 12), [summary])
        try harness.coordinator.deliverySucceeded(summary)
        XCTAssertEqual(
            try harness.coordinator.nextDelivery(policy: openPolicy, hour: 12),
            [.prompt(expectedPrompts(twoTrips)[2])]
        )
    }

    @MainActor
    func testFailureRetriesAndFabricatedAcknowledgementDoesNotMutate() throws {
        let harness = try makeHarness()
        let events = twoEventTrips(count: 1, seed: 70)
        try replaceRepository(harness.repository, events: events)
        try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        let delivery = try XCTUnwrap(try harness.coordinator.nextDelivery(policy: openPolicy, hour: 12).first)
        let before = try promptPayload(harness.repository.root)
        let fabricated = PetTravelPromptDelivery.prompt(durabilityPrompt(seed: 999))
        XCTAssertThrowsError(try harness.coordinator.deliverySucceeded(fabricated))
        XCTAssertThrowsError(try harness.coordinator.deliveryFailed(fabricated))
        XCTAssertEqual(try promptPayload(harness.repository.root), before)
        XCTAssertEqual(try harness.coordinator.nextDelivery(policy: openPolicy, hour: 12), [])
        try harness.coordinator.deliveryFailed(delivery)
        XCTAssertEqual(try harness.coordinator.nextDelivery(policy: openPolicy, hour: 12), [delivery])
    }

    @MainActor
    func testSummaryInFlightGloballySuppressesNewerOrdinaryDelivery() throws {
        let harness = try makeHarness()
        let other = try PetTravelPromptCoordinator(repository: harness.repository)
        let firstTrip = twoEventTrips(count: 1, seed: 75)
        try replaceRepository(harness.repository, events: firstTrip)
        try harness.coordinator.ingestCurrent(policy: overnightPolicy, hour: 23)
        let summary = try XCTUnwrap(
            try harness.coordinator.nextDelivery(policy: openPolicy, hour: 12).first
        )

        let twoTrips = twoEventTrips(count: 2, seed: 75)
        try replaceRepository(harness.repository, events: twoTrips)
        try other.ingestCurrent(policy: openPolicy, hour: 12)
        XCTAssertEqual(try other.nextDelivery(policy: openPolicy, hour: 12), [])
        try harness.coordinator.deliverySucceeded(summary)
        XCTAssertEqual(
            try other.nextDelivery(policy: openPolicy, hour: 12),
            [.prompt(expectedPrompts(twoTrips)[2])]
        )
    }

    @MainActor
    func testTwoCoordinatorsShareOneDeliveryOwnership() throws {
        let harness = try makeHarness()
        let second = try PetTravelPromptCoordinator(repository: harness.repository)
        let events = twoEventTrips(count: 1, seed: 80)
        try replaceRepository(harness.repository, events: events)
        try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        let delivery = try XCTUnwrap(try harness.coordinator.nextDelivery(policy: openPolicy, hour: 12).first)
        XCTAssertEqual(try second.nextDelivery(policy: openPolicy, hour: 12), [])
        try harness.coordinator.deliveryFailed(delivery)
        XCTAssertEqual(try second.nextDelivery(policy: openPolicy, hour: 12), [delivery])
    }

    @MainActor
    func testSymlinkAncestorAliasIsRejectedAtConstruction() throws {
        let harness = try makeHarness()
        let container = harness.repository.root.deletingLastPathComponent()
        let alias = container.deletingLastPathComponent()
            .appendingPathComponent("alias-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: container)
        addTeardownBlock { try? FileManager.default.removeItem(at: alias) }
        let aliasRepository = try TravelRepository(
            root: alias.appendingPathComponent("repository", isDirectory: true)
        )
        XCTAssertThrowsError(try PetTravelPromptCoordinator(repository: aliasRepository))
    }

    @MainActor
    func testParentReplacementDoesNotSplitStableDeliveryLockNamespace() throws {
        let harness = try makeHarness()
        let events = twoEventTrips(count: 1, seed: 90)
        try replaceRepository(harness.repository, events: events)
        try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        let delivery = try XCTUnwrap(try harness.coordinator.nextDelivery(policy: openPolicy, hour: 12).first)

        let container = harness.repository.root.deletingLastPathComponent()
        let moved = container.deletingLastPathComponent().appendingPathComponent("moved-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: container, to: moved)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let replacementRepository = try TravelRepository(root: container.appendingPathComponent("repository"))
        let replacement = try PetTravelPromptCoordinator(repository: replacementRepository)
        let replacementEvents = twoEventTrips(count: 1, seed: 900)
        try replaceRepository(replacementRepository, events: replacementEvents)
        try replacement.ingestCurrent(policy: openPolicy, hour: 12)

        XCTAssertEqual(try replacement.nextDelivery(policy: openPolicy, hour: 12), [])
        try harness.coordinator.deliveryFailed(delivery)
        XCTAssertEqual(
            try replacement.nextDelivery(policy: openPolicy, hour: 12),
            [.prompt(expectedPrompts(replacementEvents)[0])]
        )
        try? FileManager.default.removeItem(at: moved)
    }

    @MainActor
    func testReorderedOrPartialStoredSummaryFailsClosedAndPreservesBytes() throws {
        for reorder in [true, false] {
            let harness = try makeHarness()
            let events = twoEventTrips(count: 1, seed: reorder ? 101 : 102)
            try replaceRepository(harness.repository, events: events)
            try harness.coordinator.ingestCurrent(policy: overnightPolicy, hour: 23)
            let delivery = try XCTUnwrap(
                try harness.coordinator.nextDelivery(policy: openPolicy, hour: 12).first
            )
            try harness.coordinator.deliveryFailed(delivery)
            var object = try envelopeObject(harness.repository.root)
            var summary = try XCTUnwrap(object["summary"] as? [String: Any])
            let identifiers = expectedPrompts(events).map(\.identifier)
            if reorder {
                summary["promptIDs"] = Array(identifiers.reversed())
            } else {
                summary["promptIDs"] = [identifiers[0]]
                summary["count"] = 1
            }
            object["summary"] = summary
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try writeStateFixture(bytes, root: harness.repository.root)

            let relaunched = try PetTravelPromptCoordinator(repository: harness.repository)
            XCTAssertThrowsError(try relaunched.pendingCount) { error in
                XCTAssertEqual(
                    error as? PetTravelPromptCoordinatorError,
                    .corruptValue(promptManifestURL(harness.repository.root).path)
                )
            }
            XCTAssertEqual(try promptPayload(harness.repository.root), bytes)
        }
    }

    @MainActor
    func testOversizeDuplicateUnknownAndTruncatedJSONFailClosed() throws {
        let validEmpty = #"{"nextSequence":0,"observation":null,"queue":[],"schemaVersion":2,"summary":null}"#
        let fixtures: [Data] = [
            Data(repeating: 0x20, count: 16 * 1_048_576 + 1),
            Data(#"{"schemaVersion":2,"schemaVersion":2,"nextSequence":0,"queue":[],"summary":null,"observation":null}"#.utf8),
            Data(validEmpty.dropLast().utf8) + Data(#", "surprise":true}"#.utf8),
            Data(#"{"schemaVersion":"#.utf8),
        ]
        for (index, bytes) in fixtures.enumerated() {
            let harness = try makeHarness()
            try replaceRepository(harness.repository, events: twoEventTrips(count: 1, seed: 2000 + index))
            try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
            try writeStateFixture(bytes, root: harness.repository.root)
            XCTAssertThrowsError(try harness.coordinator.pendingCount) { error in
                XCTAssertEqual(
                    error as? PetTravelPromptCoordinatorError,
                    .corruptValue(promptManifestURL(harness.repository.root).path)
                )
            }
            XCTAssertEqual(try promptPayload(harness.repository.root), bytes)
        }
    }

    @MainActor
    func testStrictCorruptionAndSymlinkFailClosedWithoutChangingBytes() throws {
        let harness = try makeHarness()
        try replaceRepository(harness.repository, events: twoEventTrips(count: 1, seed: 2100))
        try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        let corrupt = Data(#"{"schemaVersion":2,"schemaVersion":2}"#.utf8)
        try writeStateFixture(corrupt, root: harness.repository.root)
        XCTAssertThrowsError(try harness.coordinator.pendingCount)
        XCTAssertEqual(try promptPayload(harness.repository.root), corrupt)

        let stateURL = promptStateURL(harness.repository.root)
        try FileManager.default.removeItem(at: stateURL)
        let target = harness.repository.root.appendingPathComponent("outside")
        let targetBytes = Data("untouched".utf8)
        try targetBytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: stateURL, withDestinationURL: target)
        XCTAssertThrowsError(try harness.coordinator.pendingCount)
        XCTAssertEqual(try Data(contentsOf: target), targetBytes)
    }

    @MainActor
    func testStateDirectorySymlinkAndHardlinkedStateFailClosed() throws {
        do {
            let harness = try makeHarness()
            let events = twoEventTrips(count: 1, seed: 103)
            try replaceRepository(harness.repository, events: events)
            try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
            let state = harness.repository.root.appendingPathComponent("state", isDirectory: true)
            let original = harness.repository.root.appendingPathComponent("state-original", isDirectory: true)
            let bytes = try promptPayload(harness.repository.root)
            try FileManager.default.moveItem(at: state, to: original)
            try FileManager.default.createSymbolicLink(at: state, withDestinationURL: original)
            XCTAssertThrowsError(try harness.coordinator.pendingCount)
            XCTAssertEqual(
                try promptPayload(inStateDirectory: original),
                bytes
            )
        }

        do {
            let harness = try makeHarness()
            let events = twoEventTrips(count: 1, seed: 104)
            try replaceRepository(harness.repository, events: events)
            try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
            let stateURL = promptStateURL(harness.repository.root)
            let bytes = try Data(contentsOf: stateURL)
            let linked = harness.repository.root.appendingPathComponent("linked-prompt-state")
            try FileManager.default.linkItem(at: stateURL, to: linked)
            XCTAssertThrowsError(try harness.coordinator.pendingCount)
            XCTAssertEqual(try Data(contentsOf: stateURL), bytes)
            XCTAssertEqual(try Data(contentsOf: linked), bytes)
        }
    }

    @MainActor
    func testStateDirectorySwapFailsWithoutDetachedCommit() throws {
        let harness = try makeHarness()
        let events = twoEventTrips(count: 1, seed: 107)
        try replaceRepository(harness.repository, events: events)
        let state = harness.repository.root.appendingPathComponent("state", isDirectory: true)
        let original = harness.repository.root.appendingPathComponent("state-original", isDirectory: true)
        let attacker = harness.repository.root.appendingPathComponent("attacker", isDirectory: true)
        try FileManager.default.createDirectory(at: attacker, withIntermediateDirectories: true)
        harness.coordinator.afterOpeningStateDirectory = {
            try! FileManager.default.moveItem(at: state, to: original)
            try! FileManager.default.createSymbolicLink(at: state, withDestinationURL: attacker)
        }
        XCTAssertThrowsError(
            try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: attacker.appendingPathComponent(PetTravelPromptStore.databaseName).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: original.appendingPathComponent(PetTravelPromptStore.databaseName).path
            ),
            "ingest must not commit into the detached state directory"
        )
    }

    @MainActor
    func testLateStateDirectorySwapFailsBeforeInstallWithoutDetachedCommit() throws {
        let harness = try makeHarness()
        let first = twoEventTrips(count: 1, seed: 1075)
        try replaceRepository(harness.repository, events: first)
        try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        let state = harness.repository.root.appendingPathComponent("state", isDirectory: true)
        let before = try promptPayload(harness.repository.root)
        let detached = harness.repository.root.appendingPathComponent("detached-state", isDirectory: true)

        try replaceRepository(harness.repository, events: twoEventTrips(count: 2, seed: 1075))
        harness.coordinator.afterBeginningPromptTransaction = { _ in
            try! FileManager.default.moveItem(at: state, to: detached)
            try! FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
        }

        XCTAssertThrowsError(
            try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        )
        XCTAssertEqual(
            try promptPayload(inStateDirectory: detached),
            before
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: state.appendingPathComponent(PetTravelPromptStore.databaseName).path
            )
        )
    }

    @MainActor
    func testNextDeliveryStateSwapFailsWithoutDetachedCommitOrVisibleSuccess() throws {
        let harness = try makeHarness()
        let events = twoEventTrips(count: 1, seed: 1076)
        try replaceRepository(harness.repository, events: events)
        try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        let state = harness.repository.root.appendingPathComponent("state", isDirectory: true)
        let detached = harness.repository.root.appendingPathComponent("next-delivery-detached", isDirectory: true)
        let before = try promptPayload(harness.repository.root)
        harness.coordinator.afterCommittingPromptTransaction = { _ in
            try! FileManager.default.moveItem(at: state, to: detached)
            try! FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
        }

        XCTAssertThrowsError(
            try harness.coordinator.nextDelivery(policy: openPolicy, hour: 12)
        )
        XCTAssertEqual(try promptPayload(inStateDirectory: detached), before)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: state.appendingPathComponent(PetTravelPromptStore.databaseName).path
            )
        )
    }

    @MainActor
    func testAcknowledgementStateSwapFailsWithoutDetachedCommitOrVisibleSuccess() throws {
        let harness = try makeHarness()
        let events = twoEventTrips(count: 1, seed: 1077)
        try replaceRepository(harness.repository, events: events)
        try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        let delivery = try XCTUnwrap(
            try harness.coordinator.nextDelivery(policy: openPolicy, hour: 12).first
        )
        let state = harness.repository.root.appendingPathComponent("state", isDirectory: true)
        let detached = harness.repository.root.appendingPathComponent("ack-detached", isDirectory: true)
        let before = try promptPayload(harness.repository.root)
        harness.coordinator.afterCommittingPromptTransaction = { _ in
            try! FileManager.default.moveItem(at: state, to: detached)
            try! FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
        }

        XCTAssertThrowsError(try harness.coordinator.deliverySucceeded(delivery))
        XCTAssertNotEqual(try promptPayload(inStateDirectory: detached), before)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: state.appendingPathComponent(PetTravelPromptStore.databaseName).path
            )
        )
        XCTAssertThrowsError(try harness.coordinator.deliveryFailed(delivery)) { error in
            XCTAssertEqual(error as? PetTravelPromptCoordinatorError, .invalidAcknowledgement)
        }
    }

    @MainActor
    func testSymlinkAncestorRetargetMakesIngestFailWithoutMutatingEitherRoot() throws {
        let harness = try makeHarness()
        let oldEvents = twoEventTrips(count: 1, seed: 1071)
        try replaceRepository(harness.repository, events: oldEvents)
        try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        let oldState = try promptPayload(harness.repository.root)

        let container = harness.repository.root.deletingLastPathComponent()
        let parent = container.deletingLastPathComponent()
        let moved = parent.appendingPathComponent("retarget-old-\(UUID().uuidString)")
        let attackerContainer = parent.appendingPathComponent("retarget-new-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: container, to: moved)
        let attackerRepository = try TravelRepository(
            root: attackerContainer.appendingPathComponent("repository", isDirectory: true)
        )
        try replaceRepository(attackerRepository, events: twoEventTrips(count: 1, seed: 1072))
        try FileManager.default.createSymbolicLink(at: container, withDestinationURL: attackerContainer)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: container)
            try? FileManager.default.removeItem(at: moved)
            try? FileManager.default.removeItem(at: attackerContainer)
        }

        XCTAssertThrowsError(
            try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        )
        XCTAssertEqual(
            try promptPayload(moved.appendingPathComponent("repository")),
            oldState
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: promptManifestURL(attackerRepository.root).path
            )
        )
    }

    @MainActor
    func testRootReplacementDuringInFlightMakesIngestFailWithoutMutation() throws {
        let harness = try makeHarness()
        let oldEvents = twoEventTrips(count: 1, seed: 1073)
        try replaceRepository(harness.repository, events: oldEvents)
        try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        let delivery = try XCTUnwrap(
            try harness.coordinator.nextDelivery(policy: openPolicy, hour: 12).first
        )
        let oldState = try promptPayload(harness.repository.root)

        let container = harness.repository.root.deletingLastPathComponent()
        let moved = container.deletingLastPathComponent()
            .appendingPathComponent("inflight-old-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: container, to: moved)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let replacementRepository = try TravelRepository(
            root: container.appendingPathComponent("repository", isDirectory: true)
        )
        try replaceRepository(replacementRepository, events: twoEventTrips(count: 1, seed: 1074))
        addTeardownBlock { try? FileManager.default.removeItem(at: moved) }

        XCTAssertThrowsError(
            try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        )
        XCTAssertEqual(
            try promptPayload(moved.appendingPathComponent("repository")),
            oldState
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: promptManifestURL(replacementRepository.root).path
            )
        )

        try harness.coordinator.deliverySucceeded(delivery)
        let movedRepository = try TravelRepository(
            root: moved.appendingPathComponent("repository", isDirectory: true)
        )
        let movedCoordinator = try PetTravelPromptCoordinator(repository: movedRepository)
        XCTAssertEqual(try movedCoordinator.pendingCount, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: promptManifestURL(replacementRepository.root).path
            )
        )
    }

    @MainActor
    func testInstalledResetReleasesDeliveryOwnershipWhenPostCommitCheckFails() throws {
        let harness = try makeHarness()
        let other = try PetTravelPromptCoordinator(repository: harness.repository)
        let events = twoEventTrips(count: 1, seed: 108)
        try replaceRepository(harness.repository, events: events)
        try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        let stale = try XCTUnwrap(
            try harness.coordinator.nextDelivery(policy: openPolicy, hour: 12).first
        )
        try replaceRepository(harness.repository, events: [])
        harness.coordinator.afterCommittingPromptTransaction = { _ in throw PromptInjectedFailure.stop }
        XCTAssertThrowsError(
            try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        )
        XCTAssertThrowsError(try harness.coordinator.deliverySucceeded(stale)) { error in
            XCTAssertEqual(error as? PetTravelPromptCoordinatorError, .invalidAcknowledgement)
        }
        XCTAssertEqual(try other.nextDelivery(policy: openPolicy, hour: 12), [])
    }

    @MainActor
    func testInstalledAcknowledgementReleasesOwnershipWhenPostCommitCheckFails() throws {
        let harness = try makeHarness()
        let other = try PetTravelPromptCoordinator(repository: harness.repository)
        let events = twoEventTrips(count: 1, seed: 1080)
        try replaceRepository(harness.repository, events: events)
        try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        let first = try XCTUnwrap(
            try harness.coordinator.nextDelivery(policy: openPolicy, hour: 12).first
        )
        harness.coordinator.afterCommittingPromptTransaction = { _ in throw PromptInjectedFailure.stop }

        XCTAssertThrowsError(try harness.coordinator.deliverySucceeded(first))
        XCTAssertEqual(
            try other.nextDelivery(policy: openPolicy, hour: 12),
            [.prompt(expectedPrompts(events)[1])]
        )
        XCTAssertThrowsError(try harness.coordinator.deliverySucceeded(first)) { error in
            XCTAssertEqual(error as? PetTravelPromptCoordinatorError, .invalidAcknowledgement)
        }
    }

    @MainActor
    func testSubprocessImmediateExitPersistsRetryAndAcknowledgement() throws {
        let harness = try makeHarness()
        let events = twoEventTrips(count: 1, seed: 109)
        try replaceRepository(harness.repository, events: events)
        try runSubprocess(mode: "enqueue", root: harness.repository.root)

        let relaunched = try PetTravelPromptCoordinator(repository: harness.repository)
        XCTAssertEqual(try relaunched.pendingCount, 2)
        let first = try XCTUnwrap(
            try relaunched.nextDelivery(policy: openPolicy, hour: 12).first
        )
        try relaunched.deliveryFailed(first)
        try runSubprocess(mode: "acknowledge", root: harness.repository.root)

        let completed = try PetTravelPromptCoordinator(repository: harness.repository)
        XCTAssertEqual(try completed.pendingCount, 1)
        try completed.ingestCurrent(policy: openPolicy, hour: 12)
        XCTAssertEqual(try completed.pendingCount, 1)
        XCTAssertEqual(
            try completed.nextDelivery(policy: openPolicy, hour: 12),
            [.prompt(expectedPrompts(events)[1])]
        )
    }

    @MainActor
    func testSubprocessCrashBeforeAndAfterSQLiteCommitHasAtomicBoundary() throws {
        let harness = try makeHarness()
        let first = twoEventTrips(count: 1, seed: 1095)
        try replaceRepository(harness.repository, events: first)
        try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        XCTAssertEqual(try harness.coordinator.pendingCount, 2)

        let expanded = twoEventTrips(count: 2, seed: 1095)
        try replaceRepository(harness.repository, events: expanded)
        try runSubprocess(mode: "crash-before-commit", root: harness.repository.root)
        XCTAssertEqual(
            try PetTravelPromptCoordinator(repository: harness.repository).pendingCount,
            2,
            "an uncommitted SQLite transaction must roll back on process exit"
        )

        try runSubprocess(mode: "crash-after-commit", root: harness.repository.root)
        XCTAssertEqual(
            try PetTravelPromptCoordinator(repository: harness.repository).pendingCount,
            4,
            "a FULL-synchronous commit must survive immediate process exit"
        )
    }

    @MainActor
    func testFreshRootCrashBeforeFirstEnvelopeCommitRelaunchesEmptyAndRetries() throws {
        let harness = try makeHarness()
        let events = twoEventTrips(count: 1, seed: 1096)
        try replaceRepository(harness.repository, events: events)

        try runSubprocess(mode: "crash-before-commit", root: harness.repository.root)

        let relaunched = try PetTravelPromptCoordinator(repository: harness.repository)
        XCTAssertEqual(try relaunched.pendingCount, 0)
        try relaunched.ingestCurrent(policy: openPolicy, hour: 12)
        XCTAssertEqual(try relaunched.pendingCount, 2)
        XCTAssertEqual(
            try relaunched.nextDelivery(policy: openPolicy, hour: 12),
            [.prompt(expectedPrompts(events)[0])]
        )
    }

    @MainActor
    func testBootstrapReplacementThenImmediateExitDoesNotInstallAttemptedEnvelope() throws {
        let harness = try makeHarness()
        let events = twoEventTrips(count: 1, seed: 1097)
        try replaceRepository(harness.repository, events: events)

        try runSubprocess(mode: "crash-after-bootstrap-replacement", root: harness.repository.root)

        let relaunched = try PetTravelPromptCoordinator(repository: harness.repository)
        XCTAssertEqual(try relaunched.pendingCount, 0)
        try relaunched.ingestCurrent(policy: openPolicy, hour: 12)
        XCTAssertEqual(try relaunched.pendingCount, 2)
    }

    @MainActor
    func testZeroByteJournalImmediateExitRecoversExistingEnvelope() throws {
        let harness = try makeHarness()
        let events = twoEventTrips(count: 1, seed: 1098)
        try replaceRepository(harness.repository, events: events)
        try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        let before = try promptPayload(harness.repository.root)

        try runSubprocess(mode: "crash-zero-journal", root: harness.repository.root)

        let relaunched = try PetTravelPromptCoordinator(repository: harness.repository)
        XCTAssertEqual(try relaunched.pendingCount, 2)
        XCTAssertEqual(try promptPayload(harness.repository.root), before)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: promptManifestURL(harness.repository.root).path + "-journal"
            )
        )
    }

    @MainActor
    func testFirstStateDirectoryCreationFsyncsRoot() throws {
        let harness = try makeHarness()
        try FileManager.default.removeItem(at: harness.repository.root.appendingPathComponent("state"))
        var calls = 0
        harness.coordinator.rootDirectorySync = { descriptor in
            calls += 1
            return fsync(descriptor)
        }
        XCTAssertEqual(try harness.coordinator.pendingCount, 0)
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testFailedFirstStateDirectoryFsyncIsRetriedOnNextAccess() throws {
        let harness = try makeHarness()
        let state = harness.repository.root.appendingPathComponent("state")
        try FileManager.default.removeItem(at: state)
        var calls = 0
        harness.coordinator.rootDirectorySync = { _ in
            calls += 1
            return -1
        }

        XCTAssertThrowsError(try harness.coordinator.pendingCount)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))

        harness.coordinator.rootDirectorySync = { descriptor in
            calls += 1
            return fsync(descriptor)
        }
        XCTAssertEqual(try harness.coordinator.pendingCount, 0)
        XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testDeliveryOwnershipDescriptorDoesNotSurviveExec() throws {
        let harness = try makeHarness()
        let events = twoEventTrips(count: 1, seed: 110)
        try replaceRepository(harness.repository, events: events)
        try harness.coordinator.ingestCurrent(policy: openPolicy, hour: 12)
        let marker = harness.repository.root.deletingLastPathComponent().appendingPathComponent("exec-marker")
        let child = try launchExecLockHelper(root: harness.repository.root, marker: marker)
        defer {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        try waitForFile(marker)

        let retry = try PetTravelPromptCoordinator(repository: harness.repository)
        XCTAssertEqual(
            try retry.nextDelivery(policy: openPolicy, hour: 12),
            [.prompt(expectedPrompts(events)[0])],
            "exec must close the child coordinator's delivery lock descriptor"
        )
    }

    func testPromptDeliveryCodableRoundTripAndIdentifiers() throws {
        let prompt = durabilityPrompt(seed: 120)
        let deliveries: [PetTravelPromptDelivery] = [
            .prompt(prompt),
            .summary(promptIDs: [prompt.identifier, "another"], count: 2),
        ]
        for delivery in deliveries {
            XCTAssertEqual(try JSONDecoder().decode(PetTravelPromptDelivery.self, from: JSONEncoder().encode(delivery)), delivery)
        }
        XCTAssertEqual(deliveries[0].identifiers, [prompt.identifier])
        XCTAssertEqual(deliveries[1].identifiers, [prompt.identifier, "another"])
    }

    private var openPolicy: NotificationPolicy { .init(quietStart: 8, quietEnd: 8) }
    private var overnightPolicy: NotificationPolicy { .init(quietStart: 22, quietEnd: 8) }

    @MainActor
    private func acknowledgeAll(_ coordinator: PetTravelPromptCoordinator, policy: NotificationPolicy) throws {
        while let delivery = try coordinator.nextDelivery(policy: policy, hour: 12).first {
            try coordinator.deliverySucceeded(delivery)
        }
    }

    @MainActor
    private func makeHarness() throws -> PromptHarness {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("PetTravelPromptDurabilityTests-\(UUID().uuidString)", isDirectory: true)
        let root = container.appendingPathComponent("repository", isDirectory: true)
        let repository = try TravelRepository(root: root)
        addTeardownBlock {
            removeUnlockedPromptTestLocks(for: repository.root)
            try? FileManager.default.removeItem(at: container)
        }
        return PromptHarness(
            repository: repository,
            coordinator: try PetTravelPromptCoordinator(repository: repository)
        )
    }

    private func launchExecLockHelper(root: URL, marker: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest", "-XCTest",
            "TravelStorageTests.PetTravelPromptSubprocessHelperTests/testRunHelper",
            Bundle(for: PetTravelPromptSubprocessHelperTests.self).bundleURL.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["TRAVEL_CAT_PROMPT_HELPER_MODE"] = "exec-lock"
        environment["TRAVEL_CAT_PROMPT_HELPER_ROOT"] = root.path
        environment["TRAVEL_CAT_PROMPT_HELPER_MARKER"] = marker.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func runSubprocess(mode: String, root: URL) throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest", "-XCTest",
            "TravelStorageTests.PetTravelPromptSubprocessHelperTests/testRunHelper",
            Bundle(for: PetTravelPromptSubprocessHelperTests.self).bundleURL.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["TRAVEL_CAT_PROMPT_HELPER_MODE"] = mode
        environment["TRAVEL_CAT_PROMPT_HELPER_ROOT"] = root.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            "subprocess failed: \(String(decoding: output, as: UTF8.self))"
        )
    }

    private func envelopeObject(_ root: URL) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: promptPayload(root))
                as? [String: Any]
        )
    }

    private func writeStateFixture(_ bytes: Data, root: URL) throws {
        try writePromptPayload(bytes, root: root)
    }

    private func waitForFile(_ url: URL) throws {
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: url.path) {
            usleep(10_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}

final class PetTravelPromptSubprocessHelperTests: XCTestCase {
    @MainActor
    func testRunHelper() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let mode = environment["TRAVEL_CAT_PROMPT_HELPER_MODE"] else {
            throw XCTSkip("Only runs as a prompt durability child")
        }
        let root = URL(fileURLWithPath: try XCTUnwrap(environment["TRAVEL_CAT_PROMPT_HELPER_ROOT"]))
        let repository = try TravelRepository(root: root)
        let coordinator = try PetTravelPromptCoordinator(repository: repository)
        let policy = NotificationPolicy(quietStart: 8, quietEnd: 8)
        switch mode {
        case "enqueue":
            try coordinator.ingestCurrent(policy: policy, hour: 12)
            guard try coordinator.nextDelivery(policy: policy, hour: 12).count == 1 else {
                throw PromptHelperError.missingDelivery
            }
            _exit(EXIT_SUCCESS)
        case "acknowledge":
            guard let delivery = try coordinator.nextDelivery(policy: policy, hour: 12).first else {
                throw PromptHelperError.missingDelivery
            }
            try coordinator.deliverySucceeded(delivery)
            _exit(EXIT_SUCCESS)
        case "crash-before-commit":
            coordinator.beforeCommittingPromptTransaction = { _ in _exit(EXIT_SUCCESS) }
            try coordinator.ingestCurrent(policy: policy, hour: 12)
            throw PromptHelperError.missingDelivery
        case "crash-after-commit":
            coordinator.afterCommittingPromptTransaction = { _ in _exit(EXIT_SUCCESS) }
            try coordinator.ingestCurrent(policy: policy, hour: 12)
            throw PromptHelperError.missingDelivery
        case "crash-after-bootstrap-replacement":
            coordinator.beforeInstallingPromptBootstrap = { bootstrapPath in
                let bootstrap = URL(fileURLWithPath: bootstrapPath)
                let displaced = bootstrap.deletingLastPathComponent()
                    .appendingPathComponent("initialized-bootstrap")
                try! FileManager.default.moveItem(at: bootstrap, to: displaced)
                try! FileManager.default.copyItem(at: displaced, to: bootstrap)
                _ = chmod(bootstrap.path, 0o600)
                _exit(EXIT_SUCCESS)
            }
            try coordinator.ingestCurrent(policy: policy, hour: 12)
            throw PromptHelperError.missingDelivery
        case "crash-zero-journal":
            let state = root.appendingPathComponent("state", isDirectory: true)
            let journal = state.appendingPathComponent(PetTravelPromptStore.databaseName + "-journal")
            let descriptor = open(
                journal.path,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0 else { throw PromptHelperError.database }
            guard fsync(descriptor) == 0 else { throw PromptHelperError.database }
            _ = close(descriptor)
            let directory = open(state.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0, fsync(directory) == 0 else { throw PromptHelperError.database }
            _ = close(directory)
            _exit(EXIT_SUCCESS)
        case "exec-lock":
            let marker = try XCTUnwrap(environment["TRAVEL_CAT_PROMPT_HELPER_MARKER"])
            guard try coordinator.nextDelivery(policy: policy, hour: 12).count == 1 else {
                throw PromptHelperError.missingDelivery
            }
            let command = strdup("sh")
            let flag = strdup("-c")
            let script = strdup("/usr/bin/touch \(marker); /bin/sleep 2")
            defer { free(command); free(flag); free(script) }
            var arguments: [UnsafeMutablePointer<CChar>?] = [command, flag, script, nil]
            arguments.withUnsafeMutableBufferPointer { buffer in
                _ = execv("/bin/sh", buffer.baseAddress!)
            }
            throw PromptHelperError.execFailed
        default:
            throw PromptHelperError.unknownMode
        }
    }
}

private struct PromptHarness {
    let repository: TravelRepository
    let coordinator: PetTravelPromptCoordinator
}

private enum PromptHelperError: Error { case missingDelivery, execFailed, unknownMode, database }
private enum PromptInjectedFailure: Error { case stop }

private func removeUnlockedPromptTestLocks(for root: URL) {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("travel-cat-pet-prompt-locks-v1", isDirectory: true)
    let directory = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { return }
    defer { _ = close(directory) }
    let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    for suffix in [".mutation.lock", ".delivery.lock"] {
        let name = ".pet-travel-prompts-" + digest + suffix
        let descriptor = openat(directory, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { continue }
        var opened = stat()
        var reachable = stat()
        if fstat(descriptor, &opened) == 0,
           (opened.st_mode & S_IFMT) == S_IFREG,
           opened.st_nlink == 1,
           opened.st_uid == geteuid(),
           flock(descriptor, LOCK_EX | LOCK_NB) == 0,
           fstatat(directory, name, &reachable, AT_SYMLINK_NOFOLLOW) == 0,
           opened.st_dev == reachable.st_dev,
           opened.st_ino == reachable.st_ino {
            _ = unlinkat(directory, name, 0)
            _ = fsync(directory)
            _ = flock(descriptor, LOCK_UN)
        }
        _ = close(descriptor)
    }
}

private func promptStateURL(_ root: URL) -> URL {
    promptStateURL(inStateDirectory: root.appendingPathComponent("state", isDirectory: true))
}

private func promptManifestURL(_ root: URL) -> URL {
    root.appendingPathComponent("state", isDirectory: true)
        .appendingPathComponent(PetTravelPromptStore.databaseName)
}

private func promptStateURL(inStateDirectory state: URL) -> URL {
    guard let resolved = realpath(state.path, nil) else {
        return state.appendingPathComponent(PetTravelPromptStore.databaseName)
    }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        .appendingPathComponent(PetTravelPromptStore.databaseName)
}

private func promptPayload(_ root: URL) throws -> Data {
    try promptPayload(inStateDirectory: root.appendingPathComponent("state", isDirectory: true))
}

private func promptPayload(inStateDirectory state: URL) throws -> Data {
    var database: OpaquePointer?
    let url = promptStateURL(inStateDirectory: state)
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
          let database else { throw PromptHelperError.database }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "SELECT payload FROM prompt_state WHERE id = 1", -1, &statement, nil) == SQLITE_OK,
          let statement else { throw PromptHelperError.database }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
          sqlite3_column_type(statement, 0) == SQLITE_BLOB else { throw PromptHelperError.database }
    let count = Int(sqlite3_column_bytes(statement, 0))
    guard count > 0, let bytes = sqlite3_column_blob(statement, 0) else { throw PromptHelperError.database }
    return Data(bytes: bytes, count: count)
}

private func writePromptPayload(_ payload: Data, root: URL) throws {
    var database: OpaquePointer?
    let url = promptStateURL(root)
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
          let database else { throw PromptHelperError.database }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "UPDATE prompt_state SET payload = ?, digest = ? WHERE id = 1", -1, &statement, nil) == SQLITE_OK,
          let statement else { throw PromptHelperError.database }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let bindBlob = payload.withUnsafeBytes {
        sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(payload.count), transient)
    }
    let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    guard bindBlob == SQLITE_OK,
          sqlite3_bind_text(statement, 2, digest, -1, transient) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_DONE else { throw PromptHelperError.database }
}

private func replaceRepository(_ repository: TravelRepository, events: [TripEvent]) throws {
    let encoder = JSONEncoder.travelCat
    encoder.outputFormatting = [.sortedKeys]
    var journal = Data()
    for event in events {
        journal.append(try encoder.encode(event))
        journal.append(0x0A)
    }
    try journal.write(to: repository.root.appendingPathComponent("journal/events.jsonl"), options: .atomic)
    let snapshot: TripSnapshot
    if let last = events.last {
        snapshot = TripSnapshot(
            stateVersion: events.count,
            tripID: last.tripID,
            lastEventID: last.id,
            phase: last.phase,
            nextActionAt: last.occurredAt,
            lastUpdatedAt: last.occurredAt,
            usedItemIDs: [],
            visitedPlaces: [],
            mood: last.mood,
            openHook: last.openHook
        )
    } else {
        snapshot = .empty(now: Date(timeIntervalSince1970: 0))
    }
    try encoder.encode(snapshot).write(to: repository.snapshotURL, options: .atomic)
}

private func twoEventTrips(count: Int, seed: Int) -> [TripEvent] {
    var events: [TripEvent] = []
    for index in 0..<count {
        let tripID = seededUUID(namespace: 1, seed: seed + index)
        let departure = travelEvent(
            id: seededUUID(namespace: 2, seed: (seed + index) * 2),
            tripID: tripID,
            previousEventID: events.last?.id,
            occurredAt: events.count,
            phase: .preparing
        )
        let returned = travelEvent(
            id: seededUUID(namespace: 2, seed: (seed + index) * 2 + 1),
            tripID: tripID,
            previousEventID: departure.id,
            occurredAt: events.count + 1,
            phase: .resting
        )
        events.append(contentsOf: [departure, returned])
    }
    return events
}

private func postcardJourney(seed: Int, status: PostcardStatus) -> [TripEvent] {
    let tripID = seededUUID(namespace: 3, seed: seed)
    let phases: [TravelPhase] = [.preparing, .transit, .exploring, .postcardReady, .returning, .resting]
    var events: [TripEvent] = []
    for (index, phase) in phases.enumerated() {
        events.append(travelEvent(
            id: seededUUID(namespace: 4, seed: seed * 10 + index),
            tripID: tripID,
            previousEventID: events.last?.id,
            occurredAt: index,
            phase: phase,
            postcardStatus: phase == .postcardReady ? status : .none
        ))
    }
    return events
}

private func travelEvent(
    id: UUID,
    tripID: UUID,
    previousEventID: UUID?,
    occurredAt: Int,
    phase: TravelPhase,
    postcardStatus: PostcardStatus = .none
) -> TripEvent {
    TripEvent(
        id: id,
        tripID: tripID,
        previousEventID: previousEventID,
        occurredAt: Date(timeIntervalSince1970: TimeInterval(occurredAt)),
        phase: phase,
        location: phase == .exploring || phase == .postcardReady
            ? Location(country: "中国", city: "杭州", place: "湖边") : nil,
        transport: nil,
        summary: "旅行事件 \(occurredAt)",
        mood: Mood(level: 2, label: "期待", quote: "风很好。"),
        continuityReferences: [],
        openHook: nil,
        consumedItemID: nil,
        postcardStatus: postcardStatus,
        postcardRelativePath: postcardStatus == .ready ? "postcards/card.webp" : nil
    )
}

private func cloneEvent(
    _ event: TripEvent,
    id: UUID? = nil,
    previousEventID: UUID?? = nil
) -> TripEvent {
    TripEvent(
        id: id ?? event.id,
        tripID: event.tripID,
        previousEventID: previousEventID ?? event.previousEventID,
        occurredAt: event.occurredAt,
        phase: event.phase,
        location: event.location,
        transport: event.transport,
        summary: event.summary,
        mood: event.mood,
        continuityReferences: event.continuityReferences,
        openHook: event.openHook,
        consumedItemID: event.consumedItemID,
        postcardStatus: event.postcardStatus,
        postcardRelativePath: event.postcardRelativePath
    )
}

private func expectedPrompts(_ events: [TripEvent]) -> [PetTravelPrompt] {
    PetTravelPromptDetector.detect(
        previous: RepositoryContents(snapshot: .empty(now: Date(timeIntervalSince1970: 0)), events: []),
        current: RepositoryContents(snapshot: .empty(now: Date(timeIntervalSince1970: 0)), events: events)
    )
}

private func durabilityPrompt(seed: Int) -> PetTravelPrompt {
    .departed(
        eventID: seededUUID(namespace: 7, seed: seed),
        tripID: seededUUID(namespace: 8, seed: seed),
        location: nil,
        summary: "提示 \(seed)"
    )
}

private func seededUUID(namespace: Int, seed: Int) -> UUID {
    UUID(uuidString: String(format: "%08d-0000-0000-%04d-%012d", namespace, namespace, seed))!
}
