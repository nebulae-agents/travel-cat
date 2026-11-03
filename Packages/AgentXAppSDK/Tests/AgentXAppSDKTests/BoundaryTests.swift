import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import AgentXAppSDK

final class BoundaryTests: XCTestCase {
    func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        for path in ["apps/a/state", "apps/b/state", "shared/references", "manager"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func access(_ root: URL) throws -> AppFileAccess {
        try AppFileAccess(root: root, appID: "a", grants: [AppFileGrant(appID: "a", relativePath: "apps/a", access: .readWrite), AppFileGrant(appID: "a", relativePath: "shared/references", access: .read)])
    }
    func testOwnershipSharedAndRelocation() throws {
        let root = try fixture()
        let api = try access(root)
        try api.write(Data("own".utf8), relativePath: "apps/a/state/x")
        XCTAssertEqual(try api.read(relativePath: "apps/a/state/x"), Data("own".utf8))
        try Data("shared".utf8).write(to: root.appendingPathComponent("shared/references/x"))
        XCTAssertEqual(try api.read(relativePath: "shared/references/x"), Data("shared".utf8))
        for path in ["apps/b/state/x", "manager/x", "shared/references/x", "../escape", "/tmp/escape"] {
            XCTAssertThrowsError(try api.write(Data(), relativePath: path))
        }
        XCTAssertThrowsError(try api.read(relativePath: "apps/b/state/x"))
        let moved = root.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: root, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        XCTAssertEqual(try access(moved).read(relativePath: "apps/a/state/x"), Data("own".utf8))
    }
    func testLinksAndInvalidGrants() throws {
        let root = try fixture(); let api = try access(root)
        let victim = root.appendingPathComponent("apps/b/state/secret")
        try Data("secret".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("apps/a/state/link"), withDestinationURL: victim)
        try FileManager.default.linkItem(at: victim, to: root.appendingPathComponent("apps/a/state/hard"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("apps/a/alias"), withDestinationURL: root.appendingPathComponent("apps/b/state"))
        for path in ["apps/a/state/link", "apps/a/state/hard", "apps/a/alias/secret"] {
            XCTAssertThrowsError(try api.read(relativePath: path))
            XCTAssertThrowsError(try api.write(Data(), relativePath: path))
        }
        for path in ["apps/b", "manager", "audit", "backups", "apps/a/../b", "shared", "apps/a//state"] {
            XCTAssertThrowsError(try AppFileAccess(root: root, appID: "a", grants: [AppFileGrant(appID: "a", relativePath: path, access: .readWrite)]))
        }
        XCTAssertEqual(try Data(contentsOf: victim), Data("secret".utf8))
    }
    func testSpecialFilesAndGrantIdentity() throws {
        let root = try fixture(); let api = try access(root)
        let fifo = root.appendingPathComponent("apps/a/state/fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try api.read(relativePath: "apps/a/state/fifo"))
        XCTAssertThrowsError(try api.write(Data(), relativePath: "apps/a/state/fifo"))
        XCTAssertThrowsError(try AppFileAccess(root: root, appID: "a", grants: [AppFileGrant(appID: "b", relativePath: "apps/a", access: .read)]))
    }
    func testUppercaseApplicationIdentityIsRejected() throws {
        let root = try fixture()
        XCTAssertThrowsError(try AppFileAccess(root: root, appID: "A", grants: [.init(appID: "A", relativePath: "apps/A", access: .readWrite)]))
    }
    func testManifestCompatibility() throws {
        var manifest = AppManifest(id: "a", name: "A", version: "1.2.3", dataSchemaVersion: 1, hostAPIMajor: 1, kind: "utility", runtime: "native", modules: ["notes"])
        try manifest.validate(hostAPIMajor: 1)
        XCTAssertThrowsError(try manifest.validate(hostAPIMajor: 2))
        let data = try JSONEncoder().encode(manifest)
        XCTAssertEqual(try JSONDecoder().decode(AppManifest.self, from: data), manifest)
        manifest.paths.state = "apps/b/state"
        XCTAssertThrowsError(try manifest.validate(hostAPIMajor: 1))
    }
}
