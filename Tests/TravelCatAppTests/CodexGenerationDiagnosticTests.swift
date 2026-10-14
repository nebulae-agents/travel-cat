import Foundation
import Darwin
import XCTest
@testable import TravelCatApp

final class CodexGenerationDiagnosticTests: XCTestCase {
    func testPersistenceDropsUnknownSensitiveFieldsAndKeepsOnlyLatest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("diagnostic.json")
        let store = CodexGenerationDiagnosticStore(fileURL: url)
        let first = CodexGenerationDiagnostic(code: .networkUnavailable, recordedAt: Date(), durationMilliseconds: 123, exitStatus: 256)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any])
        object["prompt"] = "PRIVATE DIARY TOKEN /private/path"
        try store.record(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(store.latest(), first)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("PRIVATE"))
        let next = CodexGenerationDiagnostic(code: .succeeded, recordedAt: Date(), durationMilliseconds: 1, exitStatus: 0)
        try store.record(next)
        XCTAssertEqual(CodexGenerationDiagnosticStore(fileURL: url).latest(), next)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertLessThan(try Data(contentsOf: url).count, 4096)
    }

    func testReadRejectsSymbolicLinkAndFIFO() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("actual.json")
        let diagnostic = CodexGenerationDiagnostic(code: .succeeded, recordedAt: Date(), durationMilliseconds: 0, exitStatus: 0)
        try CodexGenerationDiagnosticStore(fileURL: actual).record(diagnostic)
        let linked = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: actual)
        XCTAssertNil(CodexGenerationDiagnosticStore(fileURL: linked).latest())
        let fifo = root.appendingPathComponent("pipe.json")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertNil(CodexGenerationDiagnosticStore(fileURL: fifo).latest())
    }

    func testRejectsRawLogsAndOversizeRecordsWithoutReplacingPreviousSummary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CodexGenerationDiagnosticStore(fileURL: root.appendingPathComponent("diagnostic.json"))
        let diagnostic = CodexGenerationDiagnostic(code: .notLoggedIn, recordedAt: Date(), durationMilliseconds: 0, exitStatus: nil)
        try store.record(diagnostic)
        XCTAssertThrowsError(try store.record(Data("raw secret log".utf8)))
        XCTAssertThrowsError(try store.record(Data(repeating: 32, count: 4097)))
        XCTAssertEqual(store.latest(), diagnostic)
    }
}
