#if DEBUG
import Darwin
import Foundation
import XCTest
@testable import TravelCatApp

final class AgentXWriterProbeTests: XCTestCase {
    func testRootLeaseExcludesSecondOwnerAndRejectsOtherDirectories() throws {
        let root = URL(fileURLWithPath: "/private/tmp/agentx-app-writer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try withExtendedLifetime(AgentXWriterRootLease(root: root)) { _ in
            XCTAssertThrowsError(try AgentXWriterRootLease(root: root))
        }
        XCTAssertNoThrow(try AgentXWriterRootLease(root: root))
        XCTAssertThrowsError(try AgentXWriterRootLease(root: root.deletingLastPathComponent()))
    }
}
#endif
