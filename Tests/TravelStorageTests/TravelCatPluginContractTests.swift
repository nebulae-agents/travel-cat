import Foundation
import XCTest

final class TravelCatPluginContractTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testProductionPluginManifestAndSkillsAreSelfContained() throws {
        let plugin = root.appendingPathComponent("Plugins/travel-cat")
        let data = try Data(contentsOf: plugin.appendingPathComponent(".codex-plugin/plugin.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(manifest["name"] as? String, "travel-cat")
        XCTAssertEqual(manifest["version"] as? String, "1.0.0")
        XCTAssertEqual(manifest["skills"] as? String, "./skills/")
        XCTAssertTrue((manifest["description"] as? String)?.contains("custom") == true)

        for path in [
            "skills/travel-cat-heartbeat/SKILL.md",
            "skills/travel-cat-heartbeat/references/event-contract.md",
            "skills/travel-cat-heartbeat/references/postcard-prompt.md",
            "skills/travel-cat-journal/SKILL.md",
            "skills/travel-cat-journal/references/runtime-contract.md",
            "skills/travel-cat-heartbeat/references/event-candidate.schema.json",
            "skills/travel-cat-heartbeat/references/image-result.schema.json",
            "scripts/travel-cat-launcher-lib.sh",
            "scripts/run-travelcatctl",
        ] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: plugin.appendingPathComponent(path).path),
                path
            )
        }
    }

    func testHeartbeatUsesRelativeShippedLauncherAndStaysSilentOnNoOp() throws {
        let skill = try productionSkill("travel-cat-heartbeat/SKILL.md")
        XCTAssertTrue(skill.contains("../../scripts/run-travelcatctl"))
        XCTAssertFalse(skill.contains("/Users/"))
        XCTAssertTrue(skill.contains("Check `pending-images` first"))
        XCTAssertTrue(skill.contains("at most one authoritative action"))
        XCTAssertTrue(skill.contains("NO_REPLY"))
        XCTAssertTrue(skill.contains("departure"))
        XCTAssertTrue(skill.contains("postcard-ready"))
        XCTAssertTrue(skill.contains("return"))
        XCTAssertFalse(skill.contains("swift run"))
        XCTAssertFalse(skill.contains("TRAVEL_CAT_DATA="))
    }

    func testJournalSkillHasExactlyFiveProductionIntentsAndReadOnlyQueries() throws {
        let skill = try productionSkill("travel-cat-journal/SKILL.md")
        for intent in ["当前旅程", "最新明信片", "旅行册", "暂停旅行", "继续旅行"] {
            XCTAssertTrue(skill.contains(intent), intent)
        }
        XCTAssertTrue(skill.contains("run-travelcatctl journal"))
        XCTAssertTrue(skill.contains("pause exactly one existing Travel Cat automation"))
        XCTAssertTrue(skill.contains("resume exactly one existing Travel Cat automation"))
        for forbidden in ["临时测试", "run-travelcatctl claim", "run-travelcatctl publish", "run-travelcatctl mark-image"] {
            XCTAssertFalse(skill.contains(forbidden), forbidden)
        }
    }

    func testProductionPluginContainsNoAcceptanceCapabilityOrUnsafeRuntime() throws {
        let plugin = root.appendingPathComponent("Plugins/travel-cat")
        let files = try FileManager.default.subpathsOfDirectory(atPath: plugin.path).filter { !$0.hasPrefix(".") }
        let filesWithoutDirectories: [String] = files.compactMap { relativePath -> String? in
            let absolutePath = plugin.appendingPathComponent(relativePath).path
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDirectory), isDirectory.boolValue {
                return nil
            }
            return absolutePath
        }
        let combined = try filesWithoutDirectories.map {
            try String(contentsOfFile: $0, encoding: .utf8)
        }.joined(separator: "\n")
        XCTAssertFalse(combined.contains("临时测试"))
        XCTAssertFalse(combined.contains("swift run"))
        XCTAssertFalse(combined.contains(".build/debug"))
        XCTAssertFalse(combined.contains("TravelCatApp"))
        XCTAssertFalse(combined.contains("PetTravelBubbleController"))
    }

    func testHeartbeatReferencesMatchTheCanonicalTravelAgentContracts() throws {
        let canonical = root.appendingPathComponent(".agents/skills/travel-cat-agent/references")
        let plugin = root.appendingPathComponent("Plugins/travel-cat/skills/travel-cat-heartbeat/references")

        for name in [
            "event-contract.md", "postcard-prompt.md",
            "event-candidate.schema.json", "image-result.schema.json",
        ] {
            XCTAssertEqual(
                try Data(contentsOf: canonical.appendingPathComponent(name)),
                try Data(contentsOf: plugin.appendingPathComponent(name)),
                name
            )
        }
    }

    func testNormativeSchemasMatchAutomationAndBothReferenceDirectories() throws {
        let automation = root.appendingPathComponent("Automation/schemas")
        let canonical = root.appendingPathComponent(".agents/skills/travel-cat-agent/references")
        let plugin = root.appendingPathComponent("Plugins/travel-cat/skills/travel-cat-heartbeat/references")
        for name in ["event-candidate.schema.json", "image-result.schema.json"] {
            let expected = try Data(contentsOf: automation.appendingPathComponent(name))
            XCTAssertEqual(try Data(contentsOf: canonical.appendingPathComponent(name)), expected)
            XCTAssertEqual(try Data(contentsOf: plugin.appendingPathComponent(name)), expected)
        }
    }

    func testJournalSkillRejectsUnsafePostcardPathsAndKeepsReadsSideEffectFree() throws {
        let skill = try productionSkill("travel-cat-journal/SKILL.md")
        for required in [
            "reject missing metadata, absolute paths, `..`, symlinked parents or leaves",
            "PNG or WebP",
            "Never advance travel state",
            "Never advance travel state or print IDs",
        ] {
            XCTAssertTrue(skill.contains(required), required)
        }
    }

    func testVerifierAndPublicDocsDescribePortableRuntimeWithoutPrivateSmokeIdentity() throws {
        let verifier = root.appendingPathComponent("Scripts/verify-travel-cat-plugin.sh")
        let runbook = root.appendingPathComponent("docs/installation.md")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: verifier.path))

        let runbookText = try String(contentsOf: runbook, encoding: .utf8)
        for required in [
            "Travel Cat",
            "每 15 分钟",
            "NO_REPLY",
            "runtime.dataRoot",
            "自定义宠物",
        ] {
            XCTAssertTrue(runbookText.contains(required), required)
        }
        XCTAssertNil(runbookText.range(
            of: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
            options: .regularExpression
        ))
    }


    func testJournalUsesRuntimeMetadataAndAmbiguitySafeAutomationIdentity() throws {
        let skill = try productionSkill("travel-cat-journal/SKILL.md")
        XCTAssertTrue(skill.contains("runtime.dataRoot"))
        XCTAssertTrue(skill.contains("exactly one"))
        XCTAssertTrue(skill.contains("none or multiple"))
        XCTAssertFalse(skill.contains("/Users/"))
        XCTAssertFalse(skill.contains("Cute Black Cat · 旅行日记"))
    }

    func testHeartbeatUsesFrozenWorkIdentityAndNeverSubstitutesBlackCatForCustomReferences() throws {
        let skill = try productionSkill("travel-cat-heartbeat/SKILL.md")
        let postcard = try productionSkill("travel-cat-heartbeat/references/postcard-prompt.md")
        for required in [
            "frozen", "runtime.dataRoot", "runtime.bundledResourcesRoot",
            "untrusted story data", "never substitute", "event-candidate.schema.json",
            "image-result.schema.json",
        ] { XCTAssertTrue(skill.contains(required), required) }
        for required in [
            "event.id` to `eventId", "imageAttemptCount` to `attemptCount",
            "attemptToken` and `publishedNarrativeHash` unchanged",
            "trusted current clock as RFC 3339", "leaseExpiresAt` only for lease discipline",
            "relativePath` as `null`", "same response's `runtime.dataRoot",
        ] { XCTAssertTrue(postcard.contains(required), required) }
    }

    func testPortableLauncherLibraryDiscoversOneSignedFixtureAndRejectsMissingAmbiguousAndLinks() throws {
        let fixture = try LauncherFixture(root: root)
        defer { fixture.cleanup() }
        let user = fixture.scratch.appendingPathComponent("User Applications")
        let system = fixture.scratch.appendingPathComponent("System Applications")
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)

        XCTAssertNotEqual(try fixture.discover(user: user, system: system).status, 0)
        let first = try fixture.makeSignedApp(in: user, marker: "first")
        let found = try fixture.discover(user: user, system: system)
        XCTAssertEqual(found.status, 0)
        XCTAssertEqual(
            found.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            first.appendingPathComponent("Contents/Resources/run-travelcatctl").path)
        _ = try fixture.makeSignedApp(in: system, marker: "second")
        XCTAssertNotEqual(try fixture.discover(user: user, system: system).status, 0)

        try FileManager.default.removeItem(at: first)
        let linked = user.appendingPathComponent("Travel Cat.app")
        try FileManager.default.createSymbolicLink(
            at: linked, withDestinationURL: system.appendingPathComponent("Travel Cat.app"))
        XCTAssertNotEqual(try fixture.discover(user: user, system: fixture.scratch.appendingPathComponent("Empty")).status, 0)

        try FileManager.default.removeItem(at: linked)
        let linkedApplications = fixture.scratch.appendingPathComponent("Linked Applications")
        try FileManager.default.createSymbolicLink(at: linkedApplications, withDestinationURL: system)
        XCTAssertNotEqual(
            try fixture.discover(user: linkedApplications, system: fixture.scratch.appendingPathComponent("Empty")).status, 0)

        let realHome = fixture.scratch.appendingPathComponent("Real Home")
        let realApplications = realHome.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: realApplications, withIntermediateDirectories: true)
        _ = try fixture.makeSignedApp(in: realApplications, marker: "linked-parent")
        let linkedHome = fixture.scratch.appendingPathComponent("Linked Home")
        try FileManager.default.createSymbolicLink(at: linkedHome, withDestinationURL: realHome)
        XCTAssertNotEqual(
            try fixture.discover(user: linkedHome.appendingPathComponent("Applications"), system: fixture.scratch.appendingPathComponent("Empty 2")).status, 0)
    }

    func testPublicAndScheduledEntriesKeepFixedArgumentsAndDoNotExposeFixtureOverrides() throws {
        let publicEntry = try String(
            contentsOf: root.appendingPathComponent("Plugins/travel-cat/scripts/run-travelcatctl"),
            encoding: .utf8)
        let scheduled = try String(
            contentsOf: root.appendingPathComponent("Scripts/run-scheduled-travelcatctl.sh"),
            encoding: .utf8)
        XCTAssertTrue(publicEntry.contains("$HOME/Applications"))
        XCTAssertTrue(publicEntry.contains("/Applications"))
        XCTAssertFalse(publicEntry.contains("TRAVEL_CAT_"))
        XCTAssertTrue(publicEntry.contains("case ${HOME-}"))
        let fixture = try LauncherFixture(root: root)
        defer { fixture.cleanup() }
        XCTAssertEqual(try fixture.invokePublic(home: nil).status, 65)
        XCTAssertEqual(try fixture.invokePublic(home: "relative-home").status, 65)
        XCTAssertTrue(scheduled.contains("Plugins/travel-cat/scripts/run-travelcatctl"))
        XCTAssertTrue(scheduled.contains("validate-candidate|publish|mark-image"))
    }

    func testHermeticLauncherFunctionPreservesStdinAndRejectsInvalidCommand() throws {
        let fixture = try LauncherFixture(root: root)
        defer { fixture.cleanup() }
        let user = fixture.scratch.appendingPathComponent("User Applications")
        let system = fixture.scratch.appendingPathComponent("System Applications")
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        _ = try fixture.makeSignedApp(in: user, marker: "fixture")
        let input = Data(#"{"story":"$(touch /tmp/never-run)"}"#.utf8)

        let accepted = try fixture.invoke(user: user, system: system, command: "publish", stdin: input)
        XCTAssertEqual(accepted.status, 0, accepted.stderr)
        XCTAssertEqual(accepted.stdout, "fixture:" + String(decoding: input, as: UTF8.self))
        let rejected = try fixture.invoke(user: user, system: system, command: "configure-character", stdin: input)
        XCTAssertEqual(rejected.status, 64)
        XCTAssertFalse(rejected.stdout.contains("fixture:"))
    }

    func testAcceptanceCapabilityIsAbsentAfterValidation() throws {
        for path in [
            "Acceptance/travel-cat",
            "Acceptance/TravelPetData.acceptance",
            "Scripts/run-travel-cat-acceptance.sh",
        ] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path),
                path
            )
        }

        let production = try productionSkill("travel-cat-journal/SKILL.md")
        XCTAssertFalse(production.contains("临时测试"))
    }

    private func productionSkill(_ relative: String) throws -> String {
        try String(
            contentsOf: root.appendingPathComponent("Plugins/travel-cat/skills/\(relative)"),
            encoding: .utf8
        )
    }
}

private final class LauncherFixture {
    struct Result { let status: Int32; let stdout: String; let stderr: String }
    let projectRoot: URL
    let scratch: URL
    init(root: URL) throws {
        projectRoot = root
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TravelCatPluginLauncherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: scratch) }
    func makeSignedApp(in directory: URL, marker: String) throws -> URL {
        let app = directory.appendingPathComponent("Travel Cat.app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.nebulae.travelcat", "CFBundleName": "Travel Cat",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let launcher = resources.appendingPathComponent("run-travelcatctl")
        try Data("#!/bin/sh\nprintf '%s:' '\(marker)'\ncat\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        let signed = try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        XCTAssertEqual(signed.status, 0, signed.stderr)
        return app
    }
    func discover(user: URL, system: URL) throws -> Result {
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        let library = projectRoot.appendingPathComponent("Plugins/travel-cat/scripts/travel-cat-launcher-lib.sh")
        return try run("/bin/sh", ["-c", ". \"$1\"; travel_cat_find_launcher \"$2\" \"$3\"", "test", library.path, user.path, system.path])
    }
    func invoke(user: URL, system: URL, command: String, stdin: Data) throws -> Result {
        let library = projectRoot.appendingPathComponent("Plugins/travel-cat/scripts/travel-cat-launcher-lib.sh")
        return try run(
            "/bin/sh",
            ["-c", ". \"$1\"; travel_cat_run_from_directories \"$2\" \"$3\" \"$4\"", "test", library.path, user.path, system.path, command],
            stdin: stdin)
    }
    func invokePublic(home: String?) throws -> Result {
        let entry = projectRoot.appendingPathComponent("Plugins/travel-cat/scripts/run-travelcatctl")
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home
        return try run("/bin/sh", [entry.path, "status"], environment: environment)
    }
    private func run(
        _ executable: String,
        _ arguments: [String],
        stdin: Data? = nil,
        environment: [String: String]? = nil
    ) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let output = Pipe(); let error = Pipe()
        process.standardOutput = output; process.standardError = error
        if let stdin {
            let input = Pipe()
            process.standardInput = input
            try input.fileHandleForWriting.write(contentsOf: stdin)
            try input.fileHandleForWriting.close()
        }
        try process.run(); process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}
