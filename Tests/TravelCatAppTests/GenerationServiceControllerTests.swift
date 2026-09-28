import Foundation
import XCTest
import TravelStorage
@testable import TravelCatApp

@MainActor
private final class MemoryGenerationCredentials: TravelServiceCredentialStoring {
    var values: [String: String] = [:]
    var failOnSecret: String?
    var reads = 0
    func read(id: String) throws -> String? { reads += 1; return values[id] }
    func save(_ secret: String?, id: String) throws {
        if let secret, secret == failOnSecret { throw CocoaError(.fileWriteUnknown) }
        values[id] = secret.flatMap { $0.isEmpty ? nil : $0 }
    }
}

final class GenerationServiceControllerTests: XCTestCase {
    @MainActor func testFirstLaunchGateAndHistoryCompatibilityDoNotWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = TravelGenerationConfigurationStore(root: root)
        let keys = MemoryGenerationCredentials()
        let fresh = try GenerationServiceController(store: store, credentials: keys, hasExistingHistory: false)
        XCTAssertFalse(fresh.isReady)
        let old = try GenerationServiceController(store: store, credentials: keys, hasExistingHistory: true)
        XCTAssertTrue(old.isReady)
        XCTAssertEqual(keys.reads, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.configurationURL.path))
    }

    @MainActor func testEndpointChangeRequiresExplicitCredentialChoiceAndDoesNotLeak() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TravelGenerationConfigurationStore(root: root)
        let keys = MemoryGenerationCredentials()
        let controller = try GenerationServiceController(store: store, credentials: keys, hasExistingHistory: false)
        var candidate = controller.configuration
        candidate.narrative = .init(kind: .openAICompatible, baseURL: "https://first.example/v1", model: "text")
        try controller.save(candidate, narrativeSecret: "original", imageSecret: nil)
        let original = controller.configuration
        candidate = original
        candidate.narrative.baseURL = "https://other.example/v1"
        XCTAssertThrowsError(try controller.save(candidate, narrativeSecret: "  ", imageSecret: nil))
        XCTAssertEqual(controller.configuration, original)
        XCTAssertEqual(keys.values, [original.narrative.credentialID: "original"])
        try controller.save(candidate, narrativeSecret: nil, imageSecret: nil, narrativeNoKey: true)
        XCTAssertNotEqual(controller.configuration.narrative.credentialID, original.narrative.credentialID)
        XCTAssertNil(keys.values[controller.configuration.narrative.credentialID])
        XCTAssertEqual(keys.values[original.narrative.credentialID], "original")
        XCTAssertEqual(keys.reads, 0)
    }

    @MainActor func testUnchangedEndpointRetainsCredentialIgnoringCandidateID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = MemoryGenerationCredentials()
        let controller = try GenerationServiceController(store: .init(root: root), credentials: keys, hasExistingHistory: false)
        var candidate = controller.configuration
        candidate.narrative = .init(kind: .openAICompatible, baseURL: "http://localhost:8181/v1", model: "text")
        try controller.save(candidate, narrativeSecret: "original", imageSecret: nil)
        let id = controller.configuration.narrative.credentialID
        candidate = controller.configuration
        candidate.narrative.credentialID = UUID().uuidString
        candidate.narrative.model = "another-model"
        try controller.save(candidate, narrativeSecret: nil, imageSecret: nil)
        XCTAssertEqual(controller.configuration.narrative.credentialID, id)
        XCTAssertEqual(keys.values[id], "original")
    }

    @MainActor func testFailedPersistenceRollsBackNewKeysAndKeepsPublishedState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var failWrite = false
        let store = TravelGenerationConfigurationStore(root: root, writeConfiguration: { data, url in
            if failWrite { throw CocoaError(.fileWriteUnknown) }
            try AtomicFileWriter().write(data, to: url)
        })
        let keys = MemoryGenerationCredentials()
        var saves = 0
        let controller = try GenerationServiceController(store: store, credentials: keys, hasExistingHistory: true, didSave: { saves += 1 })
        var candidate = controller.configuration
        candidate.narrative = .init(kind: .openAICompatible, model: "text")
        try controller.save(candidate, narrativeSecret: "original", imageSecret: nil)
        let original = controller.configuration
        failWrite = true
        candidate = original
        XCTAssertThrowsError(try controller.save(candidate, narrativeSecret: "replacement", imageSecret: nil))
        XCTAssertEqual(controller.configuration, original)
        XCTAssertEqual(keys.values, [original.narrative.credentialID: "original"])
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(try store.load(hasExistingHistory: true), original)
    }

    @MainActor func testSecondKeyFailureRollsBackFirstAndValidationPrecedesKeys() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = MemoryGenerationCredentials()
        let controller = try GenerationServiceController(store: .init(root: root), credentials: keys, hasExistingHistory: false)
        let original = controller.configuration
        var candidate = original
        candidate.narrative = .init(kind: .openAICompatible, model: "text")
        candidate.image = .init(kind: .openAICompatible, model: "")
        XCTAssertThrowsError(try controller.save(candidate, narrativeSecret: "first", imageSecret: "second"))
        XCTAssertTrue(keys.values.isEmpty)
        candidate.image.model = "image"
        keys.failOnSecret = "second"
        XCTAssertThrowsError(try controller.save(candidate, narrativeSecret: "first", imageSecret: "second"))
        XCTAssertTrue(keys.values.isEmpty)
        XCTAssertEqual(controller.configuration, original)
    }
    @MainActor func testPublishedThenThrownSaveKeepsNewCredentialAndPublishesSuccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TravelGenerationConfigurationStore(root: root, writeConfiguration: { data, url in
            try AtomicFileWriter().write(data, to: url)
            throw CocoaError(.fileWriteUnknown)
        })
        let keys = MemoryGenerationCredentials()
        var saves = 0
        let controller = try GenerationServiceController(store: store, credentials: keys, hasExistingHistory: false, didSave: { saves += 1 })
        var candidate = controller.configuration
        candidate.narrative = .init(kind: .openAICompatible, model: "text")
        try controller.save(candidate, narrativeSecret: "new-secret", imageSecret: nil)
        XCTAssertTrue(controller.isReady)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(try store.load(hasExistingHistory: false), controller.configuration)
        XCTAssertEqual(keys.values[controller.configuration.narrative.credentialID], "new-secret")
    }

    @MainActor func testUnknownDiskStateRetainsNewCredentialAndReturnsSafeError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TravelGenerationConfigurationStore(root: root, writeConfiguration: { _, url in
            try AtomicFileWriter().write(Data("unreadable config".utf8), to: url)
            throw NSError(domain: "secret-sensitive-error", code: 7)
        })
        let keys = MemoryGenerationCredentials()
        let controller = try GenerationServiceController(store: store, credentials: keys, hasExistingHistory: false)
        let original = controller.configuration
        var candidate = original
        candidate.narrative = .init(kind: .openAICompatible, model: "text")
        XCTAssertThrowsError(try controller.save(candidate, narrativeSecret: "new-secret", imageSecret: nil)) { error in
            XCTAssertFalse(error.localizedDescription.contains("secret-sensitive-error"))
        }
        XCTAssertEqual(controller.configuration, original)
        XCTAssertEqual(Array(keys.values.values), ["new-secret"])
    }

    @MainActor func testFirstWriteFailureWithoutPublishedFileRollsBackNewKeys() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TravelGenerationConfigurationStore(root: root, writeConfiguration: { _, _ in
            throw CocoaError(.fileWriteUnknown)
        })
        let keys = MemoryGenerationCredentials()
        let controller = try GenerationServiceController(store: store, credentials: keys, hasExistingHistory: false)
        let original = controller.configuration
        var candidate = original
        candidate.narrative = .init(kind: .openAICompatible, model: "text")
        XCTAssertThrowsError(try controller.save(candidate, narrativeSecret: "unpublished", imageSecret: nil))
        XCTAssertEqual(controller.configuration, original)
        XCTAssertTrue(keys.values.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.configurationURL.path))
    }

    @MainActor func testDanglingConfigurationSymlinkDoesNotCountAsConfirmedAbsence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TravelGenerationConfigurationStore(root: root, writeConfiguration: { _, url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: root.appendingPathComponent("missing-target"))
            throw CocoaError(.fileWriteUnknown)
        })
        let keys = MemoryGenerationCredentials()
        let controller = try GenerationServiceController(store: store, credentials: keys, hasExistingHistory: false)
        var candidate = controller.configuration
        candidate.narrative = .init(kind: .openAICompatible, model: "text")
        XCTAssertThrowsError(try controller.save(candidate, narrativeSecret: "preserved", imageSecret: nil)) { error in
            XCTAssertTrue(error is GenerationServicePersistenceError)
        }
        XCTAssertEqual(Array(keys.values.values), ["preserved"])
    }

}
