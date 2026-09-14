import Foundation
import XCTest

final class PackagingContractTests: XCTestCase {
    func testAppPackagingDoesNotPublishAnExternalPetInstaller() throws {
        let script = try String(contentsOf: projectRoot.appendingPathComponent("Scripts/package-app.sh"))
        XCTAssertFalse(script.contains("DEFAULT_PET_ENTRY"))
        XCTAssertFalse(script.contains("Install Default Pet.command"))
    }
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testInfoPlistDeclaresMenuBarApplicationContract() throws {
        let url = projectRoot.appendingPathComponent("packaging/Info.plist")
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), options: [], format: nil
        ) as? [String: Any])
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.nebulae.travelcat")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "TravelCatApp")
        XCTAssertEqual(plist["CFBundlePackageType"] as? String, "APPL")
        XCTAssertEqual(plist["LSUIElement"] as? Bool, true)
        XCTAssertEqual(plist["LSMinimumSystemVersion"] as? String, "14.0")
        XCTAssertNil(plist["TravelCatDataRoot"], "The distributable plist must not contain an author-machine data path")
    }

    func testPackagingRefreshesTheScheduledReleaseCLIProvenance() throws {
        let script = try String(
            contentsOf: projectRoot.appendingPathComponent("Scripts/package-app.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(script.contains("\"$PROJECT_ROOT/Scripts/build-scheduled-travelcatctl.sh\""))
        XCTAssertFalse(script.contains("\"$SCRIPT_DIR/build-scheduled-travelcatctl.sh\""))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: projectRoot.path).contains("Scripts"))

        for exactPath in ["Scripts/package-app.sh", "Scripts/build-scheduled-travelcatctl.sh"] {
            let url = projectRoot.appendingPathComponent(exactPath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), exactPath)
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path), exactPath)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
                .contains(url.lastPathComponent), "Exact-case path missing: \(exactPath)")

            if FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent(".git").path) {
                let tracked = try run(
                    URL(fileURLWithPath: "/usr/bin/git"),
                    ["-C", projectRoot.path, "ls-files", "--error-unmatch", exactPath]
                )
                XCTAssertEqual(tracked.status, 0, tracked.stderr)
                XCTAssertEqual(tracked.stdout.trimmingCharacters(in: .whitespacesAndNewlines), exactPath)
            }
        }
    }

    func testPackagingValidatesPreviewAssetsAtTheirSwiftPMBundlePaths() throws {
        let script = try String(
            contentsOf: projectRoot.appendingPathComponent("Scripts/package-app.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.contains("test -f \"$RESOURCE_BUNDLE/$preview_asset\""))
        XCTAssertTrue(script.contains(
            "test -f \"$STAGING/Contents/Resources/TravelCat_TravelUI.bundle/$preview_asset\""
        ))
        XCTAssertFalse(script.contains("TravelCat_TravelUI.bundle/PreviewPostcards/$preview_asset"))
    }

    func testPackagingValidatesEveryPreviewCatAtTheSwiftPMBundleRoot() throws {
        let script = try String(
            contentsOf: projectRoot.appendingPathComponent("Scripts/package-app.sh"),
            encoding: .utf8
        )

        for name in [
            "preview-cat-front.png",
            "preview-cat-side.png",
            "preview-cat-sitting.png",
        ] {
            XCTAssertTrue(script.contains(name), name)
        }
        XCTAssertTrue(script.contains("for cat_asset in"))
        XCTAssertTrue(script.contains("test -f \"$RESOURCE_BUNDLE/$cat_asset\""))
        XCTAssertTrue(script.contains(
            "test -f \"$STAGING/Contents/Resources/TravelCat_TravelUI.bundle/$cat_asset\""
        ))
        XCTAssertFalse(script.contains("TravelCat_TravelUI.bundle/PreviewBlackCat/$cat_asset"))
    }

    func testScheduledLauncherDelegatesToPortablePluginBoundaryWithFixedCommands() throws {
        let launcher = try String(
            contentsOf: projectRoot.appendingPathComponent("Scripts/run-scheduled-travelcatctl.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(launcher.contains("Plugins/travel-cat/scripts/run-travelcatctl"))
        XCTAssertFalse(launcher.contains("/Users/"))
        XCTAssertFalse(launcher.contains(".worktrees/travel-cat"))
        XCTAssertFalse(launcher.contains(".build"))
        XCTAssertFalse(launcher.contains("TravelPetData"))
        XCTAssertFalse(launcher.contains("PROVENANCE="))
        XCTAssertFalse(launcher.contains("verify-travelcatctl-release.sh"))
        XCTAssertFalse(launcher.contains("TRAVEL_CAT_DATA"))
        XCTAssertFalse(launcher.contains("swift run"))
        XCTAssertFalse(launcher.contains("/debug/"))
        XCTAssertFalse(launcher.contains("eval"))

        for command in ["status", "journal", "pending-images", "claim", "validate-candidate", "publish", "mark-image"] {
            XCTAssertTrue(launcher.contains(command), "Launcher must allow the documented fixed command: \(command)")
        }
    }

    func testBundledScheduledRuntimeIsSelfContainedAndFailClosed() throws {
        let launcherURL = projectRoot.appendingPathComponent("Scripts/run-bundled-travelcatctl.sh")
        let launcher = try String(contentsOf: launcherURL, encoding: .utf8)
        let package = try String(
            contentsOf: projectRoot.appendingPathComponent("Scripts/package-app.sh"),
            encoding: .utf8
        )

        for token in [
            "Contents/Helpers/travelcatctl",
            "Contents/Resources/travelcatctl-release.provenance",
            "codesign --verify --deep --strict",
            "CFBundleIdentifier",
            "com.nebulae.travelcat",
            "binarySHA256=", "binaryArtifactID=",
            "TRAVEL_CAT_DATA",
            "Library/Application Support/TravelCat/TravelPetData",
        ] {
            XCTAssertTrue(launcher.contains(token), "Bundled launcher is missing: \(token)")
        }
        XCTAssertFalse(launcher.contains("TRAVEL_CAT_MODE"))
        XCTAssertFalse(launcher.contains("/Users/"))
        XCTAssertFalse(launcher.contains(".worktrees"))
        XCTAssertFalse(launcher.contains("/debug/"))
        XCTAssertFalse(launcher.contains("swift run"))
        XCTAssertFalse(launcher.contains("eval"))
        XCTAssertFalse(launcher.contains("\\${"), "Shell parameter expansion must not be escaped into a literal")
        XCTAssertTrue(launcher.contains("EXPECTED_SHA=${BINARY_LINE#binarySHA256=}"))
        XCTAssertTrue(launcher.contains("for DIGEST in \"$EXPECTED_SOURCE\" \"$EXPECTED_SHA\""))

        for command in ["status", "journal", "pending-images", "claim", "validate-candidate", "publish", "mark-image"] {
            XCTAssertTrue(launcher.contains(command), "Bundled launcher must allow: \(command)")
        }
        for command in ["character", "configure-character"] {
            XCTAssertTrue(launcher.contains(command), "Interactive bundled launcher must allow: \(command)")
        }
        XCTAssertTrue(launcher.contains("install-default-pet"))
        XCTAssertTrue(launcher.contains("TRAVEL_CAT_DEFAULT_PET_RESOURCES_ROOT"))
        XCTAssertTrue(launcher.contains("TRAVEL_CAT_DEFAULT_PETS_ROOT"))

        for packagedPath in [
            "Contents/Resources/run-travelcatctl",
            "Contents/Helpers/travelcatctl",
            "Contents/Resources/travelcatctl-release.provenance",
        ] {
            XCTAssertTrue(package.contains(packagedPath), "Package script is missing: \(packagedPath)")
        }
        XCTAssertTrue(package.contains("run-bundled-travelcatctl.sh"))
        XCTAssertTrue(package.contains("binaryArtifactID="))
        XCTAssertTrue(package.contains("codesign --force --sign - \"$STAGING\""))
        XCTAssertFalse(package.contains("codesign --force --deep --sign"))
        XCTAssertLessThan(
            try XCTUnwrap(package.range(of: "Contents/Helpers/travelcatctl")?.lowerBound),
            try XCTUnwrap(package.range(of: "codesign --force --sign")?.lowerBound),
            "The helper must be present before the enclosing bundle is signed"
        )
    }

    func testBundledLauncherUsesPortableHomeDefaultAndIgnoresAmbientDataRoot() throws {
        let fixture = try makeBundledLauncherFixture(dataRoot: nil)
        defer { try? FileManager.default.removeItem(at: fixture.app.deletingLastPathComponent()) }
        let home = fixture.app.deletingLastPathComponent().appendingPathComponent("portable home", isDirectory: true)

        let result = try run(
            fixture.launcher,
            ["status"],
            environment: [
                "HOME": home.path,
                "TRAVEL_CAT_DATA": "/tmp/ambient-must-not-win",
            ]
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            result.stdout,
            "status\n\(home.path)/Library/Application Support/TravelCat/TravelPetData\n\(fixture.app.path)/Contents/Resources/TravelCat_TravelUI.bundle\n"
        )
    }

    func testBundledLauncherUsesAbsolutePlistOverride() throws {
        let override = "/tmp/travel cat explicit data"
        let fixture = try makeBundledLauncherFixture(dataRoot: override)
        defer { try? FileManager.default.removeItem(at: fixture.app.deletingLastPathComponent()) }

        let result = try run(
            fixture.launcher,
            ["journal"],
            environment: ["HOME": "/tmp/ignored-home", "TRAVEL_CAT_DATA": "/tmp/ignored-ambient"]
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "journal\n\(override)\n\(fixture.app.path)/Contents/Resources/TravelCat_TravelUI.bundle\n")
    }

    func testBundledLauncherUsesExplicitCodexHomeOnlyForDefaultPetInstall() throws {
        let fixture = try makeBundledLauncherFixture(dataRoot: "relative travel root must be ignored")
        defer { try? FileManager.default.removeItem(at: fixture.app.deletingLastPathComponent()) }
        let codex = fixture.app.deletingLastPathComponent().appendingPathComponent("Codex Home", isDirectory: true)
        let result = try run(fixture.launcher, ["install-default-pet"], environment: [
            "CODEX_HOME": codex.path,
            "TRAVEL_CAT_DEFAULT_PETS_ROOT": "/tmp/ambient-must-not-win",
        ])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "install-default-pet\n\(codex.path)/pets\n\(fixture.app.path)/Contents/Resources/TravelCat_TravelUI.bundle\n")
    }

    func testBundledLauncherRejectsInvalidExplicitCodexHomeInsteadOfFallingBack() throws {
        let fixture = try makeBundledLauncherFixture(dataRoot: nil)
        defer { try? FileManager.default.removeItem(at: fixture.app.deletingLastPathComponent()) }
        let result = try run(fixture.launcher, ["install-default-pet"], environment: [
            "HOME": "/tmp/valid-home", "CODEX_HOME": "relative",
        ])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("CODEX_HOME"))
    }

    func testDefaultPetCandidateEntryIsThinAndFixed() throws {
        let entry = try String(contentsOf: projectRoot.appendingPathComponent("Scripts/install-default-pet.command"), encoding: .utf8)
        XCTAssertTrue(entry.contains("Travel Cat.app"))
        XCTAssertTrue(entry.contains("codesign --verify --deep --strict"))
        XCTAssertTrue(entry.contains("com.nebulae.travelcat"))
        XCTAssertTrue(entry.contains("exec \"$LAUNCHER\" install-default-pet"))
        XCTAssertTrue(entry.contains("[ -f \"$LAUNCHER\" ]"))
        XCTAssertFalse(entry.contains("python"))
        XCTAssertFalse(entry.contains("swift"))
        XCTAssertFalse(entry.contains("TRAVEL_CAT_DEFAULT"))
    }

    func testBundledLauncherSuppliesOwnResourcesRootAndIgnoresAmbientOverride() throws {
        let fixture = try makeBundledLauncherFixture(dataRoot: "/tmp/data root")
        defer { try? FileManager.default.removeItem(at: fixture.app.deletingLastPathComponent()) }
        let result = try run(
            fixture.launcher, ["pending-images"],
            environment: [
                "HOME": "/tmp/portable home",
                "TRAVEL_CAT_BUNDLED_RESOURCES_ROOT": "/tmp/ambient must not win",
            ])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            result.stdout,
            "pending-images\n/tmp/data root\n\(fixture.app.path)/Contents/Resources/TravelCat_TravelUI.bundle\n")
    }

    func testBundledLauncherRejectsInvalidConfiguredRootAndInvalidHome() throws {
        for invalidRoot: Any in ["", "relative/path", ["/tmp/looks-valid": true]] {
            let fixture = try makeBundledLauncherFixture(dataRoot: invalidRoot)
            defer { try? FileManager.default.removeItem(at: fixture.app.deletingLastPathComponent()) }
            let result = try run(fixture.launcher, ["status"], environment: ["HOME": "/tmp/valid-home"])
            XCTAssertNotEqual(result.status, 0, "Configured root '\(invalidRoot)' must fail closed")
        }

        let fixture = try makeBundledLauncherFixture(dataRoot: nil)
        defer { try? FileManager.default.removeItem(at: fixture.app.deletingLastPathComponent()) }
        for invalidHome in ["", "relative-home"] {
            let result = try run(fixture.launcher, ["status"], environment: ["HOME": invalidHome])
            XCTAssertNotEqual(result.status, 0, "HOME '\(invalidHome)' must fail closed")
        }
    }

    func testPackageAppAcceptsOnlyOptionalAbsoluteDataRootArgument() throws {
        let package = projectRoot.appendingPathComponent("Scripts/package-app.sh")
        for arguments in [
            ["--data-root", "relative/path"],
            ["--data-root", ""],
            ["--data-root"],
            ["--unknown"],
            ["/tmp/legacy-positional-root"],
        ] {
            let result = try run(package, arguments)
            XCTAssertEqual(result.status, 64, "Arguments \(arguments) should be rejected before building: \(result.stderr)")
        }
    }

    func testInstallerPublishesOnlyTravelCatAndNeverTouchesTravelData() throws {
        let installer = projectRoot.appendingPathComponent("Scripts/install-travel-cat-app.sh")
        let installerSource = try String(contentsOf: installer, encoding: .utf8)
        XCTAssertTrue(installerSource.contains("Applications/Travel Cat.app"))
        XCTAssertTrue(installerSource.contains("com.nebulae.travelcat"))
        XCTAssertTrue(installerSource.contains("codesign --verify --deep --strict"))
        XCTAssertTrue(installerSource.contains(".staging."))
        XCTAssertFalse(installerSource.contains("Application Support"))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("travel-cat-installer-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let source = root.appendingPathComponent("source/Travel Cat.app", isDirectory: true)
        try makeSignedFixtureApp(at: source, bundleID: "com.nebulae.travelcat")

        let dataRoot = home.appendingPathComponent("Library/Application Support/TravelCat/TravelPetData", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        let marker = dataRoot.appendingPathComponent("preserve-me.txt")
        let markerBytes = Data("travel-history-must-survive\n".utf8)
        try markerBytes.write(to: marker)

        let installed = home.appendingPathComponent("Applications/Travel Cat.app", isDirectory: true)
        let first = try run(installer, [source.path], environment: ["HOME": home.path])
        XCTAssertEqual(first.status, 0, first.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
        XCTAssertEqual(try Data(contentsOf: marker), markerBytes)
        XCTAssertEqual(try bundleIdentifier(at: installed), "com.nebulae.travelcat")
        XCTAssertEqual(try run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--deep", "--strict", installed.path]).status, 0)

        try FileManager.default.removeItem(at: installed)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideMarker = outside.appendingPathComponent("outside.txt")
        try Data("untouched\n".utf8).write(to: outsideMarker)
        try FileManager.default.createSymbolicLink(at: installed, withDestinationURL: outside)
        let symlinkAttempt = try run(installer, [source.path], environment: ["HOME": home.path])
        XCTAssertNotEqual(symlinkAttempt.status, 0)
        XCTAssertEqual(try Data(contentsOf: outsideMarker), Data("untouched\n".utf8))
        try FileManager.default.removeItem(at: installed)

        try makeSignedFixtureApp(at: installed, bundleID: "example.not-travel-cat")
        let foreignPlist = try Data(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))
        let replacementAttempt = try run(
            installer,
            [source.path, "--replace-existing"],
            environment: ["HOME": home.path]
        )
        XCTAssertNotEqual(replacementAttempt.status, 0)
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("Contents/Info.plist")), foreignPlist)
        XCTAssertEqual(try Data(contentsOf: marker), markerBytes)
    }

    func testPinnedVerifierIgnoresCanonicalReplacementAndRejectsUnsafePinnedArtifacts() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("travel-cat-launcher-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("project", isDirectory: true)
        let pinnedRoot = container.appendingPathComponent("external-pinned", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/TravelCore"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/TravelStorage"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/TravelCatCLI"), withIntermediateDirectories: true)
        try Data("// package\n".utf8).write(to: root.appendingPathComponent("Package.swift"))
        try Data("// core\n".utf8).write(to: root.appendingPathComponent("Sources/TravelCore/Core.swift"))
        let canonical = container.appendingPathComponent("canonical/travelcatctl")
        try FileManager.default.createDirectory(at: canonical.deletingLastPathComponent(), withIntermediateDirectories: true)
        let originalBytes = Data("#!/bin/sh\nprintf pinned-v1\n".utf8)
        try originalBytes.write(to: canonical)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: canonical.path)

        let verifier = projectRoot.appendingPathComponent("Scripts/verify-travelcatctl-release.sh")
        let digestTool = projectRoot.appendingPathComponent("Scripts/travelcatctl-source-digest.sh")
        let provenance = root.appendingPathComponent("travelcatctl-release.provenance")

        XCTAssertNotEqual(try run(verifier, [provenance.path, root.path, pinnedRoot.path]).status, 0)

        let sourceDigest = try run(digestTool, [root.path])
        XCTAssertEqual(sourceDigest.status, 0, sourceDigest.stderr)
        let binaryDigest = try sha256(canonical)
        let artifactID = "\(binaryDigest)/travelcatctl"
        let pinned = pinnedRoot.appendingPathComponent(artifactID)
        try FileManager.default.createDirectory(at: pinned.deletingLastPathComponent(), withIntermediateDirectories: true)
        try originalBytes.write(to: pinned)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: pinned.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: pinned.deletingLastPathComponent().path)
        let provenanceText = """
        format=travel-cat-cli-provenance-v3
        product=travelcatctl
        configuration=release
        sourceTreeSHA256=\(sourceDigest.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        binarySHA256=\(binaryDigest)
        binaryArtifactID=\(artifactID)
        """
        try Data((provenanceText + "\n").utf8).write(to: provenance)

        let matching = try run(verifier, [provenance.path, root.path, pinnedRoot.path])
        XCTAssertEqual(matching.status, 0, matching.stderr)
        let matchingPath = matching.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(matchingPath.hasSuffix("/\(artifactID)"), matchingPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: matchingPath)), originalBytes)

        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: pinnedRoot.path)
        let writableRoot = try run(verifier, [provenance.path, root.path, pinnedRoot.path])
        XCTAssertNotEqual(writableRoot.status, 0, "A group/world-writable pinned root must fail closed")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pinnedRoot.path)

        try Data("#!/bin/sh\nprintf canonical-v2\n".utf8).write(to: canonical)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: canonical.path)
        let execution = try run(pinned, [])
        XCTAssertEqual(execution.status, 0, execution.stderr)
        XCTAssertEqual(execution.stdout, "pinned-v1")

        let wrongPath = provenanceText.replacingOccurrences(
            of: "binaryArtifactID=\(artifactID)",
            with: "binaryArtifactID=../travelcatctl"
        )
        try Data((wrongPath + "\n").utf8).write(to: provenance)
        XCTAssertNotEqual(try run(verifier, [provenance.path, root.path, pinnedRoot.path]).status, 0)
        try Data((provenanceText + "\n").utf8).write(to: provenance)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pinned.deletingLastPathComponent().path)
        try FileManager.default.removeItem(at: pinned)
        try FileManager.default.createSymbolicLink(at: pinned, withDestinationURL: canonical)
        XCTAssertNotEqual(try run(verifier, [provenance.path, root.path, pinnedRoot.path]).status, 0)

        try FileManager.default.removeItem(at: pinned)
        try Data("#!/bin/sh\nprintf drift\n".utf8).write(to: pinned)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: pinned.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: pinned.deletingLastPathComponent().path)
        XCTAssertNotEqual(try run(verifier, [provenance.path, root.path, pinnedRoot.path]).status, 0)

        let projectPinnedRoot = root.appendingPathComponent("pinned", isDirectory: true)
        try FileManager.default.createDirectory(at: projectPinnedRoot, withIntermediateDirectories: true)
        XCTAssertNotEqual(try run(verifier, [provenance.path, root.path, projectPinnedRoot.path]).status, 0)
    }

    func testActiveBuildAndVerificationEntrypointsUseOnlyTheExternalSwiftWrapper() throws {
        let paths = [
            "Scripts/build-scheduled-travelcatctl.sh",
            "Scripts/package-app.sh",
            "Scripts/verify-travel-cat-skill.sh",
            "Scripts/verify-agent-contract.sh",
        ]
        let directSwiftPM = try NSRegularExpression(pattern: #"(?m)^\s*swift\s+(?:build|run|test)\b"#)
        for path in paths {
            let source = try String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8)
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            XCTAssertNil(directSwiftPM.firstMatch(in: source, range: range), "Direct SwiftPM invocation in \(path)")
            XCTAssertFalse(source.contains("$PROJECT_ROOT/.build"), "Repository build path in \(path)")
            XCTAssertTrue(source.contains("travel-cat-swift.sh"), "Missing external wrapper in \(path)")
        }
    }

    func testPinnedPublisherReusesMatchingArtifactAndNeverOverwritesConflict() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("travel-cat-publisher-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let canonical = root.appendingPathComponent("canonical-travelcatctl")
        let original = Data("#!/bin/sh\nprintf original\n".utf8)
        try original.write(to: canonical)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: canonical.path)
        let pinnedRoot = root.appendingPathComponent("pinned", isDirectory: true)
        let publisher = projectRoot.appendingPathComponent("Scripts/publish-pinned-travelcatctl.sh")

        let first = try run(publisher, [canonical.path, pinnedRoot.path])
        XCTAssertEqual(first.status, 0, first.stderr)
        let pinned = URL(fileURLWithPath: first.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(try Data(contentsOf: pinned), original)
        let preservedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: preservedDate], ofItemAtPath: pinned.path)

        let second = try run(publisher, [canonical.path, pinnedRoot.path])
        XCTAssertEqual(second.status, 0, second.stderr)
        let secondAttributes = try FileManager.default.attributesOfItem(atPath: pinned.path)
        XCTAssertEqual((secondAttributes[.modificationDate] as? Date)?.timeIntervalSince1970, preservedDate.timeIntervalSince1970)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pinned.deletingLastPathComponent().path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pinned.path)
        let conflicting = Data("#!/bin/sh\nprintf conflict\n".utf8)
        try conflicting.write(to: pinned)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: pinned.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: pinned.deletingLastPathComponent().path)
        let conflict = try run(publisher, [canonical.path, pinnedRoot.path])
        XCTAssertNotEqual(conflict.status, 0)
        XCTAssertEqual(try Data(contentsOf: pinned), conflicting, "Conflict must fail closed, not be overwritten")
    }

    func testScheduledPromptAndPublicDocsStatePortableHeartbeatBoundaries() throws {
        let prompt = try String(
            contentsOf: projectRoot.appendingPathComponent("Automation/prompts/scheduled-task.md"),
            encoding: .utf8
        )
        XCTAssertFalse(prompt.contains("/Users/"))
        XCTAssertFalse(prompt.contains(".worktrees"))
        XCTAssertTrue(prompt.contains("NO_REPLY"))
        XCTAssertTrue(prompt.contains("pending-images"))
        XCTAssertTrue(prompt.contains("frozen character profile"))
        XCTAssertFalse(prompt.localizedCaseInsensitiveContains("standalone cron"))

        let docs = try String(
            contentsOf: projectRoot.appendingPathComponent("docs/installation.md"),
            encoding: .utf8
        )
        for token in [
            "每 15 分钟", "NO_REPLY", "runtime.dataRoot", "自定义宠物", "Gatekeeper",
        ] {
            XCTAssertTrue(docs.localizedCaseInsensitiveContains(token), "Public docs are missing: \(token)")
        }
        XCTAssertFalse(docs.contains("019ff02c-f697-7d00-9009-31f5d49fe5e4"))
        XCTAssertFalse(docs.localizedCaseInsensitiveContains("default model"))
        XCTAssertFalse(docs.localizedCaseInsensitiveContains("default sandbox"))
    }

    private func makeSignedFixtureApp(at app: URL, bundleID: String) throws {
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let executable = macOS.appendingPathComponent("TravelCatApp")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "TravelCatApp",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))
        let signing = try run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--sign", "-", app.path])
        XCTAssertEqual(signing.status, 0, signing.stderr)
    }

    private func makeBundledLauncherFixture(dataRoot: Any?) throws -> (app: URL, launcher: URL) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("travel-cat-bundled-launcher-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let app = container.appendingPathComponent("Travel Cat.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let helpers = contents.appendingPathComponent("Helpers", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        let launcher = resources.appendingPathComponent("run-travelcatctl")
        try FileManager.default.copyItem(
            at: projectRoot.appendingPathComponent("Scripts/run-bundled-travelcatctl.sh"),
            to: launcher
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: launcher.path)

        let helper = helpers.appendingPathComponent("travelcatctl")
        let helperSource = container.appendingPathComponent("fixture-helper.c")
        try Data("""
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        int main(int argc, char **argv) {
            const char *root = getenv("TRAVEL_CAT_DATA");
            const char *resources = getenv("TRAVEL_CAT_BUNDLED_RESOURCES_ROOT");
            if (argc > 1 && !strcmp(argv[1], "install-default-pet")) {
                root = getenv("TRAVEL_CAT_DEFAULT_PETS_ROOT");
                resources = getenv("TRAVEL_CAT_DEFAULT_PET_RESOURCES_ROOT");
            }
            printf("%s\\n%s\\n", argc > 1 ? argv[1] : "", root ? root : "");
            if (resources) printf("%s\\n", resources);
            return 0;
        }
        """.utf8).write(to: helperSource)
        let compilation = try run(
            URL(fileURLWithPath: "/usr/bin/xcrun"),
            ["clang", helperSource.path, "-o", helper.path]
        )
        XCTAssertEqual(compilation.status, 0, compilation.stderr)
        let nestedSigning = try run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            ["--force", "--sign", "-", helper.path]
        )
        XCTAssertEqual(nestedSigning.status, 0, nestedSigning.stderr)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: helper.path)
        let digest = try sha256(helper)
        let provenance = """
        format=travel-cat-cli-provenance-v3
        product=travelcatctl
        configuration=release
        sourceTreeSHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        binarySHA256=\(digest)
        binaryArtifactID=\(digest)/travelcatctl
        """
        try Data((provenance + "\n").utf8).write(
            to: resources.appendingPathComponent("travelcatctl-release.provenance")
        )

        var plist: [String: Any] = [
            "CFBundleIdentifier": "com.nebulae.travelcat",
            "CFBundleExecutable": "travelcatctl",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
        ]
        if let dataRoot { plist["TravelCatDataRoot"] = dataRoot }
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))
        let signing = try run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--sign", "-", app.path])
        XCTAssertEqual(signing.status, 0, signing.stderr)
        let canonicalApp = app.path.hasPrefix("/var/")
            ? URL(fileURLWithPath: "/private\(app.path)")
            : app
        return (
            canonicalApp,
            canonicalApp.appendingPathComponent("Contents/Resources/run-travelcatctl")
        )
    }

    private func bundleIdentifier(at app: URL) throws -> String {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        return try XCTUnwrap(plist["CFBundleIdentifier"] as? String)
    }

    private func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String] = [:]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func sha256(_ url: URL) throws -> String {
        let result = try run(URL(fileURLWithPath: "/usr/bin/shasum"), ["-a", "256", url.path])
        XCTAssertEqual(result.status, 0, result.stderr)
        return try XCTUnwrap(result.stdout.split(separator: " ").first.map(String.init))
    }
}
