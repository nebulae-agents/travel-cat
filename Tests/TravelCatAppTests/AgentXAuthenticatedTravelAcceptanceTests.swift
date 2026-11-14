import Foundation
import XCTest
import TravelCore
import TravelStorage
import TravelUI
@testable import TravelCatApp

/// Explicit, authenticated integration acceptance. All travel state is newly created.
@MainActor
final class AgentXAuthenticatedTravelAcceptanceTests: XCTestCase {
    private enum AcceptanceFailure: Error { case verification(String) }
    private func require(_ value: Bool, _ message: String) throws {
        guard value else { throw AcceptanceFailure.verification(message) }
    }
    func testRealNarrativePostcardPersistenceAndCancellation() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["AGENTX_AUTHENTICATED_TRAVEL_TEST"] == "1" else {
            throw XCTSkip("Requires a separately logged-in temporary acceptance profile")
        }
        let root = URL(fileURLWithPath: try XCTUnwrap(env["AGENTX_AUTHENTICATED_ACCEPTANCE_ROOT"]))
        let home = URL(fileURLWithPath: try XCTUnwrap(env["CODEX_HOME"]))
        let executable = URL(fileURLWithPath: try XCTUnwrap(env["AGENTX_REAL_CODEX_EXECUTABLE"]))
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedHome = home.resolvingSymlinksInPath().standardizedFileURL
        let temporary = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().standardizedFileURL
        guard resolvedRoot.path.hasPrefix(temporary.path + "/agentx-authenticated-"),
              resolvedHome.path.hasPrefix(resolvedRoot.path + "/profiles/"),
              FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            XCTFail("Requires an isolated authenticated acceptance root"); return
        }
        let dataRoot = root.appendingPathComponent("travel-data-\(UUID().uuidString)")
        let clock = AuthenticatedAcceptanceClock()
        let repository = try TravelRepository(root: dataRoot, clock: clock)
        let executor = CodexTravelExecutor(executableURL: executable, timeout: 480)
        let generator = CountedRealTravelGenerator(executor: executor)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let worker = AutomaticTravelWorker(repository: repository, generator: generator,
            clock: { clock.now }, calendar: { calendar })
        print("authenticated-travel-evidence-root: \(dataRoot.path)")
        do {
            var pending: TripEvent?
            var completed = false
            for _ in 0..<40 {
                let outcome = try await worker.step(settings: .init(mode: .fast), progress: { stage in
                    print("authenticated-travel-stage: \(stage.rawValue)")
                })
                if let failure = outcome.failure {
                    XCTFail("Real travel failed: \(failure.category.rawValue), stage=\(failure.stage?.rawValue ?? "unknown")")
                    break
                }
                let contents = try repository.loadContents()
                if pending == nil { pending = contents.events.first { $0.postcardStatus == .pendingImage } }
                if let pending, let ready = contents.events.first(where: { $0.id == pending.id && $0.postcardStatus == .ready }) {
                    var expected = pending
                    expected.postcardStatus = .ready
                    expected.postcardRelativePath = ready.postcardRelativePath
                    try require(ready == expected, "Ready event changed narrative")
                    let reopened = try TravelRepository(root: dataRoot, clock: clock).loadContents()
                    try require(reopened.events.first { $0.id == ready.id } == ready, "Reopened event differs")
                    let bytes = try PostcardImageLoader.loadData(relativePath: try XCTUnwrap(ready.postcardRelativePath), rootURL: dataRoot)
                    let thumbnail = try PostcardImageDecoder.decodeThumbnail(data: bytes)
                    try require(thumbnail.width == 1024, "Invalid postcard width")
                    try require(thumbnail.height > 0, "Invalid postcard height")
                    completed = true
                    break
                }
                clock.set(max(clock.now.addingTimeInterval(1), outcome.nextCheckAt))
            }
            try require(completed, "A real pending narrative must become a stored, readable postcard")
            let stopped = await executor.shutdownAndWait(timeout: .seconds(10))
            try require(stopped, "Completed executor did not stop")
            try require(executor.positivelyStopped, "Executor exit unconfirmed")
            try require(executor.resumeWithoutRunning(), "Resume refused")
            try require(!executor.hasOwnedOperations, "Resume launched work")
            let workspace = root.appendingPathComponent("cancel-workspace-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
            let task = Task { try await executor.run(prompt: "For a cancellation acceptance test, write the integers 1 through 20000, one per line. Do not use tools or files.", workspace: workspace) }
            try await Task.sleep(for: .seconds(2))
            try require(executor.hasOwnedOperations, "Cancellation had no active operation")
            task.cancel()
            do { _ = try await task.value; throw AcceptanceFailure.verification("Cancelled invocation returned success") }
            catch { try require(error is CancellationError, "Cancellation returned unexpected result") }
            let cancelledStopped = await executor.shutdownAndWait(timeout: .seconds(10))
            try require(cancelledStopped, "Cancelled executor did not stop")
            try require(executor.positivelyStopped, "Executor exit unconfirmed")
            let report: [String: Any] = ["pendingToReady": completed, "readbackVerified": true,
                "narrativeCalls": generator.narrativeCalls, "imageCalls": generator.imageCalls,
                "cancelledInvocationReaped": cancelledStopped]
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                .write(to: dataRoot.appendingPathComponent("acceptance-report.json"), options: .atomic)
        } catch {
            _ = await executor.shutdownAndWait(timeout: .seconds(10))
            throw error
        }
    }
}

@MainActor
private final class CountedRealTravelGenerator: TravelContentGenerating {
    let generator: CodexTravelContentGenerator
    var narrativeCalls = 0
    var imageCalls = 0
    init(executor: CodexTravelExecutor) { generator = .init(executor: executor) }
    func narrative(for request: TravelEventRequest) async throws -> TravelNarrative {
        guard narrativeCalls < 4 else { throw CodexTravelExecutor.Failure.generationFailed }
        narrativeCalls += 1
        return try await generator.narrative(for: request)
    }
    func image(for work: PendingImageWork, in workspace: URL) async throws -> URL {
        guard imageCalls < 1 else { throw CodexTravelExecutor.Failure.generationFailed }
        imageCalls += 1
        return try await generator.image(for: work, in: workspace)
    }
}

private final class AuthenticatedAcceptanceClock: TravelClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ date: Date) { lock.lock(); defer { lock.unlock() }; value = date }
}
