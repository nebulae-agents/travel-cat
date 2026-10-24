import Foundation
import XCTest
@testable import TravelCatApp

/// Real empty sidecar subprocesses only: no UI, Docker, Native daemon, profile or account RPC.
final class AgentSidecarExitTests: XCTestCase {
    private func python() throws -> String {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = ["/opt/homebrew/bin/python3"] + paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0).appendingPathComponent("python3").path }
        return try XCTUnwrap(candidates.first { FileManager.default.isExecutableFile(atPath: $0) }, "Python 3.11+ is required by the runtime contracts")
    }
    @MainActor func testUnlaunchedClientNeedsNoExitObservation() async {
        let exited = await AgentSidecarClient().waitForExit(timeout: .zero)
        XCTAssertTrue(exited)
    }
    @MainActor func testPublicExitCallbackAndEOFDoNotPrematurelyConfirmTermination() async throws {
        let client = AgentSidecarClient()
        var callbacks = 0
        client.onExit = { callbacks += 1 }
        try client.launch(python: python())
        client.onExit?() // A callback is transport state, not process-termination evidence.
        let beforeEOF = await client.waitForExit(timeout: .milliseconds(50))
        XCTAssertFalse(beforeEOF)
        XCTAssertEqual(callbacks, 1)
        client.shutdown()
        let beforeObservation = await client.waitForExit(timeout: .zero)
        XCTAssertFalse(beforeObservation, "Closing input alone cannot publish detached evidence")
        let exited = await client.waitForExit(timeout: .seconds(10))
        XCTAssertTrue(exited)
        XCTAssertEqual(callbacks, 2, "The existing actual-exit callback remains available")
    }
    @MainActor func testProtocolInvalidationStillWaitsForExactOldChildTermination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidecar-exit-protocol-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let release = root.appendingPathComponent("release")
        var exitConfirmed = false
        defer {
            // Every early failure releases only this owned fixture. Keep its
            // directory as evidence unless actual termination was confirmed.
            try? Data().write(to: release)
            if exitConfirmed { try? FileManager.default.removeItem(at: root) }
        }
        let readyMarker = root.appendingPathComponent("ready")
        let invalidationGate = root.appendingPathComponent("invalidate")
        let executable = root.appendingPathComponent("protocol-fixture.sh")
        let script = """
        #!/bin/sh
        trap '' TERM
        fixture_dir=$(/usr/bin/dirname "$0")
        : > "$fixture_dir/ready"
        attempts=0
        while [ ! -f "$fixture_dir/invalidate" ] && [ ! -f "$fixture_dir/release" ] && [ "$attempts" -lt 1500 ]; do
          /bin/sleep 0.02
          attempts=$((attempts + 1))
        done
        if [ ! -f "$fixture_dir/invalidate" ] || [ -f "$fixture_dir/release" ]; then exit 0; fi
        printf 'not-json\n'
        attempts=0
        while [ ! -f "$fixture_dir/release" ] && [ "$attempts" -lt 1500 ]; do
          /bin/sleep 0.02
          attempts=$((attempts + 1))
        done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = AgentSidecarClient()
        var callbacks = 0
        let invalidated = expectation(description: "Malformed protocol invalidated the actual transport generation")
        client.onExit = {
            callbacks += 1
            if callbacks == 1 { invalidated.fulfill() }
        }
        try client.launch(python: executable.path)
        // Launch is not readiness. The child cannot emit the invalid protocol
        // until the test observes its marker and explicitly opens the gate.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: readyMarker.path)
        }, object: nil)
        await fulfillment(of: [ready], timeout: 10)
        guard FileManager.default.fileExists(atPath: readyMarker.path) else {
            XCTFail("Owned fixture did not confirm startup readiness")
            return
        }
        try Data().write(to: invalidationGate)
        await fulfillment(of: [invalidated], timeout: 10)
        XCTAssertEqual(callbacks, 1, "Malformed protocol must invalidate the transport generation")
        guard callbacks == 1 else { return } // Failed precondition; defer releases the owned child.
        let stillRunning = await client.waitForExit(timeout: .milliseconds(50))
        XCTAssertFalse(stillRunning, "Transport invalidation is not an actual child exit")
        try Data().write(to: release)
        let exited = await client.waitForExit(timeout: .seconds(5))
        exitConfirmed = exited
        XCTAssertTrue(exited, "The old generation termination must still release its exact lifetime observation")
        XCTAssertEqual(callbacks, 1, "Keep the existing old-generation callback suppression")
    }
    @MainActor func testEOFExitObservationDoesNotRequirePublicCallback() async throws {
        let client = AgentSidecarClient()
        try client.launch(python: python())
        client.onExit = nil // The model may ignore its callback after shutdown.
        client.shutdown()
        let exited = await client.waitForExit(timeout: .seconds(10))
        XCTAssertTrue(exited)
    }
}
