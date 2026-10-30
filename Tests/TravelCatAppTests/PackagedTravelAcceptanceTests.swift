import Foundation
import XCTest
@testable import TravelCatApp

@MainActor
final class PackagedTravelAcceptanceTests: XCTestCase {
    func testOnlyExactOfflineFlagCanEnterAcceptance() throws {
        XCTAssertFalse(try PackagedTravelAcceptance.isRequested(arguments: []))
        XCTAssertFalse(try PackagedTravelAcceptance.isRequested(arguments: ["-psn_0_123"]))
        XCTAssertFalse(try PackagedTravelAcceptance.isRequested(arguments: ["--unknown"]))
        XCTAssertTrue(try PackagedTravelAcceptance.isRequested(arguments: ["--offline-packaged-acceptance"]))
        for arguments in [["--offline-packaged-acceptance", "/tmp/data"],
                          ["--offline-packaged-acceptance=true"], ["--offline-packaged"],
                          ["--offline-packaged-acceptance", "--offline-packaged-acceptance"],
                          ["--offline-packaged-acceptance", "--provider", "live"]] {
            XCTAssertThrowsError(try PackagedTravelAcceptance.isRequested(arguments: arguments)) {
                XCTAssertEqual($0 as? PackagedTravelAcceptance.Failure, .invalidArguments)
            }
        }
    }

    func testNonAppBundleIsRejectedBeforeSyntheticWork() async {
        do {
            _ = try await PackagedTravelAcceptance.run()
            XCTFail("A test executable is not a packaged app")
        } catch {
            XCTAssertEqual(error as? PackagedTravelAcceptance.Failure, .notPackagedApp)
        }
    }

    func testFailureOutputContainsOnlyFixedClassification() throws {
        let error = NSError(domain: "private/path/provider-secret", code: 7,
                            userInfo: [NSLocalizedDescriptionKey: "private request content"])
        let output = PackagedTravelAcceptance.failureJSON(error)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(result["status"] as? String, "failed")
        XCTAssertEqual(result["code"] as? String, "acceptanceFailed")
        XCTAssertFalse(output.contains("private"))
    }

    func testSyntheticLifecycleUsesResourceCopyAndProductionImageReadback() async throws {
        let result = try await PackagedTravelAcceptance.runSyntheticLifecycle()
        XCTAssertTrue(result.pendingObserved)
        XCTAssertTrue(result.readyObserved)
        XCTAssertTrue(result.readbackVerified)
        XCTAssertGreaterThan(result.narrativeCalls, 0)
        XCTAssertEqual(result.imageCalls, 1)
        XCTAssertEqual(result.copiedResourceCount, 6)
    }
}
