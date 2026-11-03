import Foundation
import CryptoKit
import Security
import Darwin

/// Copies only the official Codex keychain entry for managed per-instance CODEX_HOME.
/// Source entries remain intact. No credential bytes are persisted in files or diagnostics.
struct AgentXNativeCredentialMigration {
    enum Failure: Error { case unsafeProfile, conflict, keychain(OSStatus), readBack }
    let read: (String) throws -> Data?
    let insert: (String, Data) throws -> Void
    static func account(profile: URL) -> String {
        let canonical: String
        if let path = realpath(profile.path, nil) { canonical = String(cString: path); free(path) }
        else { canonical = profile.path }
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return "cli|" + digest.map { String(format: "%02x", $0) }.joined().prefix(16)
    }
    static var system: Self { Self(read: { account in
        var value: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: "Codex Auth", kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw Failure.keychain(status) }
        return data
    }, insert: { account, data in
        let status = SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: "Codex Auth", kSecAttrAccount: account, kSecValueData: data] as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }) }
    private static func validateAncestors(_ url: URL) throws {
        guard url.isFileURL, !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else { throw Failure.unsafeProfile }
        var cursor = URL(fileURLWithPath: "/")
        for component in url.path.split(separator: "/") {
            cursor.appendPathComponent(String(component))
            var information = stat()
            guard lstat(cursor.path, &information) == 0,
                  information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw Failure.unsafeProfile }
        }
        guard let pointer = realpath(url.path, nil) else { throw Failure.unsafeProfile }
        defer { free(pointer) }
        guard String(cString: pointer) == url.path else { throw Failure.unsafeProfile }
    }
    func migrate(from source: URL, to destination: URL) throws {
        let relative = "apps/workbench/state/runtime/native-runtime"
        let directory = source.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try Self.validateAncestors(directory)
        let profiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        var copies: [(String, Data)] = []
        for profile in profiles {
            guard UUID(uuidString: profile.lastPathComponent) != nil,
                  try profile.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw Failure.unsafeProfile }
            let target = destination.appendingPathComponent(relative).appendingPathComponent(profile.lastPathComponent)
            try Self.validateAncestors(profile)
            try Self.validateAncestors(target)
            let from = Self.account(profile: profile), to = Self.account(profile: target)
            guard let secret = try read(from) else { continue }
            if let existing = try read(to) {
                guard existing == secret else { throw Failure.conflict }
            } else { copies.append((to, secret)) }
        }
        for (account, data) in copies {
            try insert(account, data)
            guard try read(account) == data else { throw Failure.readBack }
        }
    }
}
