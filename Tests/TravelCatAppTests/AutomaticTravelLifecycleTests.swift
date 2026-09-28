import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import TravelCore
@testable import TravelStorage
@testable import TravelCatApp

@MainActor
final class AutomaticTravelLifecycleTests: XCTestCase {
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
        f.generator.imageWidth = nil
        _ = try await f.worker.step(settings: .init(mode: .fast))
        XCTAssertEqual(f.generator.imageCalls, 1)
        f.clock.advance(121)
        f.generator.failNarrative = true
        _ = try await f.worker.step(settings: .init(mode: .fast))
        // The narrative's 15-second backoff must not block an already-due image retry.
        f.clock.advance(1)
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
