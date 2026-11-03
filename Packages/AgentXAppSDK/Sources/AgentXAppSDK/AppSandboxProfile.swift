import Foundation

/// Produces policy only. The host must apply it before exec and fail closed on error.
public enum AppSandboxProfile {
    public static func generate(root: URL, appID: String, grants: [AppFileGrant]) throws -> String {
        // Validate root without silently following links, as the broker does.
        _ = try AppFileAccess(root: root, appID: appID, grants: grants)
        let runtimePaths = ["/System/Library", "/usr/lib", "/usr/bin", "/bin", "/private/var/db/dyld"]
        guard root.path != "/", !runtimePaths.contains(where: { root.path == $0 || root.path.hasPrefix($0 + "/") || $0.hasPrefix(root.path + "/") }) else { throw AppSDKError.denied }
        // A pathname sandbox cannot distinguish a hardlink from the original inode.
        // Validate the entire granted subtree before launch; the host must exclude
        // concurrent import/rename/link operations until the child exits.
        let manager = FileManager.default
        func check(_ url: URL) throws {
            let attributes = try manager.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            guard type == .typeDirectory || (type == .typeRegular && (attributes[.referenceCount] as? NSNumber)?.intValue == 1) else { throw AppSDKError.unsafeFile }
        }
        for grant in grants {
            var cursor = root
            for part in try components(grant.relativePath) {
                cursor.appendPathComponent(part)
                try check(cursor)
            }
            var enumerationError: Error?
            if let enumerator = manager.enumerator(at: cursor, includingPropertiesForKeys: nil, options: [], errorHandler: { _, error in
                enumerationError = error; return false
            }) {
                for case let child as URL in enumerator { try check(child) }
            }
            if let enumerationError { throw enumerationError }
        }
        func quoted(_ value: String) throws -> String {
            guard !value.unicodeScalars.contains(where: { $0.value < 32 }) else { throw AppSDKError.invalidPath }
            return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var lines = ["(version 1)", "(deny default)", "(import \"dyld-support.sb\")", "(deny network*)", "(allow process-exec)", "(allow process-fork)", "(allow sysctl-read)"]
        for path in runtimePaths { lines.append("(allow file-read* file-map-executable (subpath \(try quoted(path))))") }
        for grant in grants {
            let path = root.appendingPathComponent(grant.relativePath).path
            lines.append("(allow file-read* (subpath \(try quoted(path))))")
            if grant.access == .readWrite { lines.append("(allow file-write* (subpath \(try quoted(path))))") }
        }
        return lines.joined(separator: "\n")
    }
}
