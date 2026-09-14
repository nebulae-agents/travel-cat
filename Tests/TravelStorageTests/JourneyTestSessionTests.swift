import XCTest
@testable import TravelStorage

final class JourneyTestSessionTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var parent: URL!
    private var productionRoot: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JourneyTestSessionTests-\(UUID().uuidString)", isDirectory: true)
        parent = temporaryDirectory.appendingPathComponent("JourneyTests", isDirectory: true)
        productionRoot = temporaryDirectory.appendingPathComponent("Production", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: productionRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }

    func testCreateUsesCanonicalLowercaseUUIDAndOwnershipManifest() throws {
        let id = UUID(uuidString: "AABBCCDD-EEFF-0011-2233-445566778899")!
        let session = try JourneyTestSession.create(parent: parent, productionRoot: productionRoot, id: id)

        XCTAssertEqual(session.id, id)
        XCTAssertEqual(session.root.lastPathComponent, id.uuidString.lowercased())
        XCTAssertTrue(session.root.isFileURL)
        XCTAssertTrue(session.root.path.hasPrefix(parent.path + "/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.root.path))
        let manifest = session.root.appendingPathComponent(".journey-test-session.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
        XCTAssertNoThrow(try session.validate())
    }

    func testCreateMakesUniqueSessionsWithoutTouchingProduction() throws {
        let first = try JourneyTestSession.create(parent: parent, productionRoot: productionRoot)
        let second = try JourneyTestSession.create(parent: parent, productionRoot: productionRoot)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.root, second.root)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: productionRoot.path).count, 0)
    }

    func testRejectsNonPlainAbsoluteFileURLs() throws {
        var queryComponents = URLComponents(url: parent, resolvingAgainstBaseURL: false)!
        queryComponents.query = "query=value"
        let query = queryComponents.url!
        var fragmentComponents = URLComponents(url: parent, resolvingAgainstBaseURL: false)!
        fragmentComponents.fragment = "fragment"
        let fragment = fragmentComponents.url!
        let relative = URL(string: "JourneyTests", relativeTo: temporaryDirectory)
        let relativeFile = URL(string: parent.path, relativeTo: temporaryDirectory)
        let host = URL(string: "file://host\(parent.path)")!
        XCTAssertThrowsError(try JourneyTestSession.create(parent: query, productionRoot: productionRoot))
        XCTAssertThrowsError(try JourneyTestSession.create(parent: fragment, productionRoot: productionRoot))
        XCTAssertThrowsError(try JourneyTestSession.create(parent: relative!, productionRoot: productionRoot))
        XCTAssertThrowsError(try JourneyTestSession.create(parent: relativeFile!, productionRoot: productionRoot))
        XCTAssertThrowsError(try JourneyTestSession.create(parent: host, productionRoot: productionRoot))
    }

    func testValidateRejectsParentAndProductionReplacement() throws {
        let session = try JourneyTestSession.create(parent: parent, productionRoot: productionRoot)
        let outside = temporaryDirectory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        try FileManager.default.removeItem(at: productionRoot)
        try FileManager.default.createSymbolicLink(at: productionRoot, withDestinationURL: outside)
        assertError(.symlinkNotAllowed) { try session.validate() }

        try FileManager.default.removeItem(at: productionRoot)
        try FileManager.default.createDirectory(at: productionRoot, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
        assertError(.symlinkNotAllowed) { try session.validate() }
    }

    func testRejectsProductionRootWithSymlinkedAncestor() throws {
        let realProduction = temporaryDirectory.appendingPathComponent("real-production", isDirectory: true)
        try FileManager.default.createDirectory(at: realProduction, withIntermediateDirectories: true)
        let linkedAncestor = temporaryDirectory.appendingPathComponent("production-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedAncestor, withDestinationURL: realProduction)
        let symlinkedProduction = linkedAncestor.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: realProduction.appendingPathComponent("nested", isDirectory: true), withIntermediateDirectories: true)

        assertError(.symlinkNotAllowed) {
            try JourneyTestSession.create(parent: parent, productionRoot: symlinkedProduction)
        }
    }

    func testValidateRejectsRegularDirectoryReplacement() throws {
        let session = try JourneyTestSession.create(parent: parent, productionRoot: productionRoot)
        let productionOld = temporaryDirectory.appendingPathComponent("Production-old", isDirectory: true)
        try FileManager.default.moveItem(at: productionRoot, to: productionOld)
        try FileManager.default.createDirectory(at: productionRoot, withIntermediateDirectories: true)
        assertError(.invalidSession) { try session.validate() }

        // Recreate a clean context, then replace the session directory with a copy carrying its manifest.
        let secondParent = temporaryDirectory.appendingPathComponent("second", isDirectory: true)
            .appendingPathComponent("JourneyTests", isDirectory: true)
        let secondProduction = temporaryDirectory.appendingPathComponent("second-production", isDirectory: true)
        try FileManager.default.createDirectory(at: secondParent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondProduction, withIntermediateDirectories: true)
        let second = try JourneyTestSession.create(parent: secondParent, productionRoot: secondProduction)
        let sessionOld = temporaryDirectory.appendingPathComponent("session-old", isDirectory: true)
        try FileManager.default.moveItem(at: second.root, to: sessionOld)
        try FileManager.default.copyItem(at: sessionOld, to: second.root)
        assertError(.invalidSession) { try second.validate() }
    }

    func testCreateIsExclusiveAndPreservesExistingSession() throws {
        let id = UUID()
        let existing = parent.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let marker = existing.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)

        XCTAssertThrowsError(try JourneyTestSession.create(parent: parent, productionRoot: productionRoot, id: id))
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
    }

    func testOpenReopensAndValidateRejectsForgedOrMissingManifest() throws {
        let created = try JourneyTestSession.create(parent: parent, productionRoot: productionRoot)
        let uncanonicalRoot = URL(fileURLWithPath: parent.path + "/../JourneyTests/" + created.id.uuidString.lowercased())
        XCTAssertNotEqual(uncanonicalRoot.path, uncanonicalRoot.standardizedFileURL.path)
        let reopened = try JourneyTestSession.open(root: uncanonicalRoot, parent: parent, productionRoot: productionRoot)
        XCTAssertEqual(reopened.id, created.id)
        XCTAssertEqual(reopened.root, created.root.standardizedFileURL)
        XCTAssertNoThrow(try reopened.validate())

        let manifest = created.root.appendingPathComponent(".journey-test-session.json")
        try FileManager.default.removeItem(at: manifest)
        XCTAssertThrowsError(try JourneyTestSession.open(root: created.root, parent: parent, productionRoot: productionRoot))

        let forged = try JourneyTestSession.create(parent: parent, productionRoot: productionRoot)
        try Data("{\"version\":1,\"id\":\"00000000-0000-0000-0000-000000000000\"}".utf8).write(
            to: forged.root.appendingPathComponent(".journey-test-session.json"), options: .atomic)
        XCTAssertThrowsError(try forged.validate())
    }

    func testOpenRejectsExternalUUIDDirectoryBeforeReadingManifest() throws {
        let externalRoot = temporaryDirectory.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)

        assertError(.invalidSession) {
            try JourneyTestSession.open(root: externalRoot, parent: parent, productionRoot: productionRoot)
        }
    }

    func testRejectsProductionOverlapAndLeavesProductionUnchanged() throws {
        let productionMarker = productionRoot.appendingPathComponent("marker.txt")
        try Data("unchanged".utf8).write(to: productionMarker)

        assertError(.productionOverlap) {
            try JourneyTestSession.create(parent: parent, productionRoot: parent)
        }
        assertError(.productionOverlap) {
            try JourneyTestSession.create(parent: parent, productionRoot: temporaryDirectory)
        }
        let descendant = parent.appendingPathComponent("production-child", isDirectory: true)
        try FileManager.default.createDirectory(at: descendant, withIntermediateDirectories: true)
        assertError(.productionOverlap) {
            try JourneyTestSession.create(parent: parent, productionRoot: descendant)
        }
        XCTAssertEqual(try Data(contentsOf: productionMarker), Data("unchanged".utf8))
    }

    func testRejectsCaseAliasProductionOverlapOnCaseInsensitiveVolume() throws {
        let parentAlias = temporaryDirectory.appendingPathComponent("journeytests", isDirectory: true)
        guard FileManager.default.fileExists(atPath: parentAlias.path) else {
            throw XCTSkip("The temporary volume is case-sensitive")
        }
        let differentlyCasedChild = parentAlias.appendingPathComponent("production-child", isDirectory: true)
        try FileManager.default.createDirectory(at: differentlyCasedChild, withIntermediateDirectories: true)

        assertError(.productionOverlap) {
            try JourneyTestSession.create(parent: parent, productionRoot: parentAlias)
        }
        assertError(.productionOverlap) {
            try JourneyTestSession.create(parent: parent, productionRoot: differentlyCasedChild)
        }
    }

    func testRejectsPhysicalPrivateAncestorOfTemporaryParent() throws {
        let privateRoot = URL(fileURLWithPath: "/private", isDirectory: true)
        guard FileManager.default.fileExists(atPath: "/private") else {
            throw XCTSkip("The temporary volume is not under macOS /private")
        }

        assertError(.productionOverlap) {
            try JourneyTestSession.create(parent: parent, productionRoot: privateRoot)
        }
    }

    func testRejectsSymlinkedParentSessionAndManifest() throws {
        let realParent = temporaryDirectory.appendingPathComponent("real", isDirectory: true)
            .appendingPathComponent("JourneyTests", isDirectory: true)
        try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: true)
        let parentLink = temporaryDirectory.appendingPathComponent("JourneyTests", isDirectory: true)
        try FileManager.default.removeItem(at: parentLink)
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: realParent)
        assertError(.symlinkNotAllowed) {
            try JourneyTestSession.create(parent: parentLink, productionRoot: productionRoot)
        }

        let clean = try JourneyTestSession.create(parent: realParent, productionRoot: productionRoot)
        let sessionLink = realParent.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createSymbolicLink(at: sessionLink, withDestinationURL: clean.root)
        assertError(.symlinkNotAllowed) {
            try JourneyTestSession.open(root: sessionLink, parent: realParent, productionRoot: productionRoot)
        }

        let manifest = clean.root.appendingPathComponent(".journey-test-session.json")
        let manifestTarget = clean.root.appendingPathComponent("manifest-target.json")
        try FileManager.default.moveItem(at: manifest, to: manifestTarget)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: manifestTarget)
        assertError(.symlinkNotAllowed) { try clean.validate() }
    }

    private func assertError<T>(_ expected: JourneyTestSession.SessionError, file: StaticString = #filePath, line: UInt = #line, _ operation: () throws -> T) {
        do {
            _ = try operation()
            XCTFail("Expected (expected)", file: file, line: line)
        } catch let error as JourneyTestSession.SessionError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}
