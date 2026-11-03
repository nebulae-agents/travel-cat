import Foundation
import XCTest
import AgentXAppSDK
@testable import TravelCatApp

final class AgentXOfflineAppLifecycleTests: XCTestCase {
    func fixture() throws -> (URL, AgentXOfflineAppLifecycle) {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("OfflineApp-\(UUID())")
        let root = base.appendingPathComponent("root")
        try AgentXRepository(root: root).save(AgentXState())
        let queue = AgentXOfflineAppLifecycle(root: root, locator: base.appendingPathComponent("host/root-location.json"))
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return (base, queue)
    }
    func baseline() -> AppManifest {
        AppManifest(id: "blackcat", name: "BlackCat", version: "2026.11", dataSchemaVersion: 1, hostAPIMajor: 1, kind: "blackcat", runtime: "native", modules: ["travel"])
    }
    func exitedReceipt(_ queue: AgentXOfflineAppLifecycle) throws {
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run(); child.waitUntilExit()
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: queue.requestURL)) as? [String: Any])
        let receipt = try JSONSerialization.data(withJSONObject: ["requestID": try XCTUnwrap(request["id"]), "processID": child.processIdentifier])
        try receipt.write(to: queue.exitReceiptURL, options: .atomic)
    }
    func testRequestDoesNotMutateRootAndCannotApplyBeforeRealPriorProcessExit() throws {
        let (base, queue) = try fixture()
        let manifestFile = base.appendingPathComponent("root/apps/blackcat/manifest.json")
        try queue.request(.register(appID: "blackcat", manifest: baseline()))
        XCTAssertTrue(queue.hasPendingOperation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestFile.path))
        XCTAssertThrowsError(try queue.applyPending(writersHaveStopped: { true }))
        try queue.recordCleanChildExit()
        XCTAssertFalse(queue.previousHostHasExited())
        XCTAssertThrowsError(try queue.applyPending(writersHaveStopped: { true }))
        try exitedReceipt(queue)
        XCTAssertTrue(queue.previousHostHasExited())
        XCTAssertThrowsError(try queue.applyPending(writersHaveStopped: { false }))
        let result = try XCTUnwrap(queue.applyPending(writersHaveStopped: { true }))
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestFile.path))
        XCTAssertFalse(queue.hasPendingOperation)
    }
    func testRevokeAndSourceRootMismatchPreventApplyAndInterruptedRequestDoesNotReplay() throws {
        let (base, queue) = try fixture()
        try queue.request(.register(appID: "blackcat", manifest: baseline()))
        try exitedReceipt(queue)
        try queue.revokeExitReceipt()
        XCTAssertFalse(queue.previousHostHasExited())
        try exitedReceipt(queue)
        let other = AgentXOfflineAppLifecycle(root: base.appendingPathComponent("other-root"), locator: base.appendingPathComponent("host/root-location.json"))
        XCTAssertThrowsError(try other.applyPending(writersHaveStopped: { true }))
        var request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: queue.requestURL)) as? [String: Any])
        request["phase"] = "applying"
        try JSONSerialization.data(withJSONObject: request).write(to: queue.requestURL)
        let result = try XCTUnwrap(queue.applyPending(writersHaveStopped: { true }))
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("root/apps/blackcat/manifest.json").path))
        XCTAssertFalse(queue.hasPendingOperation)
    }
    func testCompletedUpgradePersistsReceiptForLaterOfflineRollback() throws {
        let (base, queue) = try fixture()
        let root = base.appendingPathComponent("root")
        let host = try AgentXAppLifecycleHost(root: root, hostAPIMajor: 1, writersHaveStopped: { true })
        try host.register(appID: "blackcat", manifest: baseline())
        let package = base.appendingPathComponent("package")
        try host.exportPackage(appID: "blackcat", to: package)
        var next = baseline(); next.version = "2026.12"; next.name = "BlackCat Next"
        try JSONEncoder().encode(next).write(to: package.appendingPathComponent("manifest.json"))
        try queue.request(.upgrade(appID: "blackcat", source: package.path))
        try exitedReceipt(queue)
        let upgraded = try XCTUnwrap(queue.applyPending(writersHaveStopped: { true }))
        let receipt = try XCTUnwrap(upgraded.rollbackReceipt)
        XCTAssertNotNil(try queue.latestResult()?.rollbackReceipt)
        try queue.request(.rollback(receipt))
        try exitedReceipt(queue)
        XCTAssertTrue(try XCTUnwrap(queue.applyPending(writersHaveStopped: { true })).succeeded)
        XCTAssertEqual(try AgentXRepository(root: root).load().apps.first?.name, "BlackCat")
    }
    func testRootMigrationAndAppOperationCannotBeQueuedTogether() throws {
        let (base, queue) = try fixture()
        let storage = AgentXHostStorage(root: base.appendingPathComponent("root"), hostDirectory: base.appendingPathComponent("host"))
        try storage.requestMigration(to: base.appendingPathComponent("moved"))
        XCTAssertThrowsError(try queue.request(.register(appID: "blackcat", manifest: baseline())))
        XCTAssertFalse(queue.hasPendingOperation)
        XCTAssertTrue(storage.hasPendingMigration)
    }

}
