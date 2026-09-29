import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import TravelCore
import TravelUI
@testable import TravelStorage
@testable import TravelCatApp

@MainActor
final class AutomaticTravelLifecycleTests: XCTestCase {
    func testRecoveryRefreshNotifiesMenuAfterPlansLoadAndOnBacklogError() async throws {
        let f = try LifecycleFixture()
        defer { f.clean() }
        try await f.startThreePostcardTrip()
        let model = AppModel(snapshot: try f.repository.loadSnapshot(), events: try f.repository.events(), dataRoot: f.root)
        var observed: [UUID?] = []
        let controller = PostcardRecoveryController(repository: f.repository, model: model, worker: f.makeWorker(),
            settings: { .init(mode: .fast) }, isReady: { false },
            didRefresh: { observed.append(model.latestAvailableTripID()) })
        defer { controller.stop() }
        controller.start()
        XCTAssertEqual(observed.last!, try f.repository.loadSnapshot().tripID)
        XCTAssertEqual(model.postcardWorkItems.count, 3)
        let broken = Data("corrupt supplemental records".utf8)
        let url = f.root.appendingPathComponent("state/postcard-backlog.json")
        try broken.write(to: url)
        controller.refresh()
        XCTAssertEqual(observed.count, 2)
        XCTAssertNotNil(model.postcardWorkError)
        XCTAssertEqual(model.postcardWorkItems.count, 3)
        XCTAssertEqual(try Data(contentsOf: url), broken)
    }


    func testChangingModeReschedulesExistingPhaseAndSurvivesRestart() async throws {
        let f = try LifecycleFixture()
        defer { f.clean() }
        try await f.reach(.preparing)
        let version = try f.repository.loadSnapshot().stateVersion
        let daily = try await f.worker.step(settings: .init(mode: .daily))
        XCTAssertGreaterThanOrEqual(daily.nextCheckAt.timeIntervalSince(f.clock.now), 900)
        let fast = try await f.worker.step(settings: .init(mode: .fast))
        XCTAssertEqual(fast.nextCheckAt, f.clock.now.addingTimeInterval(120))
        f.clock.advance(30)
        let restarted = f.makeWorker()
        let again = try await restarted.step(settings: .init(mode: .fast))
        XCTAssertEqual(again.nextCheckAt, fast.nextCheckAt)
        XCTAssertEqual(try f.repository.loadSnapshot().stateVersion, version)
    }

    func testChangingFastRestToDailyRestRequiresTwelveHoursAndNewDay() async throws {
        let f = try LifecycleFixture()
        defer { f.clean() }
        try await f.reach(.resting)
        let count = try f.repository.events().count
        let result = try await f.worker.step(settings: .init(mode: .daily))
        XCTAssertGreaterThanOrEqual(result.nextCheckAt.timeIntervalSince(f.clock.now), 12 * 3600)
        XCTAssertFalse(f.calendar.isDate(result.nextCheckAt, inSameDayAs: f.clock.now))
        XCTAssertTrue((8..<20).contains(f.calendar.component(.hour, from: result.nextCheckAt)))
        f.clock.advance(121)
        _ = try await f.worker.step(settings: .init(mode: .daily))
        XCTAssertEqual(try f.repository.events().count, count)
    }

    func testNarrativeFailureDoesNotStarveDueImageRetry() async throws {
        let f = try LifecycleFixture()
        defer { f.clean() }
        try await f.reach(.postcardReady)
        f.clock.advance(15) // Persisted minimum model-action gap.
        f.generator.imageWidth = nil
        _ = try await f.worker.step(settings: .init(mode: .fast))
        XCTAssertEqual(f.generator.imageCalls, 1)
        f.clock.advance(121)
        f.generator.failNarrative = true
        _ = try await f.worker.step(settings: .init(mode: .fast))
        // At the persisted model-action boundary, narrative backoff must not starve a due image retry.
        f.clock.advance(15)
        _ = try await f.worker.step(settings: .init(mode: .fast))
        XCTAssertEqual(f.generator.imageCalls, 2)
    }

    func testDifferentWorkersHoldOneLockAcrossGeneration() async throws {
        let f = try LifecycleFixture()
        defer { f.clean() }
        try await f.reach(.preparing)
        f.clock.advance(121)
        f.generator.holdNarrative = true
        let running = Task { try await f.worker.step(settings: .init(mode: .fast)) }
        await waitUntil { f.generator.pending != nil }
        let requests = f.generator.narrativeCalls
        let second = f.makeWorker()
        _ = try await second.step(settings: .init(mode: .fast))
        XCTAssertEqual(f.generator.narrativeCalls, requests)
        f.generator.release()
        _ = try await running.value
        XCTAssertEqual(try f.repository.loadSnapshot().phase, .transit)
    }

    func testCancelledLateNarrativeCannotPublishAndLockBecomesAvailable() async throws {
        let f = try LifecycleFixture()
        defer { f.clean() }
        try await f.reach(.preparing)
        f.clock.advance(121)
        let before = try f.repository.loadSnapshot()
        f.generator.holdNarrative = true
        let running = Task { try await f.worker.step(settings: .init(mode: .fast)) }
        await waitUntil { f.generator.pending != nil }
        running.cancel()
        f.generator.release()
        do { _ = try await running.value; XCTFail("cancelled generation must not publish") }
        catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
        XCTAssertEqual(try f.repository.loadSnapshot(), before)
        f.clock.advance(15)
        _ = try await f.makeWorker().step(settings: .init(mode: .fast))
        XCTAssertEqual(try f.repository.loadSnapshot().phase, .transit)
    }

    func testPauseAndResumeIgnoresOldCompletion() async throws {
        var completions: [CheckedContinuation<AutomaticTravelOutcome, Never>] = []
        let controller = AutomaticTravelController(isEnabled: { true }, run: {
            await withCheckedContinuation { completions.append($0) }
        })
        defer { controller.stop() }
        controller.refresh()
        await waitUntil { completions.count == 1 }
        controller.pause()
        controller.refresh()
        await waitUntil { completions.count == 2 }
        completions[1].resume(returning: .init(nextCheckAt: Date().addingTimeInterval(120), message: "new"))
        await waitUntil { controller.message == "new" }
        completions[0].resume(returning: .init(nextCheckAt: Date().addingTimeInterval(120), message: "old"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(controller.message, "new")
        XCTAssertFalse(controller.isRunning)
    }

    func testSettingsChangeCancelsOldGenerationAndSchedulesFreshWork() async throws {
        var completions: [CheckedContinuation<AutomaticTravelOutcome, Never>] = []
        let controller = AutomaticTravelController(isEnabled: { true }, run: {
            await withCheckedContinuation { completions.append($0) }
        })
        defer { controller.stop() }
        controller.refresh()
        await waitUntil { completions.count == 1 }
        controller.settingsDidChange()
        await waitUntil { completions.count == 2 }
        completions[0].resume(returning: .init(nextCheckAt: Date(), message: "old mode"))
        completions[1].resume(returning: .init(nextCheckAt: Date().addingTimeInterval(120), message: "new mode"))
        await waitUntil { controller.message == "new mode" }
        XCTAssertFalse(controller.isRunning)
    }

    func testInvalidImageConsumesOneRetryInsteadOfWaitingForLeaseExpiry() async throws {
        let f = try LifecycleFixture()
        defer { f.clean() }
        try await f.reach(.postcardReady)
        f.clock.advance(15) // Persisted minimum model-action gap.
        let event = try XCTUnwrap(f.repository.events().last)
        f.generator.imageWidth = 1024
        f.generator.imageHeight = 1024
        _ = try await f.worker.step(settings: .init(mode: .fast))
        let retry = try XCTUnwrap(f.repository.imageRetry(for: event.id))
        XCTAssertEqual(retry.attemptCount, 1)
        XCTAssertNil(retry.activeAttemptToken)
        XCTAssertNotNil(retry.retryAt)
    }

    func testReadyIntentSurvivesJournalWriteFailureAndWorkerRestart() async throws {
        let f = try LifecycleFixture()
        defer { f.clean() }
        try await f.reach(.postcardReady)
        f.clock.advance(15) // Persisted minimum model-action gap.
        let event = try XCTUnwrap(f.repository.events().last)
        f.generator.imageWidth = 1152
        f.generator.imageHeight = 768
        let directory = f.root.appendingPathComponent("journal")
        f.repository.imageValidationHook = {
            try! FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        _ = try await f.worker.step(settings: .init(mode: .fast))
        f.repository.imageValidationHook = nil
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let reopened = try TravelRepository(root: f.root, clock: f.clock)
        let recovered = try XCTUnwrap(reopened.events().first { $0.id == event.id })
        XCTAssertEqual(recovered.postcardStatus, .ready)
        let path = try XCTUnwrap(recovered.postcardRelativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(path).path))
        XCTAssertEqual(try reopened.imageRetry(for: event.id)?.attemptCount, 0)
    }

    func testDailyDepartureFinishingAfterTwentyIsDiscardedAndRescheduled() async throws {
        let f = try LifecycleFixture()
        defer { f.clean() }
        let initial = try await f.worker.step(settings: .init(mode: .daily))
        f.clock.set(initial.nextCheckAt)
        f.generator.onNarrative = {
            let late = f.calendar.startOfDay(for: f.clock.now).addingTimeInterval(20 * 3600 + 60)
            f.clock.set(late)
        }
        let result = try await f.worker.step(settings: .init(mode: .daily))
        XCTAssertEqual(f.generator.narrativeCalls, 1)
        XCTAssertEqual(try f.repository.events().count, 0)
        XCTAssertEqual(try f.repository.loadSnapshot().stateVersion, 0)
        XCTAssertGreaterThan(result.nextCheckAt, f.clock.now)
        XCTAssertTrue((8..<20).contains(f.calendar.component(.hour, from: result.nextCheckAt)))
        f.generator.onNarrative = nil
        let reopened = try await f.makeWorker().step(settings: .init(mode: .daily))
        XCTAssertEqual(reopened.nextCheckAt, result.nextCheckAt)
    }

    func testHistoryClearedDuringGenerationRejectsOldCandidate() async throws {
        let f = try LifecycleFixture()
        defer { f.clean() }
        let initial = try await f.worker.step(settings: .init(mode: .fast))
        f.clock.set(initial.nextCheckAt)
        // Both snapshots have version zero; only the reset timestamp distinguishes them.
        f.generator.onNarrative = { _ = try f.repository.clearHistory(now: f.clock.now) }
        _ = try await f.worker.step(settings: .init(mode: .fast))
        XCTAssertEqual(try f.repository.events().count, 0)
        XCTAssertEqual(try f.repository.loadSnapshot().stateVersion, 0)
        f.generator.onNarrative = nil
        let next = try await f.makeWorker().step(settings: .init(mode: .fast))
        XCTAssertGreaterThan(next.nextCheckAt, f.clock.now)
        XCTAssertEqual(try f.repository.events().count, 0)
    }

    func testOfflineBeforeFirstPostcardFulfillsEveryDurableSlot() async throws {
        let f = try LifecycleFixture()
        defer { f.clean() }
        try await f.startThreePostcardTrip()
        try await f.reach(.exploring)
        let before = try f.plan()
        XCTAssertEqual(before.slots.count, 3)
        f.clock.advance(4 * 24 * 3600)
        let resumedAt = f.clock.now
        let restarted = f.makeWorker()
        for _ in 0..<30 {
            let calls = f.generator.narrativeCalls + f.generator.imageCalls
            let outcome = try await restarted.step(settings: .init(mode: .fast))
            XCTAssertLessThanOrEqual(f.generator.narrativeCalls + f.generator.imageCalls - calls, 1)
            let snapshot = try f.repository.loadSnapshot()
            if snapshot.phase == .resting { break }
            XCTAssertLessThanOrEqual(outcome.nextCheckAt.timeIntervalSince(f.clock.now), 15)
            f.clock.set(max(f.clock.now.addingTimeInterval(1), outcome.nextCheckAt))
        }
        let postcards = try f.repository.events().filter { $0.phase == .postcardReady }
        XCTAssertEqual(postcards.count, 3)
        XCTAssertEqual(Set(postcards.map(\.id)), Set(before.slots.map(\.id)))
        XCTAssertTrue(postcards.allSatisfy { $0.occurredAt >= resumedAt && $0.postcardStatus == .ready })
        XCTAssertEqual(try f.repository.loadSnapshot().phase, .resting)
        XCTAssertEqual(try f.plan().remainingImageCount, 0)
    }

    func testOfflineMidTripAndRestartRetainRemainingSlots() async throws {
        let f = try LifecycleFixture()
        defer { f.clean() }
        try await f.startThreePostcardTrip()
        try await f.reach(.postcardReady)
        f.clock.advance(15) // Persisted minimum model-action gap.
        let original = try f.plan()
        f.clock.advance(5 * 24 * 3600)
        var worker = f.makeWorker()
        for _ in 0..<30 {
            let outcome = try await worker.step(settings: .init(mode: .fast))
            XCTAssertEqual(try f.plan().slots.map(\.id), original.slots.map(\.id))
            if try f.repository.loadSnapshot().phase == .resting { break }
            f.clock.set(max(f.clock.now.addingTimeInterval(1), outcome.nextCheckAt))
            worker = f.makeWorker()
        }
        let postcards = try f.repository.events().filter { $0.phase == .postcardReady }
        XCTAssertEqual(postcards.count, 3)
        XCTAssertEqual(Set(postcards.map(\.id)).count, 3)
        XCTAssertTrue(postcards.allSatisfy { $0.postcardStatus == .ready })
    }

    func testDailyOfflineCatchUpUsesMinuteGapAndKeepsFutureDeparture() async throws {
        let f = try LifecycleFixture()
        defer { f.clean() }
        try await f.startThreePostcardTrip()
        try await f.reach(.exploring)
        _ = try await f.worker.step(settings: .init(mode: .daily))
        f.clock.advance(4 * 24 * 3600)
        for _ in 0..<30 {
            let outcome = try await f.makeWorker().step(settings: .init(mode: .daily))
            if try f.repository.loadSnapshot().phase == .resting {
                XCTAssertGreaterThanOrEqual(outcome.nextCheckAt.timeIntervalSince(f.clock.now), 12 * 3600)
                break
            }
            XCTAssertEqual(outcome.nextCheckAt.timeIntervalSince(f.clock.now), 60)
            f.clock.set(outcome.nextCheckAt)
        }
        XCTAssertEqual(try f.repository.events().filter { $0.phase == .postcardReady }.count, 3)
        XCTAssertEqual(try f.repository.loadSnapshot().phase, .resting)
    }

    func testPostcardTextFailureRetainsSlotAndRetryAcrossRestart() async throws {
        let f = try LifecycleFixture()
        defer { f.clean() }
        try await f.startThreePostcardTrip()
        try await f.reach(.exploring)
        f.clock.advance(4 * 24 * 3600)
        let plannedID = try XCTUnwrap(f.plan().nextEventID)
        f.generator.failNarrative = true
        let failed = try await f.worker.step(settings: .init(mode: .fast))
        XCTAssertTrue(failed.message.contains("3"))
        let calls = f.generator.narrativeCalls
        f.generator.failNarrative = false
        _ = try await f.makeWorker().step(settings: .init(mode: .fast))
        XCTAssertEqual(f.generator.narrativeCalls, calls)
        XCTAssertEqual(try f.plan().nextEventID, plannedID)
        f.clock.set(failed.nextCheckAt)
        _ = try await f.makeWorker().step(settings: .init(mode: .fast))
        XCTAssertEqual(try f.repository.events().last?.id, plannedID)
    }

    func testLegacyStateAndStalePublicationPlanRebuildFromJournal() async throws {
        let f = try LifecycleFixture()
        defer { f.clean() }
        try await f.startThreePostcardTrip()
        try await f.reach(.postcardReady)
        f.clock.advance(15) // Persisted minimum model-action gap.
        let postcard = try XCTUnwrap(f.repository.events().last)
        let original = try f.plan()
        try f.updateState { $0.removeValue(forKey: "postcardPlan") }
        _ = try await f.makeWorker().step(settings: .init(mode: .fast))
        let rebuilt = try f.plan()
        XCTAssertEqual(rebuilt.slots.map(\.id), original.slots.map(\.id))
        XCTAssertEqual(rebuilt.slots.compactMap(\.eventID), [postcard.id])
        XCTAssertEqual(rebuilt.slots.filter(\.imageReady).count, 1)
        // Simulate a crash after journal publication but before saving the binding.
        let stale = TripPostcardPlan(tripID: postcard.tripID)
        try f.updateState { $0["postcardPlan"] = try JSONSerialization.jsonObject(with: JSONEncoder.travelCat.encode(stale)) }
        let count = try f.repository.events().count
        for _ in 0..<3 { _ = try await f.makeWorker().step(settings: .init(mode: .fast)) }
        XCTAssertEqual(try f.repository.events().count, count)
        XCTAssertEqual(try f.plan(), rebuilt)
    }

    func testLegacyRandomEventIDsBindWithoutRewritingHistory() async throws {
        let f = try LifecycleFixture()
        defer { f.clean() }
        try await f.startThreePostcardTrip()
        try await f.reach(.postcardReady)
        f.clock.advance(15) // Persisted minimum model-action gap.
        let events = try f.repository.events()
        let postcard = try XCTUnwrap(events.last)
        // Use another trip's deterministic IDs to exercise legacy (non-slot) binding.
        var plan = TripPostcardPlan(tripID: postcard.tripID)
        let alternate = TripPostcardPlan(tripID: UUID(uuidString: "05000000-0000-4000-8000-000000000001")!)
        plan.slots = alternate.slots
        plan.reconcile(events: events)
        XCTAssertEqual(plan.slots.compactMap(\.eventID), [postcard.id])
        XCTAssertEqual(plan.unpublishedCount, 2)
        XCTAssertEqual(try f.repository.events(), events)
    }

    func testLegacyRestingTripBackfillsWithoutChangingOldJournalOrSnapshot() async throws {
        let f = try LifecycleFixture()
        defer { f.clean() }
        try await f.startThreePostcardTrip()
        try await f.reach(.postcardReady)
        f.clock.advance(15)
        _ = try await f.worker.step(settings: .init(mode: .fast))
        try await f.publishPhase(.returning)
        try await f.publishPhase(.resting)
        let original = try f.repository.loadContents()
        let journalURL = f.root.appendingPathComponent("journal/events.jsonl")
        let bytes = try Data(contentsOf: journalURL)
        f.clock.advance(4 * 24 * 3600)
        let resumedAt = f.clock.now
        let backlog = try PostcardBacklogStore(root: f.root, clock: f.clock)
        for _ in 0..<12 {
            let outcome = try await f.makeWorker().step(settings: .init(mode: .fast))
            let extras = try backlog.supplementalEvents()
            if extras.count == 2 && extras.allSatisfy({ $0.postcardStatus == .ready }) { break }
            f.clock.set(outcome.nextCheckAt)
        }
        let extras = try backlog.supplementalEvents()
        XCTAssertEqual(extras.count, 2)
        XCTAssertTrue(extras.allSatisfy { $0.tripID == original.snapshot.tripID && $0.occurredAt >= resumedAt && $0.postcardStatus == .ready })
        XCTAssertEqual(try Data(contentsOf: journalURL), bytes)
        XCTAssertEqual(try f.repository.loadSnapshot(), original.snapshot)
    }

    func testOldTripDebtSurvivesNewTripAndModeChange() async throws {
        let f = try LifecycleFixture()
        defer { f.clean() }
        try await f.startThreePostcardTrip()
        try await f.publishPhase(.transit)
        try await f.publishPhase(.returning)
        try await f.publishPhase(.resting)
        let oldTrip = try XCTUnwrap(f.repository.loadSnapshot().tripID)
        try await f.publishPhase(.preparing)
        let current = try f.repository.loadSnapshot()
        f.clock.advance(4 * 24 * 3600)
        _ = try await f.worker.step(settings: .init(mode: .daily))
        let backlog = try PostcardBacklogStore(root: f.root, clock: f.clock)
        XCTAssertEqual(try backlog.supplementalEvents().first?.tripID, oldTrip)
        XCTAssertEqual(try f.repository.loadSnapshot(), current)
        let plans = try backlog.reconcile(events: f.repository.events())
        XCTAssertEqual(plans.count, 2)
        XCTAssertEqual(plans.first?.slots.count, 3)
        XCTAssertNotNil(plans.last?.slots.first)
    }

    func testRepeatedWakeCannotBypassPersistedModelGap() async throws {
        let f = try LifecycleFixture()
        defer { f.clean() }
        try await f.startThreePostcardTrip()
        try await f.reach(.postcardReady)
        let calls = f.generator.imageCalls + f.generator.narrativeCalls
        for _ in 0..<5 { _ = try await f.makeWorker().step(settings: .init(mode: .fast)) }
        XCTAssertEqual(f.generator.imageCalls + f.generator.narrativeCalls, calls)
        f.clock.advance(14)
        _ = try await f.makeWorker().step(settings: .init(mode: .fast))
        XCTAssertEqual(f.generator.imageCalls + f.generator.narrativeCalls, calls)
        f.clock.advance(1)
        _ = try await f.makeWorker().step(settings: .init(mode: .fast))
        XCTAssertEqual(f.generator.imageCalls + f.generator.narrativeCalls, calls + 1)
    }

    func testCorruptAutomaticCachePreservesBytesAndRebuildsFromJournal() async throws {
        let f = try LifecycleFixture()
        defer { f.clean() }
        try await f.startThreePostcardTrip()
        try await f.reach(.exploring)
        let ids = try f.plan().slots.map(\.id)
        let corrupt = Data("{broken original scheduling state".utf8)
        try corrupt.write(to: f.root.appendingPathComponent("state/automatic-travel.json"))
        f.clock.advance(4 * 24 * 3600)
        let calls = f.generator.narrativeCalls
        let outcome = try await f.makeWorker().step(settings: .init(mode: .fast))
        XCTAssertEqual(f.generator.narrativeCalls, calls)
        XCTAssertEqual(try f.plan().slots.map(\.id), ids)
        let backups = try FileManager.default.contentsOfDirectory(at: f.root.appendingPathComponent("state"), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("automatic-travel.corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), corrupt)
        f.clock.set(outcome.nextCheckAt)
        _ = try await f.makeWorker().step(settings: .init(mode: .fast))
        XCTAssertEqual(try f.repository.events().last?.id, ids.first)
    }

    func testQueuedManualRetryResumesOnStartupWhileAutomaticTravelIsPaused() async throws {
        let f = try LifecycleFixture()
        defer { f.clean() }
        try await f.startThreePostcardTrip()
        try await f.reach(.postcardReady)
        let event = try XCTUnwrap(f.repository.events().last)
        for _ in 0..<3 {
            f.clock.advance(300)
            let work = try XCTUnwrap(f.repository.pendingImages(mode: .fast).first)
            _ = try f.repository.markImage(.init(eventId: event.id, status: .failed, attemptedAt: f.clock.now,
                relativePath: nil, reason: "test generation failure", attemptToken: work.attemptToken,
                attemptCount: work.imageAttemptCount, publishedNarrativeHash: work.publishedNarrativeHash), mode: .fast)
        }
        try f.repository.requestManualImageRetry(eventID: event.id, mode: .fast)
        let snapshot = try f.repository.loadSnapshot()
        let narrativeCalls = f.generator.narrativeCalls
        f.generator.imageWidth = nil
        let model = AppModel(snapshot: snapshot, events: try f.repository.events(), dataRoot: f.root, clock: { f.clock.now })
        var paused = TravelSettings(mode: .fast)
        paused.automaticTravelEnabled = false
        let controller = PostcardRecoveryController(repository: f.repository, model: model, worker: f.makeWorker(),
            settings: { paused }, isReady: { true }, now: { f.clock.now },
            sleep: { seconds in f.clock.advance(seconds); await Task.yield() })
        defer { controller.stop() }
        controller.start()
        await waitUntil { f.generator.imageCalls == 1 }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(f.generator.narrativeCalls, narrativeCalls)
        XCTAssertEqual(try f.repository.loadSnapshot(), snapshot)
        XCTAssertEqual(try f.repository.events().last?.postcardStatus, .imageUnavailable)
        XCTAssertEqual(try f.repository.imageRetry(for: event.id)?.manualRequests.count, 1)
        XCTAssertEqual(try f.repository.imageRetry(for: event.id)?.manualAttemptResults.count, 1)
        f.clock.advance(1000)
        _ = try await f.worker.step(settings: paused)
        XCTAssertEqual(f.generator.imageCalls, 1)
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("operation never reached suspension point")
    }
}

@MainActor
private final class LifecycleFixture {
    let root: URL
    let clock = LifecycleClock(Date(timeIntervalSince1970: 1_800_000_000))
    let repository: TravelRepository
    let generator = LifecycleGenerator()
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    lazy var worker = makeWorker()
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        repository = try TravelRepository(root: root, clock: clock)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func makeWorker() -> AutomaticTravelWorker {
        let clock = self.clock
        let calendar = self.calendar
        return AutomaticTravelWorker(repository: repository, generator: generator, clock: { clock.now }, calendar: { calendar })
    }
    func updateState(_ change: (inout [String: Any]) throws -> Void) throws {
        let url = root.appendingPathComponent("state/automatic-travel.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        try change(&object)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url, options: .atomic)
    }
    func plan() throws -> TripPostcardPlan {
        let url = root.appendingPathComponent("state/automatic-travel.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try JSONDecoder.travelCat.decode(TripPostcardPlan.self,
            from: JSONSerialization.data(withJSONObject: try XCTUnwrap(object["postcardPlan"])))
    }
    func startThreePostcardTrip() async throws {
        let initial = try await worker.step(settings: .init(mode: .fast))
        let plan = TripPostcardPlan(tripID: UUID(uuidString: "02000000-0000-4000-8000-000000000001")!)
        try updateState { $0["postcardPlan"] = try JSONSerialization.jsonObject(with: JSONEncoder.travelCat.encode(plan)) }
        clock.set(initial.nextCheckAt)
        _ = try await worker.step(settings: .init(mode: .fast))
        XCTAssertEqual(try repository.loadSnapshot().phase, .preparing)
    }
    func publishPhase(_ phase: TravelPhase) async throws {
        clock.advance(1)
        let contents = try repository.loadContents()
        let request = TravelEventRequest(claim: DueClaim(due: true, snapshot: contents.snapshot, previousEvent: contents.events.last),
            recentEvents: contents.events, phase: phase)
        let narrative = try await generator.narrative(for: request)
        let event = AgentEventEnvelope(eventId: UUID(), tripId: phase == .preparing ? UUID() : contents.snapshot.tripID!,
            previousEventId: contents.snapshot.lastEventID, occurredAt: clock.now, phase: phase,
            location: narrative.location, transport: narrative.transport, summary: narrative.summary, mood: narrative.mood,
            continuityReferences: narrative.continuityReferences, openHook: narrative.openHook, consumedItemId: nil,
            postcard: PostcardRequest(required: false, scenePrompt: nil))
        let projected = try event.validatedProjection(previous: contents.snapshot, existingEventIDs: Set(contents.events.map(\.id)),
            mode: .fast, calendar: calendar, now: clock.now)
        try repository.publish(event: projected.event, next: projected.next, expectedSnapshot: contents.snapshot)
    }
    func reach(_ phase: TravelPhase) async throws {
        for _ in 0..<40 {
            let outcome = try await worker.step(settings: .init(mode: .fast))
            let snapshot = try repository.loadSnapshot()
            if snapshot.stateVersion > 0 && snapshot.phase == phase { return }
            clock.set(max(clock.now.addingTimeInterval(1), outcome.nextCheckAt))
        }
        XCTFail("did not reach \(phase), calls=\(generator.narrativeCalls), state=\(String(data: try Data(contentsOf: root.appendingPathComponent("state/automatic-travel.json")), encoding: .utf8) ?? "")")
    }
}

private final class LifecycleClock: TravelClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ date: Date) { lock.lock(); defer { lock.unlock() }; value = date }
    func advance(_ seconds: TimeInterval) { set(now.addingTimeInterval(seconds)) }
}

@MainActor
private final class LifecycleGenerator: TravelContentGenerating {
    var narrativeCalls = 0
    var imageCalls = 0
    var imageWidth: Int? = 1152
    var imageHeight = 768
    var onNarrative: (() throws -> Void)?
    var failNarrative = false
    var holdNarrative = false
    var pending: CheckedContinuation<Void, Never>?
    func release() { holdNarrative = false; pending?.resume(); pending = nil }
    func narrative(for request: TravelEventRequest) async throws -> TravelNarrative {
        narrativeCalls += 1
        if holdNarrative { await withCheckedContinuation { pending = $0 } }
        if failNarrative { throw CocoaError(.fileReadUnknown) }
        try onNarrative?()
        return TravelNarrative(
            summary: "黑猫沿着蜿蜒的小路继续旅行，记住沿途的风景，也惦记着温暖的小屋。",
            mood: Mood(level: request.claim.snapshot.mood.level, label: "平静", quote: "今天也有新的风景。"),
            location: [.exploring, .postcardReady].contains(request.phase) ? Location(country: "中国", city: "杭州", place: "沿湖第\(narrativeCalls)站") : nil,
            transport: nil,
            continuityReferences: [request.claim.previousEvent?.summary ?? "从温暖的小屋出发"],
            openHook: "继续看看前方的小路", consumedItemID: nil,
            scenePrompt: request.phase == .postcardReady ? "黑猫在湖边留下旅行合影" : nil)
    }
    func image(for work: PendingImageWork, in workspace: URL) async throws -> URL {
        imageCalls += 1
        guard let width = imageWidth else { throw CocoaError(.fileNoSuchFile) }
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: imageHeight, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let url = workspace.appendingPathComponent("postcard.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
