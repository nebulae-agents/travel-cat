import Foundation
import XCTest
@testable import TravelCatApp

final class JourneyTestCodexInstallationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("JourneyCodexResolver-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    func testFindsNativeExecutableInSuppliedPathWithoutExecutingIt() throws {
        try installNative(at: root.appendingPathComponent("codex"))
        let result = try JourneyTestCodexInstallation.resolve(searchDirectories: [root], nvmRoot: nil)
        XCTAssertEqual(result.executableURL.path, root.appendingPathComponent("codex").path)
        XCTAssertEqual(result.searchPath, root.path + ":/usr/bin:/bin")
    }

    func testNpmSymlinkRequiresMatchingNodeAndPreservesLauncherDirectory() throws {
        let script = root.appendingPathComponent("codex.js")
        try Data("#!/usr/bin/env node\n// resolver fixture; never executed\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("codex"), withDestinationURL: script)
        XCTAssertThrowsError(try JourneyTestCodexInstallation.resolve(searchDirectories: [root], nvmRoot: nil))
        try installNative(at: root.appendingPathComponent("node"))
        let result = try JourneyTestCodexInstallation.resolve(searchDirectories: [root], nvmRoot: nil)
        XCTAssertEqual(result.executableURL.lastPathComponent, "codex")
        XCTAssertTrue(result.searchPath.hasPrefix(root.path + ":"))
    }

    func testDiscoversNvmWithoutShellProfileAndChoosesNewestUsableVersion() throws {
        let nvm = root.appendingPathComponent("versions")
        for version in ["v9.9.0", "v22.2.0", "v99.0.0"] {
            try FileManager.default.createDirectory(at: nvm.appendingPathComponent(version + "/bin"), withIntermediateDirectories: true)
        }
        try installNative(at: nvm.appendingPathComponent("v9.9.0/bin/codex"))
        try installNative(at: nvm.appendingPathComponent("v22.2.0/bin/codex"))
        let result = try JourneyTestCodexInstallation.resolve(searchDirectories: [], nvmRoot: nvm)
        XCTAssertTrue(result.executableURL.path.hasSuffix("v22.2.0/bin/codex"))
    }

    func testRejectsNonExecutableAndUnsupportedScript() throws {
        let target = root.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        XCTAssertThrowsError(try JourneyTestCodexInstallation.resolve(searchDirectories: [root], nvmRoot: nil))
        try FileManager.default.removeItem(at: target)
        try installNative(at: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        XCTAssertThrowsError(try JourneyTestCodexInstallation.resolve(searchDirectories: [root], nvmRoot: nil))
    }

    func testDiscoveryFindsHomeNvmWhenLaunchServicesPathHasNoCodex() throws {
        let bin = root.appendingPathComponent(".nvm/versions/node/v22.22.2/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try installNative(at: bin.appendingPathComponent("codex"))
        let result = try JourneyTestCodexInstallation.discover(
            environment: ["PATH": ".:relative"], home: root, commonDirectories: []
        )
        XCTAssertEqual(
            result.executableURL.resolvingSymlinksInPath(),
            bin.appendingPathComponent("codex").resolvingSymlinksInPath()
        )
    }

    private func installNative(at url: URL) throws {
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: url)
    }
}
