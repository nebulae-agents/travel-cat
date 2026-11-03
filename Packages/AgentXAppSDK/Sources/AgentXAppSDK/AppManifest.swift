import Foundation

public enum AppSDKError: Error, Equatable { case invalidPath, invalidManifest, incompatibleHost, denied, unsafeFile, system(Int32) }

func components(_ path: String) throws -> [String] {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") && !$0.contains("\\") }) else { throw AppSDKError.invalidPath }
    return parts
}
func validID(_ id: String) -> Bool {
    !id.isEmpty && id == id.lowercased() && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
}

public struct AppManifest: Codable, Equatable, Sendable {
    public struct Paths: Codable, Equatable, Sendable {
        public var state: String
        public var artifacts: String
        public var instances: String
        public var runs: String
        public init(appID: String) {
            state = "apps/\(appID)/state"; artifacts = "apps/\(appID)/artifacts"
            instances = "apps/\(appID)/instances"; runs = "apps/\(appID)/runs"
        }
    }
    public var id: String
    public var name: String
    public var version: String
    public var dataSchemaVersion: Int
    public var hostAPIMajor: Int
    public var kind: String
    public var runtime: String
    public var modules: [String]
    public var paths: Paths
    public init(id: String, name: String, version: String, dataSchemaVersion: Int, hostAPIMajor: Int, kind: String, runtime: String, modules: [String]) {
        self.id = id; self.name = name; self.version = version; self.dataSchemaVersion = dataSchemaVersion
        self.hostAPIMajor = hostAPIMajor; self.kind = kind; self.runtime = runtime; self.modules = modules; paths = Paths(appID: id)
    }
    public func validate(hostAPIMajor supportedMajor: Int) throws {
        guard validID(id), !name.isEmpty, !version.isEmpty, dataSchemaVersion > 0, hostAPIMajor > 0, !kind.isEmpty, !runtime.isEmpty else { throw AppSDKError.invalidManifest }
        guard hostAPIMajor == supportedMajor else { throw AppSDKError.incompatibleHost }
        for path in [paths.state, paths.artifacts, paths.instances, paths.runs] {
            let parts = try components(path)
            guard parts.count >= 3, parts[0] == "apps", parts[1] == id else { throw AppSDKError.invalidPath }
        }
    }
}

/// Host-issued policy data. Never deserialize grants from an untrusted app as authority.
public struct AppFileGrant: Codable, Equatable, Sendable {
    public enum Access: String, Codable, Sendable { case read, readWrite }
    public let appID: String
    public let relativePath: String
    public let access: Access
    public init(appID: String, relativePath: String, access: Access) { self.appID = appID; self.relativePath = relativePath; self.access = access }
    func validate(for id: String) throws {
        let parts = try components(relativePath)
        guard validID(id), appID == id,
              (parts.count >= 2 && parts[0] == "apps" && parts[1] == id) || (parts.count >= 2 && parts[0] == "shared") else { throw AppSDKError.denied }
    }
}
