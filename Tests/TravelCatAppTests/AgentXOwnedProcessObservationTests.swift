import Darwin
import XCTest
@testable import TravelCatApp

final class AgentXOwnedProcessObservationTests: XCTestCase {
    func testIdentityMismatchIsUnknown() throws {
        var identity = try XCTUnwrap(AgentXStopProcessIdentity.read(getpid()))
        identity.seconds += 1
        XCTAssertEqual(AgentXOwnedProcessSnapshot.observe(identity).state, .unknown)
    }
    func testRealChildAliveThenExitedWithoutObservationReaping() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["10"]
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        let identity = try XCTUnwrap(AgentXStopProcessIdentity.read(child.processIdentifier))
        XCTAssertEqual(AgentXOwnedProcessSnapshot.observe(identity).state, .alive)
        XCTAssertTrue(child.isRunning)
        child.terminate(); child.waitUntilExit()
        XCTAssertEqual(AgentXOwnedProcessSnapshot.observe(identity).state, .exited)
    }
    func testPiScopeAndReadOnlyReceipt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = AgentXPiProcessLedger(root: root)
        let owner = try XCTUnwrap(AgentXStopProcessIdentity.read(getpid()))
        let id = try ledger.begin(owner: owner, runID: "one")
        try ledger.launched(id: id, child: owner)
        let file = root.appendingPathComponent("manager/pi-processes/\(id.uuidString).json")
        let before = try Data(contentsOf: file)
        XCTAssertEqual(ledger.observeOwnedProcesses(owner: owner, runIDs: ["one"]).state, .alive)
        XCTAssertEqual(ledger.observeOwnedProcesses(owner: owner, runIDs: ["other"]).state, .unobserved)
        let historicalIDs = Set((0..<200).map { "historical-\($0)" }).union(["one"])
        let scoped = ledger.observeOwnedProcesses(owner: owner, runIDs: historicalIDs)
        XCTAssertEqual(scoped.state, .alive)
        XCTAssertEqual(scoped.observedCount, 1)
        XCTAssertEqual(before, try Data(contentsOf: file))
    }
    func testPiRejectsWrongOwnerAndUncachedPreviousSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ledger = AgentXPiProcessLedger(root: root)
        let owner = try XCTUnwrap(AgentXStopProcessIdentity.read(getpid()))
        XCTAssertEqual(ledger.observeOwnedProcesses(owner: owner, runIDs: ["old"]).reason, .unsupported)
        var wrong = owner; wrong.microseconds += 1
        XCTAssertEqual(ledger.observeOwnedProcesses(owner: wrong, runIDs: ["old"]).reason, .identityMismatch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    @MainActor func testEmptyCLIIsUnobserved() {
        XCTAssertEqual(CodexTravelExecutor().observeOwnedProcesses().state, .unobserved)
    }
}
