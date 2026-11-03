import Foundation
import XCTest
@testable import AgentXAppSDK

final class BoundedReadTests: XCTestCase {
    func testReadRejectsOversizedFileBeforeReturningData() throws {
        let root = URL(fileURLWithPath: "/private/tmp/Bounded-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("apps/a/state"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("apps/a/state/test")
        try Data(repeating: 1, count: 33).write(to: file)
        let access = try AppFileAccess(root: root, appID: "a", grants: [.init(appID: "a", relativePath: "apps/a/state", access: .read)])
        XCTAssertThrowsError(try access.read(relativePath: "apps/a/state/test", maximumBytes: 32))
        XCTAssertEqual(try access.read(relativePath: "apps/a/state/test", maximumBytes: 33).count, 33)
    }
}
