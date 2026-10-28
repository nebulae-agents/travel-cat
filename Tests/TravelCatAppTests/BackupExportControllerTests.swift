import Foundation
import XCTest
import TravelStorage
@testable import TravelCatApp

@MainActor final class BackupExportControllerTests: XCTestCase {
    func testWorkerDoesNotBlockMainActorAndDuplicateRequestsAreRejected() async throws {
        let gate = ExportGate()
        let controller = BackupExportController(operation: { destination, control in
            gate.wait()
            try control.checkCancellation()
            return destination
        })
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(controller.start(to: destination))
        XCTAssertFalse(controller.start(to: destination))
        XCTAssertTrue(controller.isExporting)
        // This main-actor code must execute while the worker remains blocked.
        await Task.yield()
        XCTAssertNil(controller.message)
        controller.cancel()
        XCTAssertTrue(controller.cancellationRequested)
        gate.release()
        await controller.waitForCompletion()
        XCTAssertFalse(controller.isExporting)
        XCTAssertEqual(controller.message, "导出已取消，未发布备份；原始数据已保留。")
        XCTAssertTrue(controller.start(to: destination))
        await controller.waitForCompletion()
        XCTAssertEqual(controller.message, "备份已导出。")
    }
    func testUnsafeDestinationIsActionableAndDoesNotLeaveControllerBusy() async {
        let controller = BackupExportController(operation: { _, _ in throw RepositoryError.unsafeExportDestination })
        XCTAssertTrue(controller.start(to: URL(fileURLWithPath: "/unused")))
        await controller.waitForCompletion()
        XCTAssertFalse(controller.isExporting)
        XCTAssertEqual(controller.message, "请将导出位置选在 Travel Cat 数据目录之外，再重试导出。")
    }
}
private final class ExportGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    func wait() { condition.lock(); defer { condition.unlock() }; while !released { condition.wait() } }
    func release() { condition.lock(); defer { condition.unlock() }; released = true; condition.broadcast() }
}
