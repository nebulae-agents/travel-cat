import XCTest
@testable import TravelCatApp

final class AgentXAcceptanceLaunchTests: XCTestCase {
    #if DEBUG
    func testDesktopReceiptContainsOnlyRunIdentityAndObservedStatus() throws {
        var run = AgentXRun(id: "turn", appID: "pilot", instanceID: "member", prompt: "private input", status: .cancelled)
        run.response = "private output"
        run.revision = 4
        run.stopEvidence = "confirmedExited"
        let bytes = try XCTUnwrap(AgentXAcceptanceLaunch.receiptLine(for: run))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["pid", "runID", "status", "revision", "stopEvidence", "displayedStatus"])
        XCTAssertEqual(json["pid"] as? Int32, getpid())
        XCTAssertEqual(json["runID"] as? String, "turn")
        XCTAssertEqual(json["revision"] as? Int, 4)
        XCTAssertEqual(json["stopEvidence"] as? String, "confirmedExited")
        XCTAssertEqual(json["displayedStatus"] as? String, run.displayedStatus)
        run.stopEvidence = "private unknown extension"
        let unknown = try XCTUnwrap(AgentXAcceptanceLaunch.receiptLine(for: run))
        let redacted = try XCTUnwrap(JSONSerialization.jsonObject(with: unknown) as? [String: Any])
        XCTAssertTrue(redacted["stopEvidence"] is NSNull)
        XCTAssertFalse(String(decoding: unknown, as: UTF8.self).contains("private"))
        XCTAssertEqual(unknown.last, 0x0A)
    }
    #endif

    func testPilotBundleRequiresMatchingIsolatedEnvironmentBeforeBoot() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: "/private/tmp/agentxd-pi-e2e-\(UUID())")
        let root = base.appendingPathComponent("root"), host = base.appendingPathComponent("host")
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: base) }

        let id = "local.agentx.pi-run.acceptance"
        let env = ["AGENTX_ROOT": root.path, "AGENTX_HOST_DIRECTORY": host.path]
        func allowed(_ env: [String: String], bundle: String = "local.agentx.pi-run.acceptance") -> Bool {
            AgentXAcceptanceLaunch.permits(bundleID: bundle, environment: env)
        }
        XCTAssertTrue(allowed([:], bundle: "com.nebulae.travelcat"))
        XCTAssertFalse(allowed([:], bundle: id))
        XCTAssertFalse(allowed(["AGENTX_ROOT": root.path]))
        XCTAssertFalse(allowed(env)) // Missing ownership marker.
        let marker = root.appendingPathComponent(".agentxd-pilot.json")
        func writeMarker(_ path: String) throws {
            let model = ["instanceID": "pi", "providerID": "p", "model": "m"]
            try JSONSerialization.data(withJSONObject: ["root": path, "appID": "pilot", "pi": model]).write(to: marker)
        }
        try writeMarker(host.path)
        XCTAssertFalse(allowed(env))
        try writeMarker(root.path)
        XCTAssertTrue(allowed(env)) // host may be created by the isolated app on first launch.
        let binding = ["instanceID": "pi", "providerID": "p", "model": "m",
                       "baseURL": "https://openrouter.ai/api/v1", "systemPrompt": "system"]
        let apps: [[String: Any]] = [["appID": "other"], ["appID": "pilot", "pi": binding]]
        let multi: [String: Any] = ["root": root.path, "version": 2, "apps": apps]
        try JSONSerialization.data(withJSONObject: multi).write(to: marker)
        XCTAssertTrue(allowed(env))
        XCTAssertFalse(allowed(["AGENTX_ROOT": root.path, "AGENTX_HOST_DIRECTORY": base.path]))
        try fm.createSymbolicLink(at: host, withDestinationURL: root)
        XCTAssertFalse(allowed(env))
        try fm.removeItem(at: host)
        try fm.createDirectory(at: host, withIntermediateDirectories: false)
        XCTAssertTrue(allowed(env))
        try Data("{}".utf8).write(to: host.appendingPathComponent("location.json"))
        XCTAssertFalse(allowed(env)) // An old locator could redirect the app into another root.
    }
}
