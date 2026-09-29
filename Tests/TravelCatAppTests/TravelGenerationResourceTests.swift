import Foundation
import XCTest
@testable import TravelCatApp

@MainActor
final class TravelGenerationResourceTests: XCTestCase {
    func testPackagedResourcesResolveWithoutDevelopmentFallback() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("ResourceProbe-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: app) }
        let contents = app.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources/TravelCat_TravelCatApp.bundle/Generation")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.nebulae.travelcat.resource-test", "CFBundleName": "Probe", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: app))
        XCTAssertEqual(CodexTravelContentGenerator.generationResourceRoot(in: bundle)?.path, resources.path)
        try FileManager.default.removeItem(at: resources)
        XCTAssertNil(CodexTravelContentGenerator.generationResourceRoot(in: bundle), "A broken installed app must not silently read build-machine resources")
    }
    func testAllRequiredGenerationAssetsAreAvailable() throws {
        let root = try XCTUnwrap(CodexTravelContentGenerator.generationResourceRoot())
        for name in ["narrative.schema.json", "image.schema.json", "front.png", "side.png", "sitting.png", "identity.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path), name)
        }
    }
}
