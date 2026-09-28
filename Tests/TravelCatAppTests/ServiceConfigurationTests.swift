import Foundation
import XCTest
@testable import TravelCatApp

final class ServiceConfigurationTests: XCTestCase {
    func testNewAndExistingHistoryDefaultsDoNotWriteOnLoad() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = TravelGenerationConfigurationStore(root: root)
        let fresh = try store.load(hasExistingHistory: false)
        XCTAssertFalse(fresh.onboardingCompleted)
        XCTAssertNotEqual(fresh.narrative.credentialID, fresh.image.credentialID)
        let existing = try store.load(hasExistingHistory: true)
        XCTAssertTrue(existing.onboardingCompleted)
        XCTAssertEqual(existing.narrative.kind, .codex)
        XCTAssertEqual(existing.image.kind, .codex)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.configurationURL.path))
    }

    func testRoundTripDraftAndCompletedValidation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TravelGenerationConfigurationStore(root: root)
        var draft = TravelGenerationConfiguration()
        draft.narrative = .init(kind: .openAICompatible, baseURL: "unfinished", model: "")
        try store.save(draft)
        XCTAssertEqual(try store.load(hasExistingHistory: false), draft)
        draft.onboardingCompleted = true
        XCTAssertThrowsError(try store.save(draft))
        draft.narrative.baseURL = "https://example.com/v1"
        draft.narrative.model = "test-model"
        try store.save(draft)
        XCTAssertEqual(try store.load(hasExistingHistory: false), draft)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.configurationURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.configurationURL)) as? [String: Any])
        let narrative = try XCTUnwrap(json["narrative"] as? [String: Any])
        XCTAssertEqual(Set(narrative.keys), Set(["kind", "baseURL", "model", "credentialID", "jsonMode", "useImageEdits"]))
        draft.schemaVersion = 2
        XCTAssertThrowsError(try store.save(draft))
    }

    func testSafeAndUnsafeEndpoints() throws {
        for address in ["https://example.com/v1", "http://localhost:1234/v1", "http://127.0.0.1/v1", "http://127.42.1.2/v1", "http://[::1]:8080/v1"] {
            XCTAssertNoThrow(try TravelServiceConfiguration(baseURL: address).validatedBaseURL(), address)
        }
        for address in ["http://example.com", "http://localhost.evil.test", "http://127.1", "http://127.00.0.1", "http://0.0.0.0", "https://user:secret@example.com", "https://example.com?key=secret", "https://example.com#secret", "file:///tmp/a", "https:///", " https://example.com", "https://example.com:0"] {
            XCTAssertThrowsError(try TravelServiceConfiguration(baseURL: address).validatedBaseURL(), address)
        }
        XCTAssertThrowsError(try TravelServiceConfiguration(kind: .openAICompatible, model: " \n").validate())
    }
}
