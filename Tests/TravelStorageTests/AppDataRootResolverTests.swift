import Foundation
import XCTest
@testable import TravelStorage

final class AppDataRootResolverTests: XCTestCase {
    func testEnvironmentWinsThenDevelopmentRootThenApplicationSupport() {
        let resolver = AppDataRootResolver()
        let support = URL(fileURLWithPath: "/tmp/Library/Application Support")
        XCTAssertEqual(resolver.resolve(environment: ["TRAVEL_CAT_DATA": " /tmp/shared "], developmentProjectRoot: URL(fileURLWithPath: "/project"), applicationSupportDirectory: support).path, "/tmp/shared")
        XCTAssertEqual(resolver.resolve(environment: [:], developmentProjectRoot: URL(fileURLWithPath: "/project"), applicationSupportDirectory: support).path, "/project/TravelPetData")
        XCTAssertEqual(resolver.resolve(environment: [:], developmentProjectRoot: nil, applicationSupportDirectory: support).path, "/tmp/Library/Application Support/TravelCat/TravelPetData")
    }

    func testBundledStableRootWinsOutsideEnvironmentOverride() {
        let resolver = AppDataRootResolver()
        let stable = URL(fileURLWithPath: "/stable-project/TravelPetData")
        let development = URL(fileURLWithPath: "/temporary-worktree")
        let support = URL(fileURLWithPath: "/tmp/Library/Application Support")

        XCTAssertEqual(
            resolver.resolve(
                environment: [:],
                bundledDataRoot: stable,
                developmentProjectRoot: development,
                applicationSupportDirectory: support
            ).path,
            stable.path
        )
        XCTAssertEqual(
            resolver.resolve(
                environment: ["TRAVEL_CAT_DATA": "/explicit"],
                bundledDataRoot: stable,
                developmentProjectRoot: development,
                applicationSupportDirectory: support
            ).path,
            "/explicit"
        )
    }
}
