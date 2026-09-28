import Foundation
import Security
import XCTest
@testable import TravelCatApp

@MainActor
private final class FakeTravelKeychain: TravelKeychainAccess {
    var values: [String: Data] = [:]
    var failure: OSStatus?
    var lastAttributes: [String: Any] = [:]
    private func key(_ query: CFDictionary) -> String { (query as NSDictionary)[kSecAttrAccount] as! String }
    func copyMatching(_ query: CFDictionary, result: inout CFTypeRef?) -> OSStatus {
        if let failure { return failure }
        guard let value = values[key(query)] else { return errSecItemNotFound }
        result = value as CFData
        return errSecSuccess
    }
    func add(_ attributes: CFDictionary) -> OSStatus {
        lastAttributes = attributes as! [String: Any]
        values[key(attributes)] = lastAttributes[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        if let failure { return failure }
        guard values[key(query)] != nil else { return errSecItemNotFound }
        lastAttributes = attributes as! [String: Any]
        values[key(query)] = lastAttributes[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func delete(_ query: CFDictionary) -> OSStatus {
        if let failure { return failure }
        values.removeValue(forKey: key(query))
        return errSecSuccess
    }
}

final class ServiceCredentialStoreTests: XCTestCase {
    @MainActor func testKeychainAddUpdateReadDeleteWithInjectedAccess() throws {
        let fake = FakeTravelKeychain()
        let store = KeychainTravelServiceCredentialStore(access: fake)
        XCTAssertNil(try store.read(id: "one"))
        try store.save("test-secret", id: "one")
        XCTAssertEqual(fake.lastAttributes[kSecAttrService as String] as? String, "com.nebulae.travelcat.model-services")
        XCTAssertEqual(fake.lastAttributes[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(fake.lastAttributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(try store.read(id: "one"), "test-secret")
        try store.save("replacement", id: "one")
        XCTAssertEqual(try store.read(id: "one"), "replacement")
        XCTAssertNil(try store.read(id: "another-endpoint"))
        try store.save("", id: "one")
        XCTAssertNil(try store.read(id: "one"))
        try store.save(nil, id: "one")
        fake.failure = errSecAuthFailed
        XCTAssertThrowsError(try store.read(id: "one"))
        XCTAssertThrowsError(try store.save("private-secret", id: "one")) { error in
            XCTAssertFalse(error.localizedDescription.contains("private-secret"))
        }
    }
}
