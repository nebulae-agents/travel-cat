import Foundation
import XCTest
@testable import AgentXAppSDK

final class SandboxTests: XCTestCase {
    func testProfileRejectsPreexistingLinkedFiles() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["apps/a", "apps/b"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let secret = root.appendingPathComponent("apps/b/secret")
        try Data("secret".utf8).write(to: secret)
        try FileManager.default.linkItem(at: secret, to: root.appendingPathComponent("apps/a/link"))
        XCTAssertThrowsError(try AppSandboxProfile.generate(root: root, appID: "a", grants: [.init(appID: "a", relativePath: "apps/a", access: .readWrite)]))
    }
    func testActualSubprocessIsolation() throws {
#if os(macOS)
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { throw XCTSkip("sandbox-exec unavailable; untrusted execution must remain disabled") }
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["apps/a", "apps/b", "shared/references", "manager"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
            try Data("value".utf8).write(to: root.appendingPathComponent(path + "/x"))
        }
        let profile = try AppSandboxProfile.generate(root: root, appID: "a", grants: [AppFileGrant(appID: "a", relativePath: "apps/a", access: .readWrite), AppFileGrant(appID: "a", relativePath: "shared/references", access: .read)])
        func run(_ command: String) throws -> (Int32, String) {
            let process = Process(); let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-p", profile, "/bin/sh", "-c", command]
            process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C"]
            process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: output, as: UTF8.self))
        }
        let own = try run("/bin/cat '\(root.path)/apps/a/x'")
        if own.0 != 0 && own.1.contains("sandbox_init") { throw XCTSkip("OS sandbox unavailable: \(own.1)") }
        XCTAssertEqual(own.0, 0, own.1)
        XCTAssertEqual(try run("echo ok > '\(root.path)/apps/a/new'").0, 0)
        XCTAssertEqual(try run("/bin/cat '\(root.path)/shared/references/x'").0, 0)
        for path in ["apps/b/x", "manager/x"] {
            XCTAssertNotEqual(try run("/bin/cat '\(root.path)/\(path)'").0, 0)
            XCTAssertNotEqual(try run("echo bad > '\(root.path)/\(path)'").0, 0)
        }
        XCTAssertNotEqual(try run("echo bad > '\(root.path)/shared/references/x'").0, 0)
#else
        throw XCTSkip("macOS sandbox only; other systems require an external sandbox")
#endif
    }
}
