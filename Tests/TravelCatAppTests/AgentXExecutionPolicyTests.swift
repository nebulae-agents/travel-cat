import Foundation
import Testing
import AgentXAppSDK
@testable import TravelCatApp

struct AgentXExecutionPolicyTests {
    private func root() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("agentx-permissions-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func app(network: [String] = ["configured-provider"], files: [String] = ["self"]) -> AgentXApplication {
        var app = AgentXApplication(id: "a", name: "A", kind: .chat)
        app.manifest = ["permissions": .object(["network": .array(network.map { .string($0) }), "files": .array(files.map { .string($0) })])]
        return app
    }
    private let provider = AgentXProvider(id: "p", name: "P", baseURL: "https://api.example.com/v1", models: ["m"])

    @Test func newBuiltinDeclaresOnlyMinimalTextPermissions() throws {
        let app = try #require(AgentXState().apps.first)
        #expect(app.declaredPermissions["network"]?.strings == ["configured-provider"])
        #expect(app.declaredPermissions["files"]?.strings == ["self"])
        #expect(app.declaredPermissions["secrets"]?.strings == [])
        #expect(app.declaredPermissions["shell"] == .bool(false))
        #expect(app.declaredPermissions["schedule"] == .bool(false))
        #expect(AgentXApplication(id: "imported", name: "Imported", kind: .chat).declaredPermissions.isEmpty)
    }
    @Test func missingNetworkPermissionPersistsDenialWithoutGrantingFiles() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let policy = try AgentXExecutionPolicy(root: root, application: app(network: [], files: []), provider: provider)
        #expect(policy.fileGrants.isEmpty)
        #expect(throws: AgentXPermissionDenied.self) { try policy.requireNetwork(provider.baseURL, runID: "r") }
        let events = try policy.events()
        #expect(events.count == 1)
        #expect(events[0]["kind"] as? String == "permission.denied")
        #expect(events[0]["source"] as? String == "host_policy")
        #expect(events[0]["operation"] as? String == "network.connect")
        #expect(events[0]["runID"] as? String == "r")
    }
    @Test func configuredProviderIsExactOriginAndDoesNotGrantSiblingsOrControlFiles() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let policy = try AgentXExecutionPolicy(root: root, application: app(), provider: provider)
        try policy.requireNetwork("https://api.example.com/v1/chat/completions", runID: "r")
        try policy.requireNetwork("https://api.example.com/custom/chat/completions#", runID: "r")
        #expect(throws: AgentXPermissionDenied.self) { try policy.requireNetwork("https://api.example.com/custom#fragment", runID: "r") }
        for url in ["https://api.example.com.evil.test/v1", "https://evil.test/v1", "http://api.example.com/v1", "https://api.example.com:444/v1", "https://user@api.example.com/v1"] {
            #expect(throws: AgentXPermissionDenied.self) { try policy.requireNetwork(url, runID: "r") }
        }
        #expect(Set(policy.fileGrants.map(\.relativePath)) == ["apps/a/state", "apps/a/artifacts", "apps/a/payload"])
        #expect(!policy.fileGrants.contains { $0.relativePath == "apps/a" })
    }
    @Test func malformedPermissionTypesAreRejectedAndRecorded() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        for value: AgentXManifestValue in [.string("configured-provider"), .bool(true), .array([.integer(1)])] {
            var malformed = app()
            malformed.manifest = ["permissions": .object(["network": value])]
            #expect(throws: AgentXPermissionDenied.self) { try AgentXExecutionPolicy(root: root, application: malformed, provider: provider) }
        }
        #expect(try AgentXExecutionPolicy(root: root, application: app(), provider: provider).events().count == 3)
    }
    @Test func unknownGrantsAndSymlinkRootFailClosed() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: (any Error).self) { try AgentXExecutionPolicy(root: root, application: app(files: ["../b"]), provider: provider) }
        let linked = root.appendingPathComponent("alias")
        let target = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)
        #expect(throws: (any Error).self) { try AgentXExecutionPolicy(root: linked, application: app(), provider: provider) }
    }
}
