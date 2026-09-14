import XCTest
import Darwin
@testable import TravelCatApp

final class SingleInstancePolicyTests: XCTestCase {
    func testNoRunningApplicationsMakesCurrentProcessPrimary() {
        XCTAssertEqual(
            SingleInstancePolicy.decision(
                currentPID: 10,
                expectedBundleID: "com.nebulae.travelcat",
                running: []
            ),
            .primary
        )
    }

    func testCurrentProcessIsExcludedFromDuplicateDetection() {
        XCTAssertEqual(
            SingleInstancePolicy.decision(
                currentPID: 10,
                expectedBundleID: "com.nebulae.travelcat",
                running: [
                    .init(processIdentifier: 10, bundleIdentifier: "com.nebulae.travelcat"),
                ]
            ),
            .primary
        )
    }

    func testMatchingForeignProcessMakesCurrentProcessSecondary() {
        XCTAssertEqual(
            SingleInstancePolicy.decision(
                currentPID: 10,
                expectedBundleID: "com.nebulae.travelcat",
                running: [
                    .init(processIdentifier: 11, bundleIdentifier: "com.nebulae.travelcat"),
                ]
            ),
            .secondary(existingPID: 11)
        )
    }

    func testUnrelatedBundleIdentifierIsIgnored() {
        XCTAssertEqual(
            SingleInstancePolicy.decision(
                currentPID: 10,
                expectedBundleID: "com.nebulae.travelcat",
                running: [
                    .init(processIdentifier: 11, bundleIdentifier: "other"),
                ]
            ),
            .primary
        )
    }

    func testMissingExpectedBundleIdentifierFailsClosed() {
        XCTAssertEqual(
            SingleInstancePolicy.decision(
                currentPID: 10,
                expectedBundleID: nil,
                running: []
            ),
            .secondary(existingPID: nil)
        )
    }

    func testMultipleMatchingProcessesChooseLowestProcessIdentifierRegardlessOfOrdering() {
        let ascending: [RunningApplicationIdentity] = [
            .init(processIdentifier: 19, bundleIdentifier: "com.nebulae.travelcat"),
            .init(processIdentifier: 11, bundleIdentifier: "com.nebulae.travelcat"),
            .init(processIdentifier: 15, bundleIdentifier: "com.nebulae.travelcat"),
        ]

        for running in [ascending, Array(ascending.reversed())] {
            XCTAssertEqual(
                SingleInstancePolicy.decision(
                    currentPID: 10,
                    expectedBundleID: "com.nebulae.travelcat",
                    running: running
                ),
                .secondary(existingPID: 11)
            )
        }
    }
}

final class SingleInstanceLockTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("travel-cat-instance-lock-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    func testTwoAcquisitionsCannotBothOwnTheSameLock() throws {
        let lockURL = temporaryDirectory.appendingPathComponent("instance.lock")

        let first = try XCTUnwrap(SingleInstanceLock.acquire(at: lockURL))
        XCTAssertNil(SingleInstanceLock.acquire(at: lockURL))
        withExtendedLifetime(first) {}
    }

    func testReleasingOwnerPermitsReacquisition() throws {
        let lockURL = temporaryDirectory.appendingPathComponent("instance.lock")
        var first: SingleInstanceLock? = try XCTUnwrap(SingleInstanceLock.acquire(at: lockURL))

        XCTAssertNotNil(first)
        XCTAssertNil(SingleInstanceLock.acquire(at: lockURL))
        first = nil

        XCTAssertNotNil(SingleInstanceLock.acquire(at: lockURL))
    }

    func testSymlinkTargetFailsClosedWithoutMutatingDestination() throws {
        let destination = temporaryDirectory.appendingPathComponent("destination")
        let original = Data("do not change".utf8)
        try original.write(to: destination)
        let lockURL = temporaryDirectory.appendingPathComponent("instance.lock")
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: destination)

        XCTAssertNil(SingleInstanceLock.acquire(at: lockURL))
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: lockURL.path), destination.path)
    }

    func testNonregularTargetFailsClosedWithoutReplacingIt() throws {
        let lockURL = temporaryDirectory.appendingPathComponent("instance.lock", isDirectory: true)
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)

        XCTAssertNil(SingleInstanceLock.acquire(at: lockURL))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testInsecureExistingTargetFailsClosedWithoutChangingBytesOrPermissions() throws {
        let lockURL = temporaryDirectory.appendingPathComponent("instance.lock")
        let original = Data("existing content".utf8)
        try original.write(to: lockURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lockURL.path)

        XCTAssertNil(SingleInstanceLock.acquire(at: lockURL))
        XCTAssertEqual(try Data(contentsOf: lockURL), original)
        let attributes = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o644)
    }

    func testHardlinkedTargetFailsClosedWithoutChangingEitherLink() throws {
        let lockURL = temporaryDirectory.appendingPathComponent("instance.lock")
        let otherLink = temporaryDirectory.appendingPathComponent("other-link")
        let original = Data("linked content".utf8)
        try original.write(to: lockURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lockURL.path)
        XCTAssertEqual(link(lockURL.path, otherLink.path), 0)
        let preconditionAttributes = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        XCTAssertEqual(preconditionAttributes[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(preconditionAttributes[.referenceCount] as? Int, 2)

        XCTAssertNil(SingleInstanceLock.acquire(at: lockURL))
        XCTAssertEqual(try Data(contentsOf: lockURL), original)
        XCTAssertEqual(try Data(contentsOf: otherLink), original)
        let attributes = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(attributes[.referenceCount] as? Int, 2)
    }

    func testIndependentProcessesRaceThenCrashReleasesOwnership() throws {
        try SubprocessLockHarness.assertRaceAndCrashRelease(in: temporaryDirectory)
    }

    func testExecDoesNotInheritOwnershipDescriptor() throws {
        try SubprocessLockHarness.assertCloseOnExec(in: temporaryDirectory)
    }
}
