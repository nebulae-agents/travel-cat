import XCTest
import AgentXAppSDK
@testable import TravelCatApp

final class AgentXFrontendTests: XCTestCase {
    func testIndependentFrontendKeepsStateAcrossPayloadUpgradeAndRootMove() throws {
        let base = URL(fileURLWithPath: "/private/tmp/Frontend-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("root"), moved = base.appendingPathComponent("moved")
        for path in ["apps/a/state", "apps/a/payload", "apps/b/state"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        var contract = AppFrontendContract(title: "Version one", modules: [.init(id: "draft", title: "Draft", fields: [.init(id: "topic", label: "Topic")], submit: .init(title: "Send", prompt: "{{topic}}"))])
        var manifest = AppManifest(id: "a", name: "A", version: "1", dataSchemaVersion: 1, hostAPIMajor: 1, kind: "chat", runtime: "host-text", modules: ["draft"])
        let manifestFile = root.appendingPathComponent("apps/a/manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestFile)
        let file = root.appendingPathComponent("apps/a/payload/frontend.json")
        try JSONEncoder().encode(contract).write(to: file)
        let store = AgentXFrontendStore(root: root, appID: "a")
        XCTAssertTrue(store.exists)
        XCTAssertTrue(try store.load().1.isEmpty)
        manifest.runtime = "unsupported-framework"
        try JSONEncoder().encode(manifest).write(to: manifestFile)
        XCTAssertThrowsError(try store.load())
        manifest.runtime = "host-text"; manifest.modules = ["missing-module"]
        try JSONEncoder().encode(manifest).write(to: manifestFile)
        XCTAssertThrowsError(try store.load())
        manifest.modules = ["draft"]
        try JSONEncoder().encode(manifest).write(to: manifestFile)
        try store.save(["draft":["topic":"Original input"]])
        contract.title = "Version two"
        try JSONEncoder().encode(contract).write(to: file)
        try FileManager.default.moveItem(at: root, to: moved)
        let result = try AgentXFrontendStore(root: moved, appID: "a").load()
        XCTAssertEqual(result.0.title, "Version two")
        XCTAssertEqual(result.1["draft"]?["topic"], "Original input")
        let sibling = moved.appendingPathComponent("apps/b/state/private.json")
        try Data("private".utf8).write(to: sibling)
        let state = moved.appendingPathComponent("apps/a/state/frontend-values.json")
        try FileManager.default.removeItem(at: state)
        try FileManager.default.createSymbolicLink(at: state, withDestinationURL: sibling)
        XCTAssertThrowsError(try AgentXFrontendStore(root: moved, appID: "a").load())
        XCTAssertThrowsError(try AgentXFrontendStore(root: moved, appID: "a").save([:]))
        XCTAssertEqual(try String(contentsOf: sibling, encoding: .utf8), "private")
    }
}
