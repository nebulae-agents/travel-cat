import Foundation
import XCTest
@testable import TravelCatApp

/// Opt-in real CLI validation without copying the user's login or invoking a paid model.
@MainActor
final class AgentXRealTravelLifecycleTests: XCTestCase {
    func testIsolatedRealTravelCLIFailureIsReapedAndFenced() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["AGENTX_REAL_TRAVEL_TEST"] == "1" else { throw XCTSkip("Requires explicit isolated real CLI acceptance") }
        let executable = try XCTUnwrap(env["AGENTX_REAL_CODEX_EXECUTABLE"])
        let home = URL(fileURLWithPath: try XCTUnwrap(env["CODEX_HOME"]))
        let manager = FileManager.default
        let canonical = home.resolvingSymlinksInPath().standardizedFileURL
        let temporary = manager.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let sharedTemporary = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().standardizedFileURL
        let allowedRoot = canonical.path.hasPrefix(temporary.path + "/") || canonical.path.hasPrefix(sharedTemporary.path + "/")
        // Foundation canonicalizes the system /private aliases differently from POSIX realpath.
        // Accept only those exact system aliases; a symlink inside the test path still differs.
        let inputPath = home.standardizedFileURL.path
        let systemAliasPath = inputPath.hasPrefix("/private/tmp/") || inputPath.hasPrefix("/private/var/")
            ? String(inputPath.dropFirst("/private".count)) : inputPath
        let values = try home.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let checks: [(String, Bool)] = [
            ("canonical", inputPath == canonical.path || systemAliasPath == canonical.path), ("temporaryRoot", allowedRoot),
            ("prefix", home.lastPathComponent.hasPrefix("agentx-real-travel-")),
            ("directory", values.isDirectory == true), ("notSymlink", values.isSymbolicLink != true),
            ("empty", try manager.contentsOfDirectory(atPath: home.path).isEmpty),
            ("executable", manager.isExecutableFile(atPath: executable))
        ]
        guard checks.allSatisfy({ $0.1 }) else {
            XCTFail("Isolated CLI preflight failed: " + checks.filter { !$0.1 }.map(\.0).joined(separator: ", "))
            print("real-travel-temporary-paths: input=\(home.path) canonical=\(canonical.path) temporary=\(temporary.path)")
            return
        }
        let workspace = home.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let executor = CodexTravelExecutor(executableURL: URL(fileURLWithPath: executable), timeout: 15)
        do {
            _ = try await executor.run(prompt: "Reply only with OK.", workspace: workspace)
            XCTFail("An isolated unauthenticated profile must not complete generation")
        } catch {
            let failure = try XCTUnwrap(error as? CodexTravelExecutor.Failure)
            XCTAssertTrue([CodexTravelExecutor.Failure.notLoggedIn, .timedOut, .networkUnavailable].contains(failure), "Unexpected real CLI compatibility or execution failure")
            print("real-travel-cli-classification: \(failure.rawValue)")
        }
        let stopped = await executor.shutdownAndWait(timeout: .seconds(5))
        XCTAssertTrue(stopped)
        XCTAssertTrue(executor.positivelyStopped)
        XCTAssertFalse(executor.hasOwnedOperations)
        do {
            _ = try await executor.run(prompt: "must remain fenced", workspace: workspace)
            XCTFail("Shutdown must reject new launches")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(executor.resumeWithoutRunning())
        XCTAssertFalse(executor.hasOwnedOperations)
    }
}
