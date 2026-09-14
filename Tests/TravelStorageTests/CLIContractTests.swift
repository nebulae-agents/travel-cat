import Foundation
import Darwin
import XCTest
import CoreGraphics
import ImageIO
import TravelCore
@testable import TravelStorage

final class CLIContractTests: XCTestCase {
    func testValidateCandidateReportsBusyWhileClaimKeepsQuietOverlapBehavior() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try TravelRepository(root: root)
        let lockDescriptor = open(root.appendingPathComponent(".repository.lock").path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(lockDescriptor, 0)
        XCTAssertEqual(flock(lockDescriptor, LOCK_EX | LOCK_NB), 0)
        defer { _ = close(lockDescriptor) }
        let candidate = try Data(contentsOf: projectRoot.appendingPathComponent("Automation/fixtures/valid-kamakura-event.json"))

        let busy = try runCLI(
            root: root,
            command: "validate-candidate",
            standardInput: candidate
        )
        XCTAssertEqual(busy.status, 75)
        let result = try JSONDecoder.travelCat.decode(ValidationResult.self, from: busy.output)
        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.violations, ["repositoryBusy"])
        XCTAssertEqual(result.stateVersion, -1)
        XCTAssertNil(result.publishEnvelope)
        let busyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: busy.output) as? [String: Any])
        XCTAssertEqual(Set(busyObject.keys), ["valid", "violations", "stateVersion"])

        let quiet = try runCLI(root: root, command: "claim", standardInput: Data())
        XCTAssertEqual(quiet.status, 0)
        XCTAssertTrue(quiet.output.isEmpty)
    }

    func testConfigurationUsesProjectRelativeRootAndDailyModeByDefault() throws {
        let now = Date(timeIntervalSince1970: 42)
        let configuration = try TravelCLIConfiguration(
            environment: [:],
            currentDirectory: URL(fileURLWithPath: "/tmp/project"),
            currentDate: now
        )

        XCTAssertEqual(configuration.root.path, "/tmp/project/TravelPetData")
        XCTAssertEqual(configuration.mode, .daily)
        XCTAssertEqual(configuration.now, now)
    }

    func testConfigurationAcceptsFastModeEnvironmentRootAndDeterministicTime() throws {
        let configuration = try TravelCLIConfiguration(
            environment: [
                "TRAVEL_CAT_DATA": "/tmp/data/../travel",
                "TRAVEL_CAT_MODE": "fast",
                "TRAVEL_CAT_NOW": "2026-08-10T10:20:30.000Z",
            ],
            currentDirectory: URL(fileURLWithPath: "/ignored"),
            currentDate: Date.distantFuture
        )

        XCTAssertEqual(configuration.root, URL(fileURLWithPath: "/tmp/travel"))
        XCTAssertEqual(configuration.mode, .fast)
        XCTAssertEqual(configuration.now, Date(timeIntervalSince1970: 1_786_357_230))
        XCTAssertEqual(configuration.runtime.dataRoot, "/tmp/travel")
        XCTAssertNil(configuration.runtime.bundledResourcesRoot)
    }

    func testConfigurationCarriesOptionalBundledResourcesRootAndCLIEnrichesClaim() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try TravelRepository(root: root)
        let bundleRoot = "/tmp/Travel Cat Resources/TravelCat_TravelUI.bundle"
        let result = try runCLI(
            root: root, command: "claim", standardInput: Data(),
            extraEnvironment: ["TRAVEL_CAT_BUNDLED_RESOURCES_ROOT": bundleRoot])
        XCTAssertEqual(result.status, 0)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
        let runtime = try XCTUnwrap(object["runtime"] as? [String: String])
        XCTAssertEqual(runtime["dataRoot"], root.path)
        XCTAssertEqual(runtime["bundledResourcesRoot"], bundleRoot)

        let journal = try runCLI(
            root: root, command: "journal", standardInput: Data(),
            extraEnvironment: ["TRAVEL_CAT_BUNDLED_RESOURCES_ROOT": bundleRoot])
        let journalObject = try XCTUnwrap(JSONSerialization.jsonObject(with: journal.output) as? [String: Any])
        XCTAssertEqual(journalObject["runtime"] as? [String: String], runtime)

        let pending = try runCLI(
            root: root, command: "pending-images", standardInput: Data(),
            extraEnvironment: ["TRAVEL_CAT_BUNDLED_RESOURCES_ROOT": bundleRoot])
        XCTAssertEqual(try JSONDecoder().decode([PendingImageWork].self, from: pending.output), [])
    }

    func testRuntimeMetadataLegacyDecodeAndEnrichmentPreservePendingLeaseFields() throws {
        let event = TripEvent.fixture()
        let legacyClaimData = try JSONEncoder.travelCat.encode(
            DueClaim(due: true, snapshot: .fixture(), previousEvent: event))
        XCTAssertNil(try JSONDecoder.travelCat.decode(DueClaim.self, from: legacyClaimData).runtime)
        let legacyClaimObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: legacyClaimData) as? [String: Any])
        XCTAssertFalse(legacyClaimObject.keys.contains("runtime"))
        let legacyJournalData = try JSONEncoder.travelCat.encode(TravelJournalView(
            snapshot: .fixture(), currentEvent: nil, latestReadyPostcard: nil,
            postcardCount: 0, album: []))
        XCTAssertNil(
            try JSONDecoder.travelCat.decode(TravelJournalView.self, from: legacyJournalData).runtime)

        let retry = ImageRetry(
            attemptCount: 2, retryAt: nil, publishedNarrativeHash: String(repeating: "a", count: 64),
            activeAttemptToken: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            leaseExpiresAt: Date(timeIntervalSince1970: 500))
        let work = PendingImageWork(event: event, retry: retry)
        let legacyWorkData = try JSONEncoder.travelCat.encode(work)
        XCTAssertNil(try JSONDecoder.travelCat.decode(PendingImageWork.self, from: legacyWorkData).runtime)
        let runtime = TravelRuntimeMetadata(dataRoot: "/tmp/data", bundledResourcesRoot: "/tmp/ui.bundle")
        let enriched = work.enriched(runtime: runtime)
        XCTAssertEqual(enriched.runtime, runtime)
        XCTAssertEqual(enriched.event, work.event)
        XCTAssertEqual(enriched.characterProfile, work.characterProfile)
        XCTAssertEqual(enriched.imageAttemptCount, work.imageAttemptCount)
        XCTAssertEqual(enriched.retryAt, work.retryAt)
        XCTAssertEqual(enriched.publishedNarrativeHash, work.publishedNarrativeHash)
        XCTAssertEqual(enriched.attemptToken, work.attemptToken)
        XCTAssertEqual(enriched.leaseExpiresAt, work.leaseExpiresAt)
    }

    func testConfigurationRejectsInvalidModeAndTime() {
        XCTAssertThrowsError(try TravelCLIConfiguration(
            environment: ["TRAVEL_CAT_MODE": "weekly"],
            currentDirectory: URL(fileURLWithPath: "/tmp"),
            currentDate: Date()
        )) { error in
            guard case CLIConfigurationError.invalidMode("weekly") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(try TravelCLIConfiguration(
            environment: ["TRAVEL_CAT_BUNDLED_RESOURCES_ROOT": "relative/ui.bundle"],
            currentDirectory: URL(fileURLWithPath: "/tmp"),
            currentDate: Date()
        )) { error in
            guard case CLIConfigurationError.invalidBundledResourcesRoot("relative/ui.bundle") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(try TravelCLIConfiguration(
            environment: ["TRAVEL_CAT_NOW": "tomorrow"],
            currentDirectory: URL(fileURLWithPath: "/tmp"),
            currentDate: Date()
        )) { error in
            guard case CLIConfigurationError.invalidNow("tomorrow") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testEmptyModeOverrideFallsBackToPersistedSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try TravelSettingsStore(root: root).save(TravelSettings(mode: .fast))
        let configuration = try TravelCLIConfiguration(
            environment: ["TRAVEL_CAT_DATA": root.path, "TRAVEL_CAT_MODE": ""],
            currentDirectory: URL(fileURLWithPath: "/ignored")
        )

        XCTAssertEqual(try configuration.resolvedMode(), .fast)
    }

    func testPublishAndMarkImageEnvelopesHaveStableJSONKeys() throws {
        let event = TripEvent.fixture()
        let next = TripSnapshot.fixture(stateVersion: 1, tripID: event.tripID, lastEventID: event.id)
        let publish = try JSONSerialization.jsonObject(
            with: JSONEncoder.travelCat.encode(PublishEnvelope(event: event, next: next))
        ) as? [String: Any]
        XCTAssertEqual(Set(publish?.keys.map { $0 } ?? []), ["event", "next"])

        let mark = try JSONSerialization.jsonObject(
            with: JSONEncoder.travelCat.encode(ImageResultEnvelope(
                eventId: event.id,
                status: .failed,
                attemptedAt: Date(timeIntervalSince1970: 100),
                relativePath: nil,
                reason: "network",
                attemptToken: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                attemptCount: 0,
                publishedNarrativeHash: String(repeating: "a", count: 64)
            ))
        ) as? [String: Any]
        XCTAssertEqual(Set(mark?.keys.map { $0 } ?? []), ["eventId", "status", "attemptedAt", "reason", "attemptToken", "attemptCount", "publishedNarrativeHash"])
    }

    func testJournalCommandIsReadOnlyAndReturnsStableKeys() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try TravelRepository(root: root)
        let first = TripEvent.fixture(
            occurredAt: Date(timeIntervalSince1970: 10),
            phase: .preparing
        )
        let firstNext = TripSnapshot.fixture(
            stateVersion: 1,
            tripID: first.tripID,
            lastEventID: first.id,
            phase: first.phase
        )
        try repository.publish(event: first, next: firstNext)
        let second = TripEvent.fixture(
            tripID: first.tripID,
            previousEventID: first.id,
            occurredAt: Date(timeIntervalSince1970: 20),
            phase: .transit,
            place: "Uragami"
        )
        let secondNext = TripSnapshot.fixture(
            stateVersion: 2,
            tripID: first.tripID,
            lastEventID: second.id,
            phase: .transit
        )
        try repository.publish(event: second, next: secondNext)
        let third = TripEvent.fixture(
            tripID: first.tripID,
            previousEventID: second.id,
            occurredAt: Date(timeIntervalSince1970: 30),
            phase: .exploring,
            place: "Yuigahama Beach"
        )
        let thirdNext = TripSnapshot.fixture(
            stateVersion: 3,
            tripID: first.tripID,
            lastEventID: third.id,
            phase: .exploring
        )
        try repository.publish(event: third, next: thirdNext)
        let ready = TripEvent.fixture(
            id: UUID(),
            tripID: first.tripID,
            previousEventID: third.id,
            occurredAt: Date(timeIntervalSince1970: 40),
            phase: .postcardReady,
            postcardStatus: .pendingImage
        )
        let readyNext = TripSnapshot.fixture(
            stateVersion: 4,
            tripID: first.tripID,
            lastEventID: ready.id,
            phase: .postcardReady
        )
        try repository.publish(event: ready, next: readyNext)
        let pending = try XCTUnwrap(repository.pendingImages(mode: .fast).first)
        let path = "postcards/\(first.tripID.uuidString.lowercased())/latest.png"
        try writeImage(root.appendingPathComponent(path), width: 768, height: 768)
        _ = try repository.markImage(
            .init(
                eventId: pending.event.id,
                status: .ready,
                attemptedAt: Date(timeIntervalSince1970: 300),
                relativePath: path,
                reason: nil,
                attemptToken: pending.attemptToken,
                attemptCount: pending.imageAttemptCount,
                publishedNarrativeHash: pending.publishedNarrativeHash
            ),
            mode: .fast
        )

        let beforeOutput = try repository.events()
        let result = try runCLI(
            root: root,
            command: "journal",
            standardInput: Data()
        )
        XCTAssertEqual(result.status, 0)

        let afterOutput = try repository.events()
        XCTAssertEqual(beforeOutput, afterOutput)
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
        XCTAssertEqual(Set(output.keys), ["snapshot", "currentEvent", "latestReadyPostcard", "postcardCount", "album", "runtime"])

        let view = try JSONDecoder.travelCat.decode(TravelJournalView.self, from: result.output)
        XCTAssertEqual(view.snapshot.stateVersion, 4)
        XCTAssertEqual(view.currentEvent?.id, ready.id)
        XCTAssertEqual(view.latestReadyPostcard?.eventID, ready.id)
        XCTAssertEqual(view.postcardCount, 1)
        XCTAssertEqual(view.album.map(\.eventID), [ready.id])
        XCTAssertEqual(view.latestReadyPostcard?.postcardRelativePath, path)
        XCTAssertEqual(view.runtime?.dataRoot, root.path)
    }

    func testInstallDefaultPetRunsBeforeTravelConfigurationOrRepositoryCreation() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let resources = temporary.appendingPathComponent("Signed Resources", isDirectory: true)
        let codexHome = temporary.appendingPathComponent("Codex Home", isDirectory: true)
        let travelRoot = temporary.appendingPathComponent("must-not-exist", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(
            at: project.appendingPathComponent("Sources/TravelUI/Resources/pet.json"),
            to: resources.appendingPathComponent("pet.json"))
        try FileManager.default.copyItem(
            at: project.appendingPathComponent("Sources/TravelUI/Resources/cute-black-cat-spritesheet.webp"),
            to: resources.appendingPathComponent("cute-black-cat-spritesheet.webp"))

        let result = try runCLI(
            root: travelRoot, command: "install-default-pet", standardInput: Data(),
            extraEnvironment: [
                "TRAVEL_CAT_DEFAULT_PET_RESOURCES_ROOT": resources.path,
                "TRAVEL_CAT_DEFAULT_PETS_ROOT": codexHome.appendingPathComponent("pets").path,
                "TRAVEL_CAT_MODE": "invalid-must-not-be-read",
            ])
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: travelRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: codexHome.appendingPathComponent("pets/cute-black-cat/pet.json").path))
    }

    func testCommandParserRejectsMissingUnknownAndTrailingArguments() throws {
        XCTAssertEqual(try TravelCLICommand.parse(arguments: ["status"]), .status)
        XCTAssertEqual(try TravelCLICommand.parse(arguments: ["claim"]), .claim)
        XCTAssertEqual(try TravelCLICommand.parse(arguments: ["pending-images"]), .pendingImages)
        XCTAssertEqual(try TravelCLICommand.parse(arguments: ["journal"]), .journal)
        XCTAssertEqual(try TravelCLICommand.parse(arguments: ["validate-candidate"]), .validateCandidate)
        XCTAssertEqual(try TravelCLICommand.parse(arguments: ["character"]), .character)
        XCTAssertEqual(try TravelCLICommand.parse(arguments: ["configure-character"]), .configureCharacter)
        XCTAssertThrowsError(try TravelCLICommand.parse(arguments: []))
        XCTAssertThrowsError(try TravelCLICommand.parse(arguments: ["unknown"]))
        XCTAssertThrowsError(try TravelCLICommand.parse(arguments: ["status", "extra"]))
        XCTAssertThrowsError(try TravelCLICommand.parse(arguments: ["publish", "extra"]))
        XCTAssertThrowsError(try TravelCLICommand.parse(arguments: ["journal", "extra"]))
        XCTAssertThrowsError(try TravelCLICommand.parse(arguments: ["validate-candidate", "extra"]))
        XCTAssertThrowsError(try TravelCLICommand.parse(arguments: ["character", "extra"]))
        XCTAssertThrowsError(try TravelCLICommand.parse(arguments: ["configure-character", "extra"]))
    }

    func testLockUnavailableIsTheOnlySilentSuccessError() {
        XCTAssertTrue(TravelCLIErrorPolicy.isSilentSuccess(RepositoryError.lockUnavailable))
        XCTAssertFalse(TravelCLIErrorPolicy.isSilentSuccess(RepositoryError.recoveryRequired))
        XCTAssertFalse(TravelCLIErrorPolicy.isSilentSuccess(RepositoryError.continuityConflict))
    }

    private func runCLI(
        root: URL,
        command: String,
        standardInput: Data,
        extraEnvironment: [String: String] = [:]
    ) throws -> (status: Int32, output: Data) {
        let process = Process()
        let productsDirectory = Bundle(for: CLIContractTests.self).bundleURL.deletingLastPathComponent()
        process.executableURL = productsDirectory.appendingPathComponent("travelcatctl")
        process.arguments = [command]
        var environment = ProcessInfo.processInfo.environment
        environment["TRAVEL_CAT_DATA"] = root.path
        environment["TRAVEL_CAT_MODE"] = "fast"
        for (key, value) in extraEnvironment { environment[key] = value }
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: standardInput)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        return (process.terminationStatus, output.fileHandleForReading.readDataToEndOfFile())
    }

    private func writeImage(_ url: URL, width: Int, height: Int) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
