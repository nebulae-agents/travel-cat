import XCTest
@testable import TravelCatApp

@MainActor
final class AgentXPilotUninstallTests: XCTestCase {
    func testUninstallRejectedByPilotOwnership() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let external = ProcessInfo.processInfo.environment["AGENTX_UNINSTALL_REHEARSAL"]
        var target = root
        if let external {
            let workspace = URL(fileURLWithPath: external).resolvingSymlinksInPath()
            guard workspace.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().standardizedFileURL.path,
                  workspace.lastPathComponent.hasPrefix("agentx-ownership-") else { throw AgentXError.unsafePath }
            target = workspace.appendingPathComponent("root")
        } else {
            let marker = ["root": root.resolvingSymlinksInPath().path, "appID": "pilot"]
            try JSONEncoder().encode(marker).write(to: root.appendingPathComponent(".agentxd-pilot.json"))
        }
        let pilot = try XCTUnwrap(AgentXPilot.configured(at: target))
        XCTAssertEqual(pilot.appID, "pilot")
        guard pilot.appID == "pilot" else { return }
        let lifecycle = AgentXApplicationLifecycle(repository: AgentXRepository(root: target), requireIdle: { _ in
            XCTFail("Pilot ownership should be checked before idle state")
            throw AgentXError.unavailable
        })
        XCTAssertThrowsError(try lifecycle.uninstall("pilot")) {
            XCTAssertEqual($0.localizedDescription, "试点应用的运行由 agentxd 管理，暂不支持此操作。")
        }
    }
}
