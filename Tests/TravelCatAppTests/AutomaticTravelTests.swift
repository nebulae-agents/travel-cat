import Foundation
import XCTest
import TravelCore
import TravelStorage
@testable import TravelCatApp

@MainActor
final class AutomaticTravelTests: XCTestCase {
    func testInitialDepartureIsPersistedAcrossWorkerRestartWithoutGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        let repository = try TravelRepository(root: root, clock: FixedClock(now: now))
        let generator = StubTravelGenerator()
        let first = AutomaticTravelWorker(repository: repository, generator: generator, clock: { now })
        let a = try await first.step(settings: TravelSettings())
        let second = AutomaticTravelWorker(repository: repository, generator: generator, clock: { now.addingTimeInterval(60) })
        let b = try await second.step(settings: TravelSettings())
        XCTAssertEqual(a.nextCheckAt, b.nextCheckAt)
        XCTAssertGreaterThan(a.nextCheckAt, now)
        XCTAssertEqual(generator.requests.count, 0)
        XCTAssertEqual(try repository.events().count, 0)
    }

    func testFastTravelCompletesAllPhasesAndPreservesCausality() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var now = Date(timeIntervalSince1970: 1_787_000_000)
        let clock = MutableTravelClock(now)
        let repository = try TravelRepository(root: root, clock: clock)
        let generator = StubTravelGenerator()
        let worker = AutomaticTravelWorker(repository: repository, generator: generator, clock: { now })
        // Empty repository has a trusted initial timestamp; start fast scheduling from that time.
        now = try repository.loadSnapshot().lastUpdatedAt
        for _ in 0..<40 {
            now = now.addingTimeInterval(121)
            clock.set(now)
            _ = try await worker.step(settings: TravelSettings(mode: .fast))
            let current = try repository.loadSnapshot()
            if current.stateVersion > 0 && current.phase == .resting { break }
        }
        let contents = try repository.loadContents()
        XCTAssertEqual(contents.snapshot.phase, .resting)
        XCTAssertTrue(Set(contents.events.map(\.phase)).isSuperset(of: Set(TravelPhase.allCases)))
        XCTAssertEqual(contents.events.first?.phase, .preparing)
        for pair in zip(contents.events, contents.events.dropFirst()) {
            XCTAssertEqual(pair.1.previousEventID, pair.0.id)
            XCTAssertGreaterThan(pair.1.occurredAt, pair.0.occurredAt)
        }
        XCTAssertEqual(Set(contents.events.map(\.id)).count, contents.events.count)
    }

    func testRepeatedWakeCallbacksDoNotOverlapAndPauseCancels() async throws {
        var starts = 0
        var cancelled = false
        let controller = AutomaticTravelController(isEnabled: { true }, run: {
            starts += 1
            do { try await Task.sleep(for: .seconds(30)) }
            catch { cancelled = true; throw error }
            return AutomaticTravelOutcome(nextCheckAt: Date().addingTimeInterval(60), message: "等待出发")
        })
        controller.refresh()
        controller.refresh()
        controller.refresh()
        await Task.yield()
        XCTAssertEqual(starts, 1)
        controller.stop()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(cancelled)
        XCTAssertFalse(controller.isRunning)
    }
}

@MainActor
private final class StubTravelGenerator: TravelContentGenerating {
    var requests: [TravelEventRequest] = []
    func narrative(for request: TravelEventRequest) async throws -> TravelNarrative {
        requests.append(request)
        return TravelNarrative(
            summary: "黑猫接着上一次的旅途继续慢慢前行，记下路边的小小风景，也惦记着温暖的家。",
            mood: Mood(level: request.claim.snapshot.mood.level, label: "平静", quote: "今天也有新的风景。"),
            location: [.exploring, .postcardReady].contains(request.phase) ? Location(country: "中国", city: "杭州", place: "沿湖小路第\(requests.count)站") : nil,
            transport: request.phase == .transit ? "步行" : nil,
            continuityReferences: [request.claim.previousEvent?.summary ?? "从温暖的小屋出发"],
            openHook: "沿着小路慢慢走。", consumedItemID: nil,
            scenePrompt: request.phase == .postcardReady ? "黑猫在湖边拍下照片" : nil
        )
    }
    func image(for work: PendingImageWork, in workspace: URL) async throws -> URL {
        throw CocoaError(.fileNoSuchFile)
    }
}

private final class MutableTravelClock: TravelClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ date: Date) { lock.lock(); defer { lock.unlock() }; value = date }
}
