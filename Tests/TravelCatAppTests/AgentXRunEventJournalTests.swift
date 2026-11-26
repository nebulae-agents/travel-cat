import Foundation
import XCTest
@testable import TravelCatApp

final class AgentXRunEventJournalTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func directory(_ root: URL) -> URL { root.appendingPathComponent("apps/alpha/events/run-journal") }

    private func base() -> [String: Any] {
        ["appID": "alpha", "id": "a", "revision": 0, "response": "legacy answer", "prompt": "legacy prompt",
         "legacyField": ["retain": true], "events": [], "auditOutbox": []]
    }

    private func next(_ old: [String: Any], revision: Int) -> [String: Any] {
        var result = old
        let event: [String: Any] = ["eventId": "a:\(revision)", "runId": "a", "revision": revision]
        result["revision"] = revision
        result["events"] = Array((old["events"] as? [[String: Any]] ?? []).suffix(63)) + [event]
        result["response"] = (old["response"] as? String ?? "") + "猫"
        result["auditOutbox"] = (old["auditOutbox"] as? [[String: Any]] ?? []) + [["eventId": "audit-\(revision)"]]
        return result
    }

    private func replay(_ root: URL) throws -> [String: [String: Any]] {
        try AgentXRunEventJournal(root: root, appID: "alpha").load {
            XCTFail("Imported legacy projections again")
            return [:]
        }
    }

    func testBootstrapRejectsWrongIdentityBeforeImportAndCanRetry() throws {
        let root = try fixture()
        let journal = try AgentXRunEventJournal(root: root, appID: "alpha")
        XCTAssertThrowsError(try journal.load { ["wrong-name": base()] })
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory(root).path))
        _ = try journal.load { ["a": base()] }
        XCTAssertEqual(try replay(root)["a"]?["response"] as? String, "legacy answer")
    }

    func testRotateReplayAndEncodeOnlyChanges() throws {
        let root = try fixture()
        let journal = try AgentXRunEventJournal(root: root, appID: "alpha")
        var fields = base()
        _ = try journal.load { ["a": fields] }
        for revision in 1...70 {
            let updated = next(fields, revision: revision)
            try journal.append(id: "a", previous: fields, fields: updated)
            fields = updated
        }
        let segments = try FileManager.default.contentsOfDirectory(at: directory(root), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.path < $1.path }
        XCTAssertEqual(segments.count, 2)
        let contents = try String(contentsOf: XCTUnwrap(segments.last), encoding: .utf8)
        XCTAssertFalse(contents.contains("legacy answer"))
        XCTAssertFalse(contents.contains("legacy prompt"))
        XCTAssertFalse(contents.contains("audit-64"))
        XCTAssertFalse(contents.contains(#""eventId":"a:64""#))
        XCTAssertEqual(contents.split(separator: "\n").count, 6)
        let restored = try XCTUnwrap(replay(root)["a"])
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: restored, options: [.sortedKeys]),
                       try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]))
    }

    func testInterruptedAppendAndRotationCanResumeButCommittedTruncationFailsClosed() throws {
        let root = try fixture()
        let original = base()
        let journal = try AgentXRunEventJournal(root: root, appID: "alpha")
        _ = try journal.load { ["a": original] }
        let first = next(original, revision: 1)
        try journal.append(id: "a", previous: original, fields: first)
        let segment = directory(root).appendingPathComponent("segment-00000001.jsonl")
        let committed = try Data(contentsOf: segment)
        let handle = try FileHandle(forWritingTo: segment)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"partial":"tail"#.utf8))
        try handle.close()
        let orphan = directory(root).appendingPathComponent("segment-00000002.jsonl")
        XCTAssertTrue(FileManager.default.createFile(atPath: orphan.path, contents: Data("partial".utf8), attributes: [.posixPermissions: 0o600]))
        let restarted = try AgentXRunEventJournal(root: root, appID: "alpha")
        let recovered = try restarted.load { XCTFail("reimported"); return [:] }
        XCTAssertEqual(recovered["a"]?["revision"] as? Int, 1)
        XCTAssertEqual(try Data(contentsOf: segment), committed)
        XCTAssertTrue(try Data(contentsOf: orphan).isEmpty)
        let second = next(first, revision: 2)
        try restarted.append(id: "a", previous: first, fields: second)
        XCTAssertEqual(try replay(root)["a"]?["revision"] as? Int, 2)

        let truncated = try FileHandle(forWritingTo: segment)
        try truncated.truncate(atOffset: UInt64(committed.count - 1))
        try truncated.close()
        let damaged = try AgentXRunEventJournal(root: root, appID: "alpha")
        XCTAssertThrowsError(try damaged.load { XCTFail("reimported"); return [:] })
        XCTAssertThrowsError(try damaged.append(id: "a", previous: second, fields: next(second, revision: 3)))
    }

    func testMigrationSealPreventsReimportWhenWholeJournalIsLost() throws {
        let root = try fixture()
        let journal = try AgentXRunEventJournal(root: root, appID: "alpha")
        let started = next(base(), revision: 1)
        _ = try journal.load { ["a": base()] }
        try journal.append(id: "a", previous: base(), fields: started)
        let marker = root.appendingPathComponent("apps/alpha/.run-journal-v1")
        // Crash between directory publication and seal publication finishes on reopen.
        try FileManager.default.removeItem(at: marker)
        XCTAssertEqual(try replay(root)["a"]?["revision"] as? Int, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        try FileManager.default.removeItem(at: directory(root))
        XCTAssertThrowsError(try replay(root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory(root).path))
    }

    func testRejectedAppendPreservesLastCommitAndAllowsValidRetry() throws {
        let root = try fixture()
        let journal = try AgentXRunEventJournal(root: root, appID: "alpha")
        _ = try journal.load { ["a": base()] }
        let first = next(base(), revision: 1)
        var invalid = first
        invalid["events"] = [["runId": "other", "eventId": "other:1", "revision": 1]]
        XCTAssertThrowsError(try journal.append(id: "a", previous: base(), fields: invalid))
        invalid = first
        invalid["isRead"] = ["wrong type"]
        XCTAssertThrowsError(try journal.append(id: "a", previous: base(), fields: invalid))
        try journal.append(id: "a", previous: base(), fields: first)
        XCTAssertEqual(try replay(root)["a"]?["revision"] as? Int, 1)
    }

    func testUnknownVersionAndChangedCommittedBytesFailClosed() throws {
        let root = try fixture()
        let journal = try AgentXRunEventJournal(root: root, appID: "alpha")
        let first = next(base(), revision: 1)
        _ = try journal.load { ["a": base()] }
        try journal.append(id: "a", previous: base(), fields: first)
        XCTAssertThrowsError(try journal.append(id: "a", previous: base(), fields: first))
        let segment = directory(root).appendingPathComponent("segment-00000001.jsonl")
        let row = try String(contentsOf: segment, encoding: .utf8)
        let mutated = row.replacingOccurrences(of: "audit-1", with: "audit-2")
        XCTAssertNotEqual(row, mutated)
        try Data(mutated.utf8).write(to: segment)
        XCTAssertThrowsError(try replay(root))
        try Data(row.utf8).write(to: segment)
        XCTAssertEqual(try replay(root)["a"]?["revision"] as? Int, 1)
        let head = directory(root).appendingPathComponent("head.json")
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: head)) as? [String: Any])
        fields["version"] = 2
        try JSONSerialization.data(withJSONObject: fields).write(to: head)
        XCTAssertThrowsError(try replay(root))
    }
}
