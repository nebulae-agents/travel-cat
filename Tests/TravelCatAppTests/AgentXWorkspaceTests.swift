import XCTest
@testable import TravelCatApp

final class AgentXWorkspaceTests: XCTestCase {
    func testRelativeGrantSurvivesRootMoveAndRejectsOtherApps() throws {
        let base = URL(fileURLWithPath: "/private/tmp/agentx-workspace-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let first = base.appendingPathComponent("first"), second = base.appendingPathComponent("second")
        let relative = "apps/workbench/workspace/project"
        try FileManager.default.createDirectory(at: first.appendingPathComponent(relative), withIntermediateDirectories: true)
        let selected = try AgentXWorkspacePolicy.relativeSelection(first.appendingPathComponent(relative), root: first)
        XCTAssertEqual(selected, relative)
        XCTAssertEqual(try AgentXWorkspacePolicy.resolve(selected, root: first).path, first.appendingPathComponent(relative).path)
        try FileManager.default.moveItem(at: first, to: second)
        XCTAssertEqual(try AgentXWorkspacePolicy.resolve(selected, root: second).path, second.appendingPathComponent(relative).path)
        for invalid in ["/tmp", "apps/blackcat/state", "apps/workbench/workspace/../state", "apps/workbench/workspace", "shared/project"] {
            XCTAssertThrowsError(try AgentXWorkspacePolicy.resolve(invalid, root: second))
        }
        try FileManager.default.createSymbolicLink(at: second.appendingPathComponent("apps/workbench/workspace/link"), withDestinationURL: base)
        XCTAssertThrowsError(try AgentXWorkspacePolicy.resolve("apps/workbench/workspace/link", root: second))
    }
}
