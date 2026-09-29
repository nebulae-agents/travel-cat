import Foundation
import Security

@MainActor
protocol TravelServiceCredentialStoring {
    func read(id: String) throws -> String?
    func save(_ secret: String?, id: String) throws
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

/// Injectable boundary keeps unit tests away from the user's real keychain.
@MainActor
protocol TravelKeychainAccess {
    func copyMatching(_ query: CFDictionary, result: inout CFTypeRef?) -> OSStatus
    func add(_ attributes: CFDictionary) -> OSStatus
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

@MainActor
private struct SystemTravelKeychainAccess: TravelKeychainAccess {
    func copyMatching(_ query: CFDictionary, result: inout CFTypeRef?) -> OSStatus {
        SecItemCopyMatching(query, &result)
    }
    func add(_ attributes: CFDictionary) -> OSStatus { SecItemAdd(attributes, nil) }
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus { SecItemUpdate(query, attributes) }
    func delete(_ query: CFDictionary) -> OSStatus { SecItemDelete(query) }
}

@MainActor
final class KeychainTravelServiceCredentialStore: TravelServiceCredentialStoring {
    private let access: any TravelKeychainAccess

    init() { access = SystemTravelKeychainAccess() }
    init(access: any TravelKeychainAccess) { self.access = access }

    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.nebulae.travelcat.model-services",
         kSecAttrAccount as String: id,
         kSecAttrSynchronizable as String: false]
    }

    func read(id: String) throws -> String? {
        var attributes = query(id)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = access.copyMatching(attributes as CFDictionary, result: &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw TravelServiceCredentialError.keychain(status) }
        guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw TravelServiceCredentialError.invalidData
        }
        return secret
    }

    func save(_ secret: String?, id: String) throws {
        let match = query(id)
        guard let secret, !secret.isEmpty else {
            let status = access.delete(match as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw TravelServiceCredentialError.keychain(status)
            }
            return
        }
        let updated: [String: Any] = [kSecValueData as String: Data(secret.utf8),
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = access.update(match as CFDictionary, attributes: updated as CFDictionary)
        if status == errSecItemNotFound {
            status = access.add(match.merging(updated, uniquingKeysWith: { _, new in new }) as CFDictionary)
        }
        guard status == errSecSuccess else { throw TravelServiceCredentialError.keychain(status) }
    }
}
