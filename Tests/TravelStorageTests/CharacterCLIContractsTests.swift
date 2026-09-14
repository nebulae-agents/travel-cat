import CoreGraphics
import Darwin
import Foundation
import ImageIO
import XCTest
import TravelCore
@testable import TravelStorage

final class CharacterCLIContractsTests: XCTestCase {
    func testRequestParserAcceptsOnlyExactDefaultAndAbsoluteImportShapes() throws {
        XCTAssertEqual(try CharacterConfigurationRequest.decode(Data(#"{"action":"default"}"#.utf8)), .default)
        XCTAssertEqual(
            try CharacterConfigurationRequest.decode(Data(#"{"action":"import","directory":"/tmp/pet"}"#.utf8)),
            .import(directory: URL(fileURLWithPath: "/tmp/pet"))
        )

        for invalid in [
            #"{"action":"default","directory":"/tmp/pet"}"#,
            #"{"action":"import"}"#,
            #"{"action":"import","directory":"relative/pet"}"#,
            #"{"action":"import","directory":42}"#,
            #"{"action":"other"}"#,
            #"{"action":"default","unknown":true}"#,
            #"{"action":"default","action":"import","directory":"/tmp/pet"}"#,
        ] {
            XCTAssertThrowsError(try CharacterConfigurationRequest.decode(Data(invalid.utf8)), invalid)
        }
        XCTAssertThrowsError(try CharacterConfigurationRequest.decode(Data(repeating: 0x20, count: 65_537)))
    }

    func testCharacterAndConfigurationRoundTripsPreserveFrozenEffectiveProfile() throws {
        let fixture = Fixture()
        let aDirectory = try fixture.characterFolder(slug: "a", displayName: "A")
        let configuredA = try fixture.runCLI("configure-character", input: request(action: "import", directory: aDirectory.path))
        XCTAssertEqual(configuredA.status, 0)
        let aResponse = try JSONDecoder.travelCat.decode(CharacterConfigurationResponse.self, from: configuredA.output)
        XCTAssertEqual(aResponse.selectedProfile.displayName, "A")
        XCTAssertEqual(aResponse.effectiveProfile.displayName, "A")
        XCTAssertEqual(aResponse.dataRoot, fixture.dataRoot.standardizedFileURL.path)

        let claimDate = Date(timeIntervalSince1970: 2_000_000_000)
        _ = try TravelRepository(root: fixture.dataRoot, clock: FixedClock(now: claimDate))
            .claimDue(mode: .fast, now: claimDate)

        let bDirectory = try fixture.characterFolder(slug: "b", displayName: "B")
        XCTAssertEqual(try fixture.runCLI("configure-character", input: request(action: "import", directory: bDirectory.path)).status, 0)
        let read = try fixture.runCLI("character", input: Data())
        XCTAssertEqual(read.status, 0)
        let response = try JSONDecoder.travelCat.decode(CharacterConfigurationResponse.self, from: read.output)
        XCTAssertEqual(response.selectedProfile.displayName, "B")
        XCTAssertEqual(response.effectiveProfile.displayName, "A")

        let reset = try fixture.runCLI("configure-character", input: request(action: "default"))
        XCTAssertEqual(reset.status, 0)
        XCTAssertEqual(try JSONDecoder.travelCat.decode(CharacterConfigurationResponse.self, from: reset.output).selectedProfile, .defaultBlackCat)
    }

    func testInvalidImportAndOversizeInputDoNotChangeSelection() throws {
        let fixture = Fixture()
        let selected = try fixture.characterFolder(slug: "selected", displayName: "Selected")
        XCTAssertEqual(try fixture.runCLI("configure-character", input: request(action: "import", directory: selected.path)).status, 0)

        let missing = fixture.root.appendingPathComponent("missing")
        XCTAssertNotEqual(try fixture.runCLI("configure-character", input: request(action: "import", directory: missing.path)).status, 0)
        XCTAssertNotEqual(try fixture.runCLI("configure-character", input: Data(repeating: 0x20, count: 65_537)).status, 0)

        let response = try JSONDecoder.travelCat.decode(
            CharacterConfigurationResponse.self,
            from: fixture.runCLI("character", input: Data()).output
        )
        XCTAssertEqual(response.selectedProfile.displayName, "Selected")
    }

    func testBusyRepositoryReturnsTemporaryFailureWithoutChangingSelection() throws {
        let fixture = Fixture()
        let selected = try fixture.characterFolder(slug: "busy-selected", displayName: "Selected")
        XCTAssertEqual(try fixture.runCLI("configure-character", input: request(action: "import", directory: selected.path)).status, 0)
        let selectionURL = fixture.dataRoot.appendingPathComponent("state/active-character.json")
        let before = try Data(contentsOf: selectionURL)
        let descriptor = open(fixture.dataRoot.appendingPathComponent(".repository.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        defer { _ = close(descriptor) }

        let result = try fixture.runCLI("configure-character", input: request(action: "default"))

        XCTAssertEqual(result.status, 75)
        XCTAssertEqual(String(decoding: result.error, as: UTF8.self), "travelcatctl: repository busy\n")
        XCTAssertEqual(try Data(contentsOf: selectionURL), before)
    }

    func testCorruptRepositoryDoesNotChangeSelection() throws {
        let fixture = Fixture()
        let selected = try fixture.characterFolder(slug: "corrupt-selected", displayName: "Selected")
        XCTAssertEqual(try fixture.runCLI("configure-character", input: request(action: "import", directory: selected.path)).status, 0)
        let selectionURL = fixture.dataRoot.appendingPathComponent("state/active-character.json")
        let before = try Data(contentsOf: selectionURL)
        try Data("not-json".utf8).write(to: fixture.dataRoot.appendingPathComponent("state/current-trip.json"))

        let result = try fixture.runCLI("configure-character", input: request(action: "default"))

        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(try Data(contentsOf: selectionURL), before)
    }

    private func request(action: String, directory: String? = nil) throws -> Data {
        var object = ["action": action]
        if let directory { object["directory"] = directory }
        return try JSONSerialization.data(withJSONObject: object)
    }
}

private final class Fixture {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("CharacterCLIContractsTests-\(UUID().uuidString)")
    lazy var dataRoot = root.appendingPathComponent("data")
    deinit { try? FileManager.default.removeItem(at: root) }

    func characterFolder(slug: String, displayName: String) throws -> URL {
        let directory = root.appendingPathComponent("inputs/\(slug)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "displayName": displayName, "description": "A travelling cat.",
            "spriteVersionNumber": 2, "spritesheetPath": "sprite.webp",
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("pet.json"))
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(
            at: projectRoot.appendingPathComponent("Sources/TravelUI/Resources/cute-black-cat-spritesheet.webp"),
            to: directory.appendingPathComponent("sprite.webp")
        )
        return directory
    }

    func runCLI(_ command: String, input: Data) throws -> (status: Int32, output: Data, error: Data) {
        let process = Process()
        process.executableURL = Bundle(for: CharacterCLIContractsTests.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("travelcatctl")
        process.arguments = [command]
        var environment = ProcessInfo.processInfo.environment
        environment["TRAVEL_CAT_DATA"] = dataRoot.path
        environment["TRAVEL_CAT_MODE"] = "fast"
        environment["TRAVEL_CAT_NOW"] = "2033-05-18T03:33:20.000Z"
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: input)
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            stdout.fileHandleForReading.readDataToEndOfFile(),
            stderr.fileHandleForReading.readDataToEndOfFile()
        )
    }
}
