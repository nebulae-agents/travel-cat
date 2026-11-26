#if DEBUG
import AppKit
import CryptoKit
import Foundation

/// Scoped to the debug-only probe and the isolated desktop acceptance bundle.
struct AgentXFixtureCredential: TravelServiceCredentialStoring {
    let encoded: String
    var modelSecret: String? = nil
    func read(id: String) throws -> String? {
        if id == "audit-journal-v1" { return encoded }
        return id == "agentx.provider.local" ? modelSecret : nil
    }
    func save(_ secret: String?, id: String) throws { throw AgentXError.unavailable }
}

@MainActor
final class AgentXWriterProbe: NSObject, NSApplicationDelegate {
    private let writer: AgentXDesktopRunWriter
    init(arguments: [String]) throws {
        guard arguments.count == 4, let port = UInt16(arguments[3]), port > 0,
              arguments[1].wholeMatch(of: /\/private\/tmp\/agentx-app-writer-[A-Za-z0-9_-]+/) != nil else { throw AgentXError.corrupt }
        let root = URL(fileURLWithPath: arguments[1])
        let lease = try AgentXWriterRootLease(root: root)
        guard try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty else { throw AgentXError.unsafePath }
        let bundle = URL(fileURLWithPath: arguments[2])
        let node = bundle.appendingPathComponent("Contents/Helpers/PiAgent/node")
        let runner = bundle.appendingPathComponent("Contents/Resources/PiAgent/runner.mjs")
        guard bundle.pathExtension == "app", FileManager.default.isExecutableFile(atPath: node.path),
              FileManager.default.isReadableFile(atPath: runner.path) else { throw AgentXError.unavailable }
        let binding = AgentXPilot.PiBinding(instanceID: "pi", providerID: "local", model: "pilot-model",
                                            baseURL: "http://127.0.0.1:\(port)/v1", systemPrompt: "")
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
        writer = try AgentXDesktopRunWriter(root: root, lease: lease, apps: [.init(appID: "pilot", pi: binding)],
            runtime: AgentXPiRuntime(nodeURL: node, runnerURL: runner, ledgerRoot: root),
            credentials: AgentXFixtureCredential(encoded: key), configuredApp: { id in AgentXApplication(id: id, name: id, kind: .chat) }, canCreate: { _, _ in true },
            reportFailure: { _ in FileHandle.standardError.write(Data("writer probe unavailable\n".utf8)) })
    }

    func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.delegate = self
        writer.start()
        app.run()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await writer.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
#endif
