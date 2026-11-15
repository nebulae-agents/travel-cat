import XCTest
@testable import TravelCatApp

final class AgentXPiProcessLedgerTests: XCTestCase {
    func testMissingLedgerNeverProvesOldPiExit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = AgentXStopProcessIdentity(pid: 123, seconds: 1, microseconds: 2)
        XCTAssertFalse(try AgentXPiProcessLedger(root: root).confirmedExited(owner: owner, runID: "run"))
    }
    func testStartingRecordBlocksUntilReapedRecordIsSaved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = AgentXPiProcessLedger(root: root)
        let owner = AgentXStopProcessIdentity(pid: 123, seconds: 1, microseconds: 2)
        let id = try ledger.begin(owner: owner, runID: "run")
        XCTAssertFalse(try ledger.confirmedExited(owner: owner, runID: "run"))
        try ledger.reaped(id: id)
        XCTAssertTrue(try ledger.confirmedExited(owner: owner, runID: "run"))
    }
}
