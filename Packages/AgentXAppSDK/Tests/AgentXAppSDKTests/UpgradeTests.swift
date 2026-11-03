import Foundation
import XCTest
@testable import AgentXAppSDK

final class UpgradeTests: XCTestCase {
    func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        for path in ["apps/a/state", "apps/a/payload", "apps/b", "shared", "manager", "package/payload"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        for path in ["apps/a/state/user", "apps/b/user", "shared/user", "manager/user"] {
            try Data(path.utf8).write(to: root.appendingPathComponent(path))
        }
        try Data("old".utf8).write(to: root.appendingPathComponent("apps/a/payload/code"))
        try Data("new".utf8).write(to: root.appendingPathComponent("package/payload/code"))
        try manifest(version: "1").write(to: root.appendingPathComponent("apps/a/manifest.json"))
        try manifest(version: "2").write(to: root.appendingPathComponent("package/manifest.json"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func manifest(version: String, schema: Int = 1, host: Int = 1) throws -> Data {
        try JSONEncoder().encode(AppManifest(id: "a", name: "A", version: version, dataSchemaVersion: schema, hostAPIMajor: host, kind: "utility", runtime: "native", modules: []))
    }
    func testUpgradePreservesDataAndOtherAppsAndRollbackRestoresSnapshot() throws {
        let root = try fixture()
        let manager = try AppUpgradeManager(root: root, hostAPIMajor: 1)
        let receipt = try manager.upgrade(appID: "a", package: root.appendingPathComponent("package"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("apps/a/payload/code")), Data("new".utf8))
        for path in ["apps/a/state/user", "apps/b/user", "shared/user", "manager/user"] {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data(path.utf8))
        }
        try manager.rollback(receipt)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("apps/a/payload/code")), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("apps/a/state/user")), Data("apps/a/state/user".utf8))
    }
    func testSchemaRequiresExplicitMigrationAndFailureLeavesLiveDataUnchanged() throws {
        let root = try fixture(); let manager = try AppUpgradeManager(root: root, hostAPIMajor: 1)
        try manifest(version: "2", schema: 2).write(to: root.appendingPathComponent("package/manifest.json"))
        XCTAssertThrowsError(try manager.upgrade(appID: "a", package: root.appendingPathComponent("package")))
        XCTAssertThrowsError(try manager.upgrade(appID: "a", package: root.appendingPathComponent("package"), migration: { staging, old, new in
            XCTAssertEqual(old.dataSchemaVersion, 1); XCTAssertEqual(new.dataSchemaVersion, 2)
            try Data("changed".utf8).write(to: staging.appendingPathComponent("state/user"))
            throw AppSDKError.denied
        }))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("apps/a/state/user")), Data("apps/a/state/user".utf8))
        _ = try manager.upgrade(appID: "a", package: root.appendingPathComponent("package"), migration: { staging, _, _ in
            try Data("migrated".utf8).write(to: staging.appendingPathComponent("state/user"))
        })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("apps/a/state/user")), Data("migrated".utf8))
    }
    func testRejectsHostMismatchLinksAndPackageState() throws {
        let root = try fixture(); let manager = try AppUpgradeManager(root: root, hostAPIMajor: 1)
        try manifest(version: "2", host: 2).write(to: root.appendingPathComponent("package/manifest.json"))
        XCTAssertThrowsError(try manager.upgrade(appID: "a", package: root.appendingPathComponent("package")))
        try manifest(version: "2").write(to: root.appendingPathComponent("package/manifest.json"))
        let link = root.appendingPathComponent("package/payload/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("shared/user"))
        XCTAssertThrowsError(try manager.upgrade(appID: "a", package: root.appendingPathComponent("package")))
        try FileManager.default.removeItem(at: link)
        try FileManager.default.linkItem(at: root.appendingPathComponent("shared/user"), to: link)
        XCTAssertThrowsError(try manager.upgrade(appID: "a", package: root.appendingPathComponent("package")))
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("package/state"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try manager.upgrade(appID: "a", package: root.appendingPathComponent("package")))
        XCTAssertThrowsError(try manager.upgrade(appID: "../b", package: root.appendingPathComponent("package")))
    }
    func testMigrationCannotPublishLinksAndReceiptSurvivesRootMove() throws {
        let root = try fixture(); let manager = try AppUpgradeManager(root: root, hostAPIMajor: 1)
        try manifest(version: "2", schema: 2).write(to: root.appendingPathComponent("package/manifest.json"))
        XCTAssertThrowsError(try manager.upgrade(appID: "a", package: root.appendingPathComponent("package"), migration: { staging, _, _ in
            try FileManager.default.createSymbolicLink(at: staging.appendingPathComponent("state/link"), withDestinationURL: root.appendingPathComponent("shared"))
        }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("apps/a/state/link").path))
        try manifest(version: "2").write(to: root.appendingPathComponent("package/manifest.json"))
        let receipt = try manager.upgrade(appID: "a", package: root.appendingPathComponent("package"))
        let moved = root.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: root, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        try AppUpgradeManager(root: moved, hostAPIMajor: 1).rollback(receipt)
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("apps/a/payload/code")), Data("old".utf8))
    }

    func testRecoveryRestoresAppAfterInterruptedDirectorySwap() throws {
        let root = try fixture(); let manager = try AppUpgradeManager(root: root, hostAPIMajor: 1)
        let receipt = try manager.upgrade(appID: "a", package: root.appendingPathComponent("package"))
        let transaction = root.appendingPathComponent(receipt.snapshotRelativePath).deletingLastPathComponent()
        let before = try JSONSerialization.jsonObject(with: manifest(version: "1"))
        let after = try JSONSerialization.jsonObject(with: manifest(version: "2"))
        let marker = try JSONSerialization.data(withJSONObject: ["transaction": transaction.lastPathComponent, "before": before, "after": after])
        try marker.write(to: transaction.deletingLastPathComponent().appendingPathComponent("pending.json"))
        try FileManager.default.moveItem(at: root.appendingPathComponent("apps/a"), to: transaction.appendingPathComponent("interrupted-live"))
        try manager.recover(appID: "a")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("apps/a/payload/code")), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("apps/a/state/user")), Data("apps/a/state/user".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.deletingLastPathComponent().appendingPathComponent("pending.json").path))
        try manager.recover(appID: "a")
    }

}
