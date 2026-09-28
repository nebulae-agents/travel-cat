import Darwin
import Foundation
import XCTest
@testable import TravelCatApp

@MainActor
final class CodexTravelExecutorTests: XCTestCase {
    private func fixture(_ body: String) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("fake-codex")
        try ("#!/bin/sh\n" + body).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, script)
    }

    func testPassesPromptThroughStdinAndReturnsOnlyFinalMessage() async throws {
        let (root, script) = try fixture("""
        printf '%s\\n' "$@" > arguments
        while [ "$#" -gt 0 ]; do
          if [ "$1" = '--output-last-message' ]; then shift; result="$1"; fi
          shift
        done
        cat > "$result"
        printf 'private log should not be returned'
        """)
        let value = try await CodexTravelExecutor(executableURL: script).run(prompt: "hello $world", workspace: root)
        XCTAssertEqual(String(decoding: value, as: UTF8.self), "hello $world")
        let arguments = try String(contentsOf: root.appendingPathComponent("arguments"), encoding: .utf8)
        XCTAssertTrue(arguments.contains("--ignore-user-config\n"))
        XCTAssertTrue(arguments.contains("--sandbox\nworkspace-write\n"))
        XCTAssertFalse(arguments.contains("--add-dir"))
        XCTAssertFalse(arguments.contains("hello"))
    }

    func testExplicitDiagnosticSinkReceivesBoundedOutputOnFailure() async throws {
        let (root, script) = try fixture("/usr/bin/yes 'private bounded diagnostic' | /usr/bin/head -c 200000\nexit 1")
        let capture = DiagnosticCapture()
        do {
            _ = try await CodexTravelExecutor(executableURL: script, diagnostics: { capture.set($0) }).run(prompt: "x", workspace: root)
            XCTFail("must fail")
        } catch {
            XCTAssertEqual(error as? CodexTravelExecutor.Failure, .generationFailed)
        }
        XCTAssertGreaterThan(capture.value.count, 0)
        XCTAssertLessThanOrEqual(capture.value.count, 65536)
        XCTAssertTrue(String(decoding: capture.value, as: UTF8.self).contains("private bounded diagnostic"))
    }

    func testFailureDoesNotExposeLogsAndDetectsMissingLogin() async throws {
        for (log, expected) in [("secret-token failure", CodexTravelExecutor.Failure.generationFailed), ("Not logged in", .notLoggedIn)] {
            let (root, script) = try fixture("echo '\(log)' >&2\nexit 1")
            do { _ = try await CodexTravelExecutor(executableURL: script).run(prompt: "x", workspace: root); XCTFail("must fail") }
            catch { XCTAssertEqual(error as? CodexTravelExecutor.Failure, expected); XCTAssertFalse(error.localizedDescription.contains("secret-token")) }
        }
    }

    func testTimeoutStopsDescendants() async throws {
        let (root, script) = try fixture("sleep 30 &\necho $! > child-pid\nwait")
        do { _ = try await CodexTravelExecutor(executableURL: script, timeout: 8).run(prompt: "x", workspace: root); XCTFail("must time out") }
        catch { XCTAssertEqual(error as? CodexTravelExecutor.Failure, .timedOut) }
        let pid = try XCTUnwrap(Int32(String(contentsOf: root.appendingPathComponent("child-pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(kill(pid, 0), -1)
    }

    func testCancellationStopsProcess() async throws {
        let (root, script) = try fixture("echo $$ > process-pid\nsleep 30")
        let task = Task { try await CodexTravelExecutor(executableURL: script).run(prompt: "x", workspace: root) }
        for _ in 0..<1000 where !FileManager.default.fileExists(atPath: root.appendingPathComponent("process-pid").path) { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        do { _ = try await task.value; XCTFail("must cancel") } catch { XCTAssertTrue(error is CancellationError) }
        let pid = try XCTUnwrap(Int32(String(contentsOf: root.appendingPathComponent("process-pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1)
    }

    func testCancelAllSynchronouslyStopsProcessForApplicationExit() async throws {
        let (root, script) = try fixture("echo $$ > process-pid\nsleep 30")
        let executor = CodexTravelExecutor(executableURL: script)
        let task = Task { try await executor.run(prompt: "x", workspace: root) }
        for _ in 0..<1000 where !FileManager.default.fileExists(atPath: root.appendingPathComponent("process-pid").path) { try await Task.sleep(for: .milliseconds(10)) }
        let pid = try XCTUnwrap(Int32(String(contentsOf: root.appendingPathComponent("process-pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        executor.cancelAll()
        XCTAssertEqual(kill(pid, 0), -1)
        do { _ = try await task.value; XCTFail("must cancel") } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCancelAllStopsDescendantInSeparateSession() async throws {
        let (root, script) = try fixture("""
        /usr/bin/python3 -c 'import os,time; os.setsid(); child=os.fork(); os.setsid() if child == 0 else None; open("detached-pid" if child == 0 else "detached-parent-pid", "w").write(str(os.getpid())); time.sleep(60)' &
        wait
        """)
        let executor = CodexTravelExecutor(executableURL: script)
        let task = Task { try await executor.run(prompt: "x", workspace: root) }
        let marker = root.appendingPathComponent("detached-pid")
        for _ in 0..<1000 where !FileManager.default.fileExists(atPath: marker.path) { try await Task.sleep(for: .milliseconds(10)) }
        let pid = try XCTUnwrap(Int32(String(contentsOf: marker, encoding: .utf8)))
        let parent = try XCTUnwrap(Int32(String(contentsOf: root.appendingPathComponent("detached-parent-pid"), encoding: .utf8)))
        defer { kill(pid, SIGKILL); kill(parent, SIGKILL) }
        XCTAssertEqual(getpgid(parent), parent)
        XCTAssertEqual(getpgid(pid), pid, "fixture must escape the executor process group")
        executor.cancelAll()
        do { _ = try await task.value; XCTFail("must cancel") } catch { XCTAssertTrue(error is CancellationError) }
        for _ in 0..<100 where kill(pid, 0) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(kill(pid, 0), -1, "separate-session grandchild must not survive cancellation")
        XCTAssertEqual(kill(parent, 0), -1, "separate-session child must not survive cancellation")
    }

    func testSuccessAlsoStopsLeftoverDescendants() async throws {
        let (root, script) = try fixture("""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = '--output-last-message' ]; then shift; result="$1"; fi
          shift
        done
        sleep 30 &
        echo $! > child-pid
        printf '{}' > "$result"
        exit 0
        """)
        _ = try await CodexTravelExecutor(executableURL: script).run(prompt: "x", workspace: root)
        let pid = try XCTUnwrap(Int32(String(contentsOf: root.appendingPathComponent("child-pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(kill(pid, 0), -1)
    }

    func testMissingExecutableHasActionableError() async throws {
        let root = FileManager.default.temporaryDirectory
        do { _ = try await CodexTravelExecutor(executableURL: root.appendingPathComponent(UUID().uuidString)).run(prompt: "x", workspace: root); XCTFail("must fail") }
        catch { XCTAssertEqual(error as? CodexTravelExecutor.Failure, .notInstalled) }
    }

    func testOutputFloodCannotBlockTimeout() async throws {
        let (root, script) = try fixture("echo started > started\nwhile :; do printf 'lots of output lots of output lots of output\\n'; printf 'more error output\\n' >&2; done")
        let start = Date()
        do { _ = try await CodexTravelExecutor(executableURL: script, timeout: 8).run(prompt: "x", workspace: root); XCTFail("must time out") }
        catch { XCTAssertEqual(error as? CodexTravelExecutor.Failure, .timedOut) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path))
        XCTAssertLessThan(Date().timeIntervalSince(start), 12)
    }
}

private final class DiagnosticCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.lock(); defer { lock.unlock() }; data = value }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}
