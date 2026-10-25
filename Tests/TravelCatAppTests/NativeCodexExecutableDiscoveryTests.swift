import Foundation
import XCTest
@testable import TravelCatApp

final class NativeCodexExecutableDiscoveryTests: XCTestCase {
    private func fixture(_ body: (URL, (String) -> Bool) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root) { path in
            path.hasPrefix(root.path + "/") && FileManager.default.isExecutableFile(atPath: path)
        }
    }

    private func executable(_ root: URL, _ relative: String) throws -> URL {
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    func testFinderEnvironmentFindsChatGPTBundledExecutableAndPassesSetupValidation() throws {
        try fixture { root, available in
            let apps = root.appendingPathComponent("Applications")
            let binary = try executable(apps, "ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
            let workspace = root.appendingPathComponent("workspace")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let detected = NativeCodexExecutableDiscovery.detect(environmentPath: "/usr/bin:/bin:/usr/sbin:/sbin",
                applicationDirectories: [apps], isExecutable: available)
            XCTAssertEqual(detected, binary.path)
            XCTAssertNoThrow(try NativeRuntimeConfiguration(executable: detected, workspace: workspace.path, model: "").validate(requireModel: false))
        }
    }

    func testExplicitPathKeepsPriorityOverApplicationFallbacks() throws {
        try fixture { root, available in
            let bin = try executable(root, "bin/codex")
            _ = try executable(root, "Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
            XCTAssertEqual(NativeCodexExecutableDiscovery.detect(environmentPath: bin.deletingLastPathComponent().path,
                applicationDirectories: [root.appendingPathComponent("Applications")], isExecutable: available), bin.path)
        }
    }

    func testUserApplicationsAndStandaloneCodexRemainSupported() throws {
        try fixture { root, available in
            let system = root.appendingPathComponent("Applications")
            let user = root.appendingPathComponent("User/Applications")
            let bin = try executable(user, "Codex.app/Contents/Resources/codex")
            XCTAssertEqual(NativeCodexExecutableDiscovery.detect(environmentPath: "", applicationDirectories: [system, user],
                isExecutable: available), bin.path)
        }
    }

    func testRelativeEnvironmentEntriesAreNeverProbed() {
        let relative = "relative-codex-\(UUID().uuidString)"
        var probed: [String] = []
        _ = NativeCodexExecutableDiscovery.detect(environmentPath: ".:\(relative)", applicationDirectories: [], isExecutable: {
            probed.append($0); return false
        })
        XCTAssertFalse(probed.contains { $0.contains(relative) })
        XCTAssertFalse(probed.contains(URL(fileURLWithPath: ".").appendingPathComponent("codex").path))
    }

    func testAbsentAndNonExecutableCandidatesAreRejected() throws {
        try fixture { root, available in
            let apps = root.appendingPathComponent("Applications")
            let bin = try executable(apps, "ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bin.path)
            XCTAssertEqual(NativeCodexExecutableDiscovery.detect(environmentPath: "", applicationDirectories: [apps],
                isExecutable: available), "")
        }
    }
}
