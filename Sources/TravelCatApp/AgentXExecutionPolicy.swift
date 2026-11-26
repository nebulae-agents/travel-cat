import Foundation
import AgentXAppSDK
import TravelStorage

struct AgentXPermissionDenied: Error, LocalizedError, Sendable {
    let operation: String
    var errorDescription: String? { "应用权限不足，已阻止操作并记录权限事件。" }
}

/// Host-compiled capabilities. App declarations are never interpolated into SBPL.
/// `configured-provider` means one configured origin, not an arbitrary URL proxy.
struct AgentXExecutionPolicy: Equatable, Sendable {
    let root: URL
    let appID: String
    let fileGrants: [AppFileGrant]
    private let networkOrigin: String?

    init(root: URL, application: AgentXApplication, provider: AgentXProvider) throws {
        // Normalize only standard macOS aliases; do not silently accept a linked app/root.
        let path = root.path
        self.root = URL(fileURLWithPath: path.hasPrefix("/var/") ? "/private" + path : path.hasPrefix("/tmp/") ? "/private" + path : path)
        appID = application.id
        _ = try AppFileAccess(root: self.root, appID: appID, grants: [])
        let permissions = application.declaredPermissions
        let files = permissions["files"]?.strings ?? []
        let network = permissions["network"]?.strings ?? []
        fileGrants = files.contains("self") ? [
            .init(appID: appID, relativePath: "apps/\(appID)/state", access: .readWrite),
            .init(appID: appID, relativePath: "apps/\(appID)/artifacts", access: .readWrite),
            .init(appID: appID, relativePath: "apps/\(appID)/payload", access: .read)
        ] : []
        networkOrigin = network.contains("configured-provider") ? Self.origin(provider.baseURL) : nil
        do { try application.validateManifest() } catch { try deny("manifest.permissions", runID: nil) }
        guard application.enabled, Set(files).isSubset(of: ["self"]), Set(network).isSubset(of: ["configured-provider"]),
              Set(permissions.keys).isSubset(of: ["files", "network", "secrets", "shell", "schedule"]),
              permissions["secrets"]?.strings?.isEmpty ?? true,
              permissions["shell"] == nil || permissions["shell"] == .bool(false),
              permissions["schedule"] == nil || permissions["schedule"] == .bool(false) else {
            try deny("manifest.permissions", runID: nil)
        }
    }

    private static func origin(_ value: String) -> String? {
        let address = value.hasSuffix("#") ? String(value.dropLast()) : value
        guard let url = URLComponents(string: address), let host = url.host?.lowercased(), !host.isEmpty,
              !host.contains("%"), !host.hasSuffix("."), host.unicodeScalars.allSatisfy({ $0.isASCII }),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !value.contains("\\"), !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              url.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        guard url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)) else { return nil }
        return "\(url.scheme!)://\(host):\(url.port ?? (url.scheme == "https" ? 443 : 80))"
    }

    func requireNetwork(_ url: String, runID: String?) throws {
        guard let networkOrigin, Self.origin(url) == networkOrigin else { try deny("network.connect", runID: runID) }
    }

    func deny(_ operation: String, runID: String?) throws -> Never {
        try recordDenial(operation, runID: runID)
        throw AgentXPermissionDenied(operation: operation)
    }

    /// These are trusted policy rejections, not a claim to observe arbitrary denied syscalls.
    func recordDenial(_ operation: String, runID: String?) throws {
        _ = try AppFileAccess(root: root, appID: appID, grants: [])
        let id = UUID().uuidString.lowercased()
        let destination = try AgentXPackageFiles.safeURL("apps/\(appID)/events/permissions/\(id).json", root: root)
        var fields: [String: Any] = ["version": 1, "eventID": id, "kind": "permission.denied", "source": "host_policy",
                                     "appID": appID, "operation": operation, "timestamp": ISO8601DateFormatter().string(from: Date())]
        if let runID { fields["runID"] = runID }
        try AtomicFileWriter().write(JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), to: destination)
    }

    func events() throws -> [[String: Any]] {
        let directory = try AgentXPackageFiles.safeURL("apps/\(appID)/events/permissions", root: root)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map {
                guard let event = try JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any] else { throw AgentXError.corrupt }
                return event
            }
    }

    func sandbox(gatewayURL: String?, runID: String?) throws -> AgentXPiSandbox {
        if let gatewayURL {
            guard let endpoint = URLComponents(string: gatewayURL), endpoint.scheme == "http", endpoint.host == "127.0.0.1",
                  let port = endpoint.port, (1...65535).contains(port), endpoint.user == nil, endpoint.password == nil,
                  endpoint.query == nil, endpoint.fragment == nil else { try deny("runtime.gateway", runID: runID) }
        }
        for grant in fileGrants {
            let directory = try AgentXPackageFiles.safeURL(grant.relativePath, root: root)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return AgentXPiSandbox(policy: self, gatewayURL: gatewayURL)
    }
}

/// Only the trusted host can mint this after binding its disposable listener.
/// A nil endpoint is useful for fully offline host process fixtures; it grants no network.
struct AgentXPiSandbox: Sendable {
    let policy: AgentXExecutionPolicy
    let gatewayURL: String?
    func profile(node: URL, runner: URL) throws -> String {
        try AppSandboxProfile.generate(root: policy.root, appID: policy.appID, grants: policy.fileGrants,
            runtimeFiles: [node, runner], runtimeDirectories: [runner.deletingLastPathComponent().appendingPathComponent("node_modules")],
            loopbackPort: gatewayURL.flatMap { URLComponents(string: $0)?.port }.flatMap(UInt16.init(exactly:)))
    }
}

enum AgentXPermissionContext {
    @TaskLocal static var sandbox: AgentXPiSandbox?
}
