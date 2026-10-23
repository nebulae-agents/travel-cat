import CryptoKit
import Foundation
import XCTest
@testable import TravelCatApp

final class AgentDraftStorageTests: XCTestCase {
    private let key = Data(repeating: 42, count: 32)
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func record(kind: String = "new", id: UUID? = UUID(), text: String = "private-draft-canary", files: [[String: String]] = []) -> [String: Any] {
        var target: [String: Any] = ["kind": kind]
        if let id { target["id"] = id.uuidString }
        return ["target": target, "draft": ["text": text, "files": files, "revision": UUID().uuidString, "parentTaskID": UUID().uuidString]]
    }
    private func bytes(_ records: [[String: Any]]) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(WorkbenchSnapshot())) as? [String: Any])
        object["drafts"] = records
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    func testEncryptedRoundTripPreservesEveryDraftFieldAndOriginalAttachmentBytes() throws {
        let root = try directory(), store = WorkbenchStore(root: root, keyData: key)
        let files = [["name": "input.bin", "base64": Data([0, 255, 1, 13, 10]).base64EncodedString()]]
        let records = [record(files: files), record(kind: "task"), record(id: nil)]
        let original = try bytes(records)
        try EncryptedWorkbenchStorage(root: root, keyData: key).save(original)
        let recovered = try store.load()
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(recovered)) as? [String: Any])
        let restored = try XCTUnwrap(encoded["drafts"] as? [[String: Any]])
        func sorted(_ source: [[String: Any]]) throws -> [String] { try source.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }.sorted() }
        XCTAssertEqual(try sorted(restored), try sorted(records))
        let sealed = try Data(contentsOf: store.url)
        XCTAssertNil(sealed.range(of: Data("private-draft-canary".utf8)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.legacyURL.path))
    }
    func testInvalidDraftsCannotReplaceExistingCiphertext() throws {
        let root = try directory(), store = WorkbenchStore(root: root, keyData: key)
        try store.save(WorkbenchSnapshot())
        let sealed = try Data(contentsOf: store.url)
        var duplicate = record(); duplicate["draft"] = record(text: "different")["draft"]
        let original = record()
        duplicate["target"] = original["target"]
        let invalidFiles: [[[String: String]]] = [
            [["name": "ok", "base64": "%%%"]], [["name": "../escape", "base64": ""]],
            [["name": "secret.txt", "base64": ""]], [["name": "a\0b", "base64": ""]],
            [["name": ".hidden", "base64": ""]], [["name": "a\\b", "base64": ""]],
            [["name": String(repeating: "字", count: 67), "base64": ""]],
            [["name": "same", "base64": ""], ["name": "same", "base64": ""]],
            [["name": "bad", "base64": "YQ==\n"]]
        ]
        var batches = try invalidFiles.map { try bytes([record(files: $0)]) }
        batches += [try bytes([original, duplicate]), try bytes([record(kind: "future")]), try bytes([record(kind: "task", id: nil)]), try bytes([record(text: String(repeating: "x", count: 100_001))]), try bytes([record(text: String(repeating: "👨‍👩‍👧‍👦", count: 22_000))])]
        for invalid in batches {
            XCTAssertThrowsError(try EncryptedWorkbenchStorage(root: root, keyData: key).save(invalid))
            XCTAssertEqual(try Data(contentsOf: store.url), sealed)
        }
    }
    func testInvalidLegacyDraftNeverMigratesOrSilentlyRewritesOriginal() throws {
        let root = try directory(), store = WorkbenchStore(root: root, keyData: key)
        let invalid = try bytes([record(files: [["name": "input", "base64": "!"]])])
        try invalid.write(to: store.legacyURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.legacyURL), invalid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }
    func testDraftFileLimitsAreEnforcedBeforeReplacingCiphertext() throws {
        let root = try directory(), store = WorkbenchStore(root: root, keyData: key)
        try store.save(WorkbenchSnapshot())
        let sealed = try Data(contentsOf: store.url)
        let big = Data(repeating: 1, count: 1024 * 1024).base64EncodedString()
        let tooBig = Data(repeating: 1, count: 1024 * 1024 + 1).base64EncodedString()
        let batches = [Array(repeating: ["name": "a", "base64": ""], count: 33), [["name": "a", "base64": tooBig]], (0..<5).map { ["name": "a\($0)", "base64": big] }]
        for files in batches {
            XCTAssertThrowsError(try EncryptedWorkbenchStorage(root: root, keyData: key).save(bytes([record(files: files)])))
            XCTAssertEqual(try Data(contentsOf: store.url), sealed)
        }
    }
    func testSchemaOneWithoutDraftsStillLoads() throws {
        let root = try directory(), store = WorkbenchStore(root: root, keyData: key)
        try store.save(WorkbenchSnapshot())
        XCTAssertEqual(try store.load().schemaVersion, 1)
    }
    func testMalformedAuthenticatedCiphertextBlocksLoadAndSaveWithoutRewriting() throws {
        let root = try directory(), store = WorkbenchStore(root: root, keyData: key)
        let invalid = try bytes([record(), record(kind: "task", id: nil)])
        let header = Data("TCWB1\0".utf8)
        let box = try AES.GCM.seal(invalid, using: SymmetricKey(data: key), authenticating: header)
        let ciphertext = header + (try XCTUnwrap(box.combined))
        try ciphertext.write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(WorkbenchSnapshot()))
        XCTAssertEqual(try Data(contentsOf: store.url), ciphertext)
    }
    func testExactAttachmentBoundariesRoundTripWithoutChangingBase64() throws {
        let root = try directory(), store = WorkbenchStore(root: root, keyData: key)
        let encoded = Data(repeating: 255, count: 1024 * 1024).base64EncodedString()
        let files = (0..<4).map { ["name": String(repeating: "a", count: 199) + String($0), "base64": encoded] }
        try EncryptedWorkbenchStorage(root: root, keyData: key).save(bytes([record(text: String(repeating: "x", count: 100_000), files: files)]))
        let snapshot = try store.load()
        XCTAssertNotNil(snapshot.drafts)
        try store.save(snapshot)
        let restored = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(store.load())) as? [String: Any])
        let records = try XCTUnwrap(restored["drafts"] as? [[String: Any]])
        let draft = try XCTUnwrap(records.first?["draft"] as? [String: Any])
        XCTAssertEqual(draft["files"] as? [[String: String]], files)
        XCTAssertEqual((draft["text"] as? String)?.count, 100_000)
    }

}
