import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import TravelUI

final class TravelAlbumPreviewAssetTests: XCTestCase {
    func testRepositoryContainsSixDetailedLandscapePreviewBackgrounds() throws {
        let root = repositoryRoot
            .appendingPathComponent("Sources/TravelUI/Resources/PreviewPostcards", isDirectory: true)
        let names = TravelAlbumPreviewCatalog.definitions.map(\.filename)

        let fileManager = FileManager.default
        let actual = try fileManager
            .contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".png") }
            .sorted()
        let expected = names.sorted()

        XCTAssertEqual(actual, expected)
        for name in names {
            let url = root.appendingPathComponent(name)
            let data = try Data(contentsOf: url)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil), name)
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), name)
            let ratio = Double(image.width) / Double(image.height)

            XCTAssertEqual(ratio, 1.5, accuracy: 0.03, name)
            XCTAssertGreaterThanOrEqual(image.width, 1_200, name)
            XCTAssertGreaterThanOrEqual(image.height, 800, name)
            XCTAssertGreaterThanOrEqual(data.count, 200_000, name)
            XCTAssertGreaterThanOrEqual(try sampledUniqueColorCount(image), 256, name)
        }
    }

    func testPackagedPreviewCatsAreByteIdenticalToAuthorizedReferences() throws {
        let sourceRoot = repositoryRoot
            .appendingPathComponent("Assets/CharacterReference", isDirectory: true)
        let packagedRoot = repositoryRoot
            .appendingPathComponent("Sources/TravelUI/Resources/PreviewBlackCat", isDirectory: true)
        let pairs = [
            ("front.png", "preview-cat-front.png"),
            ("side.png", "preview-cat-side.png"),
            ("sitting.png", "preview-cat-sitting.png"),
        ]

        for (sourceName, packagedName) in pairs {
            XCTAssertEqual(
                try Data(contentsOf: sourceRoot.appendingPathComponent(sourceName)),
                try Data(contentsOf: packagedRoot.appendingPathComponent(packagedName)),
                packagedName
            )
        }
    }

    func testCatalogResolvesAllPreviewCatAssetsFromBundle() throws {
        XCTAssertEqual(PreviewBlackCatPose.allCases.count, 3)
        for pose in PreviewBlackCatPose.allCases {
            let url = try XCTUnwrap(
                TravelAlbumPreviewCatalog.catResourceURL(
                    for: pose,
                    in: TravelUIResources.bundle
                )
            )
            XCTAssertEqual(url.lastPathComponent, pose.assetFilename)
        }
    }

    private func sampledUniqueColorCount(_ image: CGImage) throws -> Int {
        let width = 64
        let height = 43
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var colors: Set<UInt32> = []
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = UInt32(pixels[index]) << 16
            let green = UInt32(pixels[index + 1]) << 8
            let blue = UInt32(pixels[index + 2])
            colors.insert(red | green | blue)
        }
        return colors.count
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
