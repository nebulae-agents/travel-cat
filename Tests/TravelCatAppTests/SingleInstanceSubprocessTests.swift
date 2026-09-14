import Darwin
import Foundation
import XCTest
@testable import TravelCatApp

final class SingleInstanceSubprocessHelperTests: XCTestCase {
    func testRunHelper() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let mode = environment["TRAVEL_CAT_LOCK_HELPER_MODE"] else {
            throw XCTSkip("Only runs in a filtered child test process")
        }
        let root = try XCTUnwrap(environment["TRAVEL_CAT_LOCK_HELPER_ROOT"]).asFileURL
        let token = try XCTUnwrap(environment["TRAVEL_CAT_LOCK_HELPER_TOKEN"])
        let lockURL = root.appendingPathComponent("instance.lock")

        switch mode {
        case "race":
            try signal("ready", token: token, in: root)
            try waitForFile(root.appendingPathComponent("start"), timeout: 5)
            if let lock = SingleInstanceLock.acquire(at: lockURL) {
                try signal("acquired", token: token, in: root)
                try waitForFile(root.appendingPathComponent("release.\(token)"), timeout: 20)
                withExtendedLifetime(lock) {}
            } else {
                try signal("denied", token: token, in: root)
            }
        case "once":
            if let lock = SingleInstanceLock.acquire(at: lockURL) {
                try signal("acquired", token: token, in: root)
                withExtendedLifetime(lock) {}
            } else {
                try signal("denied", token: token, in: root)
            }
        case "exec":
            let lock = try XCTUnwrap(SingleInstanceLock.acquire(at: lockURL))
            let postExecMarker = root.appendingPathComponent("exec-ready.\(token)").path
            withExtendedLifetime(lock) {
                let arguments = [
                    "/bin/sh",
                    "-c",
                    "touch \"$1\"; exec /bin/cat",
                    "sh",
                    postExecMarker,
                ]
                var pointers = arguments.map { strdup($0) }
                pointers.append(nil)
                defer { pointers.compactMap { $0 }.forEach { free($0) } }
                let result = pointers.withUnsafeMutableBufferPointer {
                    execv($0[0], $0.baseAddress!)
                }
                XCTFail("exec failed with result \(result), errno \(errno)")
            }
        default:
            XCTFail("Unknown helper mode: \(mode)")
        }
    }

    private func signal(_ state: String, token: String, in root: URL) throws {
        try Data().write(to: root.appendingPathComponent("\(state).\(token)"), options: .atomic)
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            usleep(10_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Timed out waiting for \(url.lastPathComponent)")
    }
}

enum SubprocessLockHarness {
    private static let timeout: TimeInterval = 8

    static func assertRaceAndCrashRelease(in root: URL) throws {
        let first = try launch(mode: "race", token: "first", root: root)
        let second = try launch(mode: "race", token: "second", root: root)
        defer {
            stopIfRunning(first)
            stopIfRunning(second)
        }

        try waitForFiles([root.appendingPathComponent("ready.first"), root.appendingPathComponent("ready.second")])
        try Data().write(to: root.appendingPathComponent("start"), options: .atomic)
        try waitUntil(timeout: timeout) {
            resultCount(in: root, tokens: ["first", "second"]) == 2
        }

        let acquiredTokens = tokens(with: "acquired", in: root, candidates: ["first", "second"])
        let deniedTokens = tokens(with: "denied", in: root, candidates: ["first", "second"])
        XCTAssertEqual(acquiredTokens.count, 1)
        XCTAssertEqual(deniedTokens.count, 1)
        let winningToken = try XCTUnwrap(acquiredTokens.first)
        let winner = winningToken == "first" ? first : second
        let loser = winningToken == "first" ? second : first

        try waitForExit(loser)
        XCTAssertEqual(loser.terminationStatus, 0, "Lock loser helper failed")
        XCTAssertEqual(kill(winner.processIdentifier, SIGKILL), 0)
        try waitForExit(winner)
        XCTAssertEqual(winner.terminationReason, .uncaughtSignal)
        XCTAssertEqual(winner.terminationStatus, SIGKILL)

        let recovery = try launch(mode: "once", token: "recovery", root: root)
        defer { stopIfRunning(recovery) }
        try waitForExit(recovery)
        XCTAssertEqual(recovery.terminationStatus, 0, "Recovery helper failed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("acquired.recovery").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("denied.recovery").path))
    }

    static func assertCloseOnExec(in root: URL) throws {
        let execStandardInput = Pipe()
        let execHelper = try launch(mode: "exec", token: "exec", root: root, standardInput: execStandardInput)
        defer {
            try? execStandardInput.fileHandleForWriting.close()
            stopIfRunning(execHelper)
        }
        try waitForFiles([root.appendingPathComponent("exec-ready.exec")])
        XCTAssertTrue(execHelper.isRunning)

        let probe = try launch(mode: "once", token: "probe", root: root)
        defer { stopIfRunning(probe) }
        try waitForExit(probe)
        XCTAssertEqual(probe.terminationStatus, 0, "Post-exec lock probe failed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("acquired.probe").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("denied.probe").path))

        try execStandardInput.fileHandleForWriting.close()
        try waitForExit(execHelper)
        XCTAssertEqual(execHelper.terminationStatus, 0, "Exec helper did not exit cleanly")
    }

    private static func launch(
        mode: String,
        token: String,
        root: URL,
        standardInput: Pipe? = nil
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest",
            "-XCTest",
            "TravelCatAppTests.SingleInstanceSubprocessHelperTests/testRunHelper",
            Bundle(for: SingleInstanceSubprocessHelperTests.self).bundleURL.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["TRAVEL_CAT_LOCK_HELPER_MODE"] = mode
        environment["TRAVEL_CAT_LOCK_HELPER_ROOT"] = root.path
        environment["TRAVEL_CAT_LOCK_HELPER_TOKEN"] = token
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = standardInput
        try process.run()
        return process
    }

    private static func resultCount(in root: URL, tokens candidates: [String]) -> Int {
        tokens(with: "acquired", in: root, candidates: candidates).count
            + tokens(with: "denied", in: root, candidates: candidates).count
    }

    private static func tokens(with state: String, in root: URL, candidates: [String]) -> [String] {
        candidates.filter {
            FileManager.default.fileExists(atPath: root.appendingPathComponent("\(state).\($0)").path)
        }
    }

    private static func waitForFiles(_ urls: [URL]) throws {
        try waitUntil(timeout: timeout) {
            urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    private static func waitForExit(_ process: Process) throws {
        try waitUntil(timeout: timeout) { !process.isRunning }
    }

    private static func waitUntil(timeout: TimeInterval, condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            usleep(10_000)
        }
        XCTAssertTrue(condition(), "Condition was not met within \(timeout) seconds")
    }

    private static func stopIfRunning(_ process: Process) {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }
}

private extension String {
    var asFileURL: URL { URL(fileURLWithPath: self, isDirectory: true) }
}
