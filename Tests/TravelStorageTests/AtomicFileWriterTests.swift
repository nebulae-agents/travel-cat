import Foundation
import XCTest
@testable import TravelStorage

final class AtomicFileWriterTests: XCTestCase {
    func testCreatesParentAndAtomicallyReplacesWithoutLeavingTemporaryFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtomicFileWriterTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("nested/value.json")
        let writer = AtomicFileWriter()

        try writer.write(Data("first".utf8), to: destination)
        try writer.write(Data("second".utf8), to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("second".utf8))
        let siblings = try FileManager.default.contentsOfDirectory(
            at: destination.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(siblings.map(\.lastPathComponent), ["value.json"])
    }

    func testReplacementFailurePreservesDestinationAndCleansTemporaryFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtomicFileWriterFailureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("existing", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: destination.appendingPathComponent("value"))

        XCTAssertThrowsError(try AtomicFileWriter().write(Data("replacement".utf8), to: destination))

        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("value")),
            Data("keep".utf8)
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path),
            ["existing"]
        )
    }
}
