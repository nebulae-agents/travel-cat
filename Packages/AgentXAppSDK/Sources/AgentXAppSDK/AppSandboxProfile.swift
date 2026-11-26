import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Produces policy only. The host must apply it before exec and fail closed on error.
public enum AppSandboxProfile {
    public static func generate(root: URL, appID: String, grants: [AppFileGrant], runtimeFiles: [URL] = [], runtimeDirectories: [URL] = [], loopbackPort: UInt16? = nil) throws -> String {
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
        func canonical(_ url: URL) throws -> String {
            guard let pointer = realpath(url.path, nil) else { throw AppSDKError.invalidPath }
            defer { free(pointer) }
            return String(cString: pointer)
        }
        // Host-selected runtime assets are read-only. Never grant an application root
        // through this channel: all mutable data stays subject to file grants above.
        // Node resolves its executable/script/module path one ancestor at a time.
        // Grant only metadata on those ancestors, never directory contents or data.
        var ancestors = Set<String>()
        for resource in runtimeFiles + runtimeDirectories where FileManager.default.fileExists(atPath: resource.path) {
            for path in [resource, URL(fileURLWithPath: try canonical(resource))] {
                ancestors.insert(path.path)
                var cursor = path.deletingLastPathComponent()
                while cursor.path != "/" {
                    ancestors.insert(cursor.path); cursor.deleteLastPathComponent()
                }
                ancestors.insert("/")
            }
        }
        for path in ancestors.sorted() {
            lines.append("(allow file-read-metadata (literal \(try quoted(path))))")
        }
        for file in runtimeFiles {
            lines.append("(allow file-read* file-map-executable (literal \(try quoted(canonical(file)))))")
        }
        for directory in runtimeDirectories where FileManager.default.fileExists(atPath: directory.path) {
            lines.append("(allow file-read* file-map-executable (subpath \(try quoted(canonical(directory)))))")
        }
        lines.append("(allow file-read* file-write* (literal \"/dev/null\"))")
        lines.append("(allow file-read* (literal \"/dev/zero\") (literal \"/dev/urandom\"))")
        if let port = loopbackPort, port > 0 {
            lines.append("(allow network-outbound (remote tcp4 \"localhost:\(port)\"))")
        }
        return lines.joined(separator: "\n")
    }
}
