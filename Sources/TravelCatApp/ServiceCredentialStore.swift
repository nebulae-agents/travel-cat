import Foundation
import Security

@MainActor
protocol TravelServiceCredentialStoring {
    func read(id: String) throws -> String?
    func save(_ secret: String?, id: String) throws
}

protocol AsyncTravelServiceCredentialStoring: Sendable {
    func read(id: String) async throws -> String?
    func save(_ secret: String?, id: String) async throws
}

enum TravelServiceCredentialError: LocalizedError {
    case keychain(OSStatus), invalidData
    var errorDescription: String? {
        switch self {
        case .keychain: "无法访问系统钥匙串，请解锁钥匙串后重试。"
        case .invalidData: "钥匙串中的服务凭据无法读取，请重新填写。"
        }
    }
}

/// Implementations are confined to the caller's actor; CF values never cross it.
protocol TravelKeychainAccess {
    func copyMatching(_ query: CFDictionary, result: inout CFTypeRef?) -> OSStatus
    func add(_ attributes: CFDictionary) -> OSStatus
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

private struct SystemTravelKeychainAccess: TravelKeychainAccess {
    func copyMatching(_ query: CFDictionary, result: inout CFTypeRef?) -> OSStatus { SecItemCopyMatching(query, &result) }
    func add(_ attributes: CFDictionary) -> OSStatus { SecItemAdd(attributes, nil) }
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus { SecItemUpdate(query, attributes) }
    func delete(_ query: CFDictionary) -> OSStatus { SecItemDelete(query) }
}

private struct TravelKeychainCredentialOperations {
    let access: any TravelKeychainAccess
    let service: String
    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: id,
         kSecAttrSynchronizable as String: false]
    }
    func read(id: String) throws -> String? {
        try Task.checkCancellation()
        var attributes = query(id)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = access.copyMatching(attributes as CFDictionary, result: &result)
        // Authorization can finish after shutdown. A cancelled read must never become 'missing'.
        try Task.checkCancellation()
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw TravelServiceCredentialError.keychain(status) }
        guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else { throw TravelServiceCredentialError.invalidData }
        return secret
    }
    func save(_ secret: String?, id: String) throws {
        let match = query(id)
        try Task.checkCancellation()
        guard let secret, !secret.isEmpty else {
            let status = access.delete(match as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw TravelServiceCredentialError.keychain(status) }
            return
        }
        let updated: [String: Any] = [kSecValueData as String: Data(secret.utf8),
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = access.update(match as CFDictionary, attributes: updated as CFDictionary)
        if status == errSecItemNotFound {
            try Task.checkCancellation()
            status = access.add(match.merging(updated, uniquingKeysWith: { _, new in new }) as CFDictionary)
        }
        guard status == errSecSuccess else { throw TravelServiceCredentialError.keychain(status) }
    }
}

/// The synchronous facade is retained for existing generation services and injected fixtures.
@MainActor
final class KeychainTravelServiceCredentialStore: TravelServiceCredentialStoring {
    private let operations: TravelKeychainCredentialOperations
    init(service: String = "com.nebulae.travelcat.model-services") {
        operations = .init(access: SystemTravelKeychainAccess(), service: service)
    }
    init(access: any TravelKeychainAccess) {
        operations = .init(access: access, service: "com.nebulae.travelcat.model-services")
    }
    func read(id: String) throws -> String? { try operations.read(id: id) }
    func save(_ secret: String?, id: String) throws { try operations.save(secret, id: id) }
}

/// A separate actor keeps blocking Security authorization away from MainActor.
/// The factory creates non-Sendable Security access inside the worker, with no CF bridging.
actor AsyncKeychainTravelServiceCredentialStore: AsyncTravelServiceCredentialStoring {
    private let service: String
    private let makeAccess: @Sendable () -> any TravelKeychainAccess
    init(service: String) { self.service = service; makeAccess = { SystemTravelKeychainAccess() } }
    init(service: String, makeAccess: @escaping @Sendable () -> any TravelKeychainAccess) {
        self.service = service; self.makeAccess = makeAccess
    }
    func read(id: String) throws -> String? {
        try TravelKeychainCredentialOperations(access: makeAccess(), service: service).read(id: id)
    }
    func save(_ secret: String?, id: String) throws {
        try TravelKeychainCredentialOperations(access: makeAccess(), service: service).save(secret, id: id)
    }
}
