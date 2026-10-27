import Foundation
import XCTest
@testable import TravelStorage

final class RepositoryExportProgressTests: XCTestCase {
    private func fixture() throws -> (URL, TravelRepository, URL) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = try TravelRepository(root: parent.appendingPathComponent("data"))
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        return (parent, repository, parent.appendingPathComponent("backup"))
    }
    func testCancelReturnsImmediatelyWhileFinalPublicationIsSlow() {
        let control = RepositoryExportControl()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "publication finished")
        let cancelled = expectation(description: "cancel returned without waiting for disk")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            try? control.publish { entered.signal(); release.wait() }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async { control.cancel(); cancelled.fulfill() }
        wait(for: [cancelled], timeout: 0.3)
        release.signal()
        wait(for: [finished], timeout: 2)
    }
    func testCancelledChunkedExportRemovesStagingAndPreservesSource() throws {
        let (parent, repository, destination) = try fixture()
        let source = repository.root.appendingPathComponent("postcards/large.png")
        let original = Data(repeating: 42, count: 4 * 1024 * 1024)
        try original.write(to: source)
        let control = RepositoryExportControl()
        control.cancel()
        XCTAssertThrowsError(try repository.export(to: destination, control: control)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: parent.path).contains { $0.hasSuffix(".export.tmp") })
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testProgressCountsBytesAndFinalCommitWinsOverLateCancellation() throws {
        let (_, repository, destination) = try fixture()
        let source = repository.root.appendingPathComponent("postcards/large.png")
        let bytes = Data(repeating: 42, count: 2 * 1024 * 1024)
        try bytes.write(to: source)
        let readings = ProgressReadings()
        let control = RepositoryExportControl(progress: { readings.append($0) })
        _ = try repository.export(to: destination, control: control)
        control.cancel()
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("postcards/large.png")), bytes)
        let values = readings.values
        XCTAssertGreaterThan(values.count, 1)
        XCTAssertGreaterThanOrEqual(values.last?.copiedBytes ?? 0, Int64(bytes.count))
        XCTAssertGreaterThanOrEqual(values.last?.completedFiles ?? 0, 3)
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0.copiedBytes <= $1.copiedBytes && $0.completedFiles <= $1.completedFiles })
        XCTAssertNoThrow(try control.checkCancellation(), "A published backup is complete even if cancel arrives afterwards")
    }
    func testCancellationDuringCopyNeverPublishesPartialBackup() throws {
        let (parent, repository, destination) = try fixture()
        try Data(repeating: 8, count: 4 * 1024 * 1024).write(to: repository.root.appendingPathComponent("postcards/large.png"))
        let box = ControlBox()
        let control = RepositoryExportControl(minimumReportInterval: 0, progress: { if $0.copiedBytes >= 1024 * 1024 { box.value?.cancel() } })
        box.value = control
        XCTAssertThrowsError(try repository.export(to: destination, control: control)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: parent.path).contains { $0.hasSuffix(".export.tmp") })
    }
}
private final class ControlBox: @unchecked Sendable { weak var value: RepositoryExportControl? }
private final class ProgressReadings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RepositoryExportProgress] = []
    var values: [RepositoryExportProgress] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ value: RepositoryExportProgress) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
}
