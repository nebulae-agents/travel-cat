import Foundation
import Security
import XCTest
@testable import TravelCatApp

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

private final class WorkerKeychainAccess: TravelKeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var threads: [Bool] = []
    private var attributes: [String: Any] = [:]
    func observedMainThreads() -> [Bool] { lock.lock(); defer { lock.unlock() }; return threads }
    func observedAttributes() -> [String: Any] { lock.lock(); defer { lock.unlock() }; return attributes }
    private func account(_ query: CFDictionary) -> String { (query as NSDictionary)[kSecAttrAccount] as! String }
    func copyMatching(_ query: CFDictionary, result: inout CFTypeRef?) -> OSStatus {
        lock.lock(); defer { lock.unlock() }; threads.append(Thread.isMainThread)
        guard let data = values[account(query)] else { return errSecItemNotFound }
        result = data as CFData; return errSecSuccess
    }
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        lock.lock(); defer { lock.unlock() }; threads.append(Thread.isMainThread)
        guard values[account(query)] != nil else { return errSecItemNotFound }
        self.attributes = attributes as! [String: Any]
        values[account(query)] = self.attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func add(_ attributes: CFDictionary) -> OSStatus {
        lock.lock(); defer { lock.unlock() }; threads.append(Thread.isMainThread)
        self.attributes = attributes as! [String: Any]
        values[account(attributes)] = self.attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func delete(_ query: CFDictionary) -> OSStatus {
        lock.lock(); defer { lock.unlock() }; threads.append(Thread.isMainThread)
        values.removeValue(forKey: account(query)); return errSecSuccess
    }
}
extension ServiceCredentialStoreTests {
    @MainActor func testAsyncKeychainReadSaveDeleteRunOutsideMainActorWithUnchangedAttributes() async throws {
        let access = WorkerKeychainAccess()
        let store = AsyncKeychainTravelServiceCredentialStore(service: "com.nebulae.travelcat.agent-content", makeAccess: { access })
        try await store.save("worker-key", id: "workbench-content-v1")
        let read = try await store.read(id: "workbench-content-v1")
        XCTAssertEqual(read, "worker-key")
        let attributes = access.observedAttributes()
        XCTAssertEqual(attributes[kSecAttrService as String] as? String, "com.nebulae.travelcat.agent-content")
        XCTAssertEqual(attributes[kSecAttrAccount as String] as? String, "workbench-content-v1")
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        try await store.save(nil, id: "workbench-content-v1")
        let deleted = try await store.read(id: "workbench-content-v1")
        XCTAssertNil(deleted)
        let threads = access.observedMainThreads()
        XCTAssertFalse(threads.isEmpty)
        XCTAssertFalse(threads.contains(true))
    }
}
