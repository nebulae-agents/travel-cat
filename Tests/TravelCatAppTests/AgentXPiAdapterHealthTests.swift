import Foundation
import Testing
@testable import TravelCatApp

@MainActor
struct AgentXPiAdapterHealthTests {
    @Test func localHealthReflectsExecutableRunnerAndBothSDKImports() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }

        let node = root.appendingPathComponent("node")
        let runner = root.appendingPathComponent("runner.mjs")
        let sdk = root.appendingPathComponent("node_modules/@earendil-works")
        let required = [runner, sdk.appendingPathComponent("pi-agent-core/package.json"),
                        sdk.appendingPathComponent("pi-agent-core/dist/index.js"),
                        sdk.appendingPathComponent("pi-ai/package.json"),
                        sdk.appendingPathComponent("pi-ai/dist/api/openai-completions.js")]
        let adapter: any AgentXRunAdapter = AgentXPiRuntime(nodeURL: node, runnerURL: runner)
        for asset in required {
            try files.createDirectory(at: asset.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: asset)
        }
        #expect(adapter.localHealth == "missing_runtime")
        try Data().write(to: node)
        try files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: node.path)
        #expect(adapter.localHealth == "missing_runtime")
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
        #expect(adapter.localHealth == "ready")
        for asset in required {
            try files.removeItem(at: asset)
            #expect(adapter.localHealth == "missing_runtime")
            try files.createDirectory(at: asset, withIntermediateDirectories: false)
            #expect(adapter.localHealth == "missing_runtime")
            try files.removeItem(at: asset)
            try Data().write(to: asset)
            #expect(adapter.localHealth == "ready")
        }
    }

    @Test func capabilitiesFollowTheConfiguredProgressMode() {
        let adapter: any AgentXRunAdapter = AgentXPiRuntime()
        for streaming in [false, true] {
            #expect(adapter.capabilities(streaming: streaming) == [
                "start": true, "stop": true, "stream": streaming, "usage": streaming,
                "tools": false, "step": false
            ])
        }
    }
}
