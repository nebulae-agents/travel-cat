import Foundation
import XCTest
@testable import TravelCatApp

@MainActor
final class AutomaticTravelControllerTests: XCTestCase {
    func testSuspensionWaitsForPreviouslyPausedOperationAndResumeDoesNotRun() async {
        var pending: CheckedContinuation<AutomaticTravelOutcome, Never>?
        var calls = 0
        var suspended = false
        let controller = AutomaticTravelController(isEnabled: { true }, run: {
            calls += 1
            if calls == 1 { return await withCheckedContinuation { pending = $0 } }
            return .init(nextCheckAt: Date().addingTimeInterval(60), message: "explicit")
        })
        controller.start(); await settle()
        controller.pause()
        controller.start() // A subsequent application suspension must revoke this queued intent.
        let drain = Task { await controller.suspendAndWait(); suspended = true }
        await settle()
        XCTAssertFalse(suspended)
        XCTAssertFalse(controller.resumeWithoutRunning())
        controller.start(); controller.settingsDidChange(); controller.refresh()
        await settle()
        XCTAssertEqual(calls, 1)
        pending?.resume(returning: .init(nextCheckAt: Date(), message: "stale"))
        await drain.value
        XCTAssertTrue(suspended)
        XCTAssertFalse(controller.hasOwnedOperations)
        XCTAssertTrue(controller.resumeWithoutRunning())
        controller.refresh(); await settle()
        XCTAssertEqual(calls, 1, "Permission alone does not arm timer or queue replay")
        XCTAssertNil(controller.nextCheckAt)
        controller.start(); await settle()
        XCTAssertEqual(calls, 2)
        await controller.suspendAndWait()
    }

    func testExplicitStartWhilePausedRunExitsIsHonoredWithoutOverlap() async {
        var pending: CheckedContinuation<AutomaticTravelOutcome, Never>?
        var calls = 0
        let controller = AutomaticTravelController(isEnabled: { true }, run: {
            calls += 1
            if calls == 1 { return await withCheckedContinuation { pending = $0 } }
            return .init(nextCheckAt: Date().addingTimeInterval(60), message: "restarted")
        })
        controller.start(); await settle()
        controller.pause()
        controller.start(); controller.start(); await settle()
        XCTAssertEqual(calls, 1)
        pending?.resume(returning: .init(nextCheckAt: Date(), message: "stale"))
        await settle()
        XCTAssertEqual(calls, 2, "Explicit start must survive an older operation draining")
        XCTAssertEqual(controller.message, "restarted")
        await controller.suspendAndWait()
    }

    func testResumeOnFreshControllerDoesNotArmAutomaticGeneration() async {
        var calls = 0
        let controller = AutomaticTravelController(isEnabled: { true }, run: {
            calls += 1
            return .init(nextCheckAt: Date(), message: "unexpected")
        })
        XCTAssertTrue(controller.resumeWithoutRunning())
        controller.refresh(); await settle()
        XCTAssertEqual(calls, 0)
        XCTAssertNil(controller.nextCheckAt)
        controller.stop()
    }

    func testDisablingTravelSettingCancelsWithoutWaitingForRunCompletion() async {
        var enabled = true
        var pending: CheckedContinuation<AutomaticTravelOutcome, Never>?
        let controller = AutomaticTravelController(isEnabled: { enabled }, run: {
            await withCheckedContinuation { pending = $0 }
        })
        controller.start(); await settle()
        enabled = false
        controller.settingsDidChange()
        XCTAssertEqual(controller.message, "自动旅行已暂停")
        XCTAssertNil(controller.progress)
        XCTAssertTrue(controller.hasOwnedOperations)
        pending?.resume(returning: .init(nextCheckAt: Date(), message: "stale"))
        await controller.suspendAndWait()
    }

    func testDisabledBeforeTaskStartsNeverInvokesOperation() async {
        var enabled = true
        var calls = 0
        let controller = AutomaticTravelController(isEnabled: { enabled }, run: {
            calls += 1
            return .init(nextCheckAt: Date(), message: "unexpected")
        })
        controller.refresh()
        enabled = false
        await settle()
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(controller.hasOwnedOperations)
        controller.stop()
    }

    func testStopRetainsCancelledOperationUntilItReallyExits() async {
        var completion: CheckedContinuation<AutomaticTravelOutcome, Never>?
        let controller = AutomaticTravelController(isEnabled: { true }, run: {
            await withCheckedContinuation { completion = $0 }
        })
        controller.refresh(); await settle()
        controller.pause()
        controller.stop()
        XCTAssertTrue(controller.isRunning, "Cancellation does not prove the operation exited")
        completion?.resume(returning: .init(nextCheckAt: Date(), message: "stale"))
        await settle()
        XCTAssertFalse(controller.isRunning)
        XCTAssertNil(controller.nextCheckAt)
    }

    func testIndependentCancellationReleasesRunAndSchedulesBoundedRetry() async throws {
        var calls = 0
        let controller = AutomaticTravelController(isEnabled: { true }, run: {
            calls += 1
            throw CancellationError()
        })
        defer { controller.stop() }
        let started = Date()
        controller.refresh()
        await settle()
        XCTAssertFalse(controller.isRunning)
        let next = try XCTUnwrap(controller.nextCheckAt)
        XCTAssertGreaterThan(next.timeIntervalSince(started), 0)
        XCTAssertLessThanOrEqual(next.timeIntervalSinceNow, 60)
        XCTAssertNil(controller.failure)
        XCTAssertEqual(calls, 1, "Cancellation retries must not form an immediate loop")
        controller.refresh()
        await settle()
        XCTAssertEqual(calls, 2, "Cancellation must release the single-run slot")
    }

    func testUnexpectedErrorOffersSanitizedCoalescedManualRetry() async throws {
        var calls = 0
        var retries = 0
        var completion: CheckedContinuation<AutomaticTravelOutcome, Never>?
        let controller = AutomaticTravelController(isEnabled: { true }, run: {
            calls += 1
            if calls == 1 { throw NSError(domain: "secret-provider-body /private/token", code: 9) }
            return await withCheckedContinuation { completion = $0 }
        }, retry: {
            retries += 1
            return .init(nextCheckAt: Date().addingTimeInterval(60), message: "no persisted failure")
        })
        defer { controller.stop() }
        controller.refresh()
        await settle()
        XCTAssertFalse(controller.isRunning)
        let failure = try XCTUnwrap(controller.failure)
        XCTAssertEqual(failure.category, .generation)
        let encoded = String(decoding: try JSONEncoder().encode(failure), as: UTF8.self)
        XCTAssertFalse(encoded.contains("secret-provider"))
        XCTAssertFalse(controller.message.contains("secret-provider"))
        XCTAssertTrue(controller.canRetryFailure)
        controller.retryFailure(); controller.retryFailure(); controller.refresh()
        await settle()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(retries, 0, "Controller errors may precede persisted worker failure state")
        completion?.resume(returning: .init(nextCheckAt: Date().addingTimeInterval(120), message: "recovered"))
        await settle()
        XCTAssertEqual(controller.message, "recovered")
        XCTAssertNil(controller.failure)
    }

    func testOldCancellationCannotClearNewRunAfterSettingsChange() async throws {
        var pending: [CheckedContinuation<AutomaticTravelOutcome, Error>] = []
        let controller = AutomaticTravelController(isEnabled: { true }, run: {
            try await withCheckedThrowingContinuation { pending.append($0) }
        })
        defer { controller.stop() }
        controller.refresh(); await settle()
        controller.settingsDidChange(); await settle()
        XCTAssertEqual(pending.count, 1, "Settings cannot overlap an operation still exiting")
        pending[0].resume(throwing: CancellationError()); await settle()
        XCTAssertEqual(pending.count, 2)
        guard pending.count == 2 else { return }
        XCTAssertTrue(controller.isRunning)
        XCTAssertNil(controller.nextCheckAt)
        controller.refresh(); await settle()
        XCTAssertEqual(pending.count, 2)
        pending[1].resume(returning: .init(nextCheckAt: Date().addingTimeInterval(120), message: "new"))
        await settle()
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(controller.message, "new")
    }

    func testDisabledCompletionStaysPausedWithoutSettingsNotification() async {
        var enabled = true
        var pending: CheckedContinuation<AutomaticTravelOutcome, Error>?
        let controller = AutomaticTravelController(isEnabled: { enabled }, run: {
            try await withCheckedThrowingContinuation { pending = $0 }
        })
        defer { controller.stop() }
        controller.refresh(); await settle()
        enabled = false
        pending?.resume(throwing: CancellationError()); await settle()
        XCTAssertFalse(controller.isRunning)
        XCTAssertNil(controller.nextCheckAt)
        XCTAssertEqual(controller.message, "自动旅行已暂停")
    }

    func testPauseCancellationDoesNotScheduleRetry() async {
        var pending: CheckedContinuation<AutomaticTravelOutcome, Error>?
        let controller = AutomaticTravelController(isEnabled: { true }, run: {
            try await withCheckedThrowingContinuation { pending = $0 }
        })
        defer { controller.stop() }
        controller.refresh(); await settle()
        controller.pause()
        pending?.resume(throwing: CancellationError()); await settle()
        XCTAssertFalse(controller.isRunning)
        XCTAssertNil(controller.nextCheckAt)
        XCTAssertEqual(controller.message, "自动旅行已暂停")
    }

    func testTimerWakesOnceAndPauseInvalidatesNextWake() async throws {
        var calls = 0
        let controller = AutomaticTravelController(isEnabled: { true }, run: {
            calls += 1
            return .init(nextCheckAt: Date(), message: "scheduled")
        })
        defer { controller.stop() }
        controller.refresh(); await settle()
        XCTAssertEqual(calls, 1)
        let deadline = Date().addingTimeInterval(3)
        while calls < 2 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(calls, 2)
        controller.pause()
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(calls, 2)
        XCTAssertNil(controller.nextCheckAt)
    }

    private func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }

    func testProgressIsScopedToExecutionAndPreservesSuccessOnFailure() async throws {
        var callbacks: [AutomaticTravelProgressHandler] = []
        var pending: [CheckedContinuation<AutomaticTravelOutcome, Error>] = []
        let success = Date(timeIntervalSince1970: 1_800_000_000)
        let controller = AutomaticTravelController(isEnabled: { true }, runWithProgress: { report in
            callbacks.append(report)
            return try await withCheckedThrowingContinuation { pending.append($0) }
        }, lastSuccessDate: success)
        defer { controller.stop() }
        controller.refresh(); await settle()
        callbacks[0](.narrativeGeneration)
        XCTAssertEqual(controller.progress, .narrativeGeneration)
        controller.pause()
        callbacks[0](.publication)
        XCTAssertNil(controller.progress)
        controller.refresh(); await settle()
        XCTAssertEqual(pending.count, 1, "Paused work still owns the execution slot")
        pending[0].resume(returning: .init(nextCheckAt: Date(), message: "stale"))
        await settle()
        controller.refresh(); await settle()
        callbacks[1](.imageHandling)
        callbacks[0](.validation)
        XCTAssertEqual(controller.progress, .imageHandling)
        XCTAssertTrue(controller.isRunning)
        pending[1].resume(throwing: CocoaError(.fileReadUnknown)); await settle()
        XCTAssertNil(controller.progress)
        XCTAssertEqual(controller.lastSuccessDate, success)
        callbacks[1](.publication)
        XCTAssertNil(controller.progress, "Completed executions cannot report further progress")
    }
}
