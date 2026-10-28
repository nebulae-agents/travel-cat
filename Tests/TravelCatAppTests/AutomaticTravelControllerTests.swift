import Foundation
import XCTest
@testable import TravelCatApp

@MainActor
final class AutomaticTravelControllerTests: XCTestCase {
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
        XCTAssertEqual(pending.count, 2)
        guard pending.count == 2 else { return }
        pending[0].resume(throwing: CancellationError()); await settle()
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
}
