import CoreGraphics
import CoreText
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import TravelUI

final class BundledPostcardFontTests: XCTestCase {
    func testRegistryRejectsANameCollisionInsteadOfAcceptingAnExternalFace() {
        XCTAssertFalse(PostcardBundledFontRegistry.acceptsRegistrationResult(false))
        XCTAssertTrue(PostcardBundledFontRegistry.acceptsRegistrationResult(true))
    }

    func testFontManifestPinsOfficialVersionSourcesHashesAndLicense() throws {
        let data = try Data(contentsOf: repositoryFontURL("manifest.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            Set([
                "family", "fonts", "license", "licenseFile", "noticeFile",
                "licenseSHA256", "licenseSourceURL", "releaseCommit", "releaseURL", "version",
            ])
        )
        XCTAssertEqual(object["family"] as? String, "LXGW WenKai Lite")
        XCTAssertEqual(object["version"] as? String, "1.522")
        XCTAssertEqual(object["license"] as? String, "OFL-1.1")
        XCTAssertEqual(object["licenseFile"] as? String, "OFL.txt")
        XCTAssertEqual(
            object["licenseSHA256"] as? String,
            "c38b1994a5e48ac30ac7d1da7d0409fd8fd8127dfe28a13d6e787d5b1ef34a5e"
        )
        XCTAssertEqual(
            object["licenseSourceURL"] as? String,
            "https://raw.githubusercontent.com/lxgw/LxgwWenKai-Lite/v1.522/OFL.txt"
        )
        XCTAssertEqual(object["noticeFile"] as? String, "THIRD_PARTY_NOTICES.md")
        XCTAssertEqual(object["releaseCommit"] as? String, "067a6d5")
        XCTAssertEqual(
            object["releaseURL"] as? String,
            "https://github.com/lxgw/LxgwWenKai-Lite/releases/tag/v1.522"
        )

        let manifest = try JSONDecoder().decode(FontManifest.self, from: data)
        XCTAssertEqual(manifest.fonts.map(\.file), Self.fontFiles)
        XCTAssertEqual(
            manifest.fonts.map(\.postScriptName),
            ["LXGWWenKaiLite-Light", "LXGWWenKaiLite-Regular", "LXGWWenKaiLite-Medium"]
        )
        for font in manifest.fonts {
            XCTAssertEqual(
                font.sourceURL,
                "https://github.com/lxgw/LxgwWenKai-Lite/releases/download/v1.522/\(font.file)"
            )
            XCTAssertNotNil(font.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
            let bytes = try Data(contentsOf: repositoryFontURL(font.file))
            XCTAssertEqual(bytes.count, font.size)
            XCTAssertEqual(Self.sha256(bytes), font.sha256)
        }
        XCTAssertEqual(
            Self.sha256(try Data(contentsOf: repositoryFontURL("OFL.txt"))),
            object["licenseSHA256"] as? String
        )
    }

    func testBundledFontsAreRegularSFNTFilesWithExpectedFacesAndChineseCoverage() throws {
        let manifest = try loadManifest()
        for entry in manifest.fonts {
            let url = repositoryFontURL(entry.file)
            var info = stat()
            XCTAssertEqual(lstat(url.path, &info), 0, entry.file)
            XCTAssertEqual(info.st_mode & S_IFMT, S_IFREG, entry.file)
            XCTAssertGreaterThan(info.st_size, 1_000_000, entry.file)
            XCTAssertLessThan(info.st_size, 30_000_000, entry.file)

            let provider = try XCTUnwrap(CGDataProvider(url: url as CFURL), entry.file)
            let graphicsFont = try XCTUnwrap(CGFont(provider), entry.file)
            XCTAssertEqual(graphicsFont.postScriptName as String?, entry.postScriptName)
            let font = CTFontCreateWithGraphicsFont(graphicsFont, 17, nil, nil)
            var characters = Array(Self.coverageText.utf16)
            var glyphs = Array(repeating: CGGlyph(), count: characters.count)
            XCTAssertTrue(
                CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count),
                entry.file
            )
            XCTAssertFalse(glyphs.contains(0), entry.file)
        }
    }

    func testOFLAndThirdPartyNoticeAreCompleteAndPackaged() throws {
        let license = try String(contentsOf: repositoryFontURL("OFL.txt"), encoding: .utf8)
        XCTAssertTrue(license.contains("SIL OPEN FONT LICENSE Version 1.1"))
        XCTAssertTrue(license.contains("Copyright 2021-2026 LXGW"))
        XCTAssertTrue(license.contains("Reserved Font Name"))

        let notice = try String(
            contentsOf: repositoryFontURL("THIRD_PARTY_NOTICES.md"),
            encoding: .utf8
        )
        XCTAssertTrue(notice.contains("LXGW WenKai Lite"))
        XCTAssertTrue(notice.contains("v1.522"))
        XCTAssertTrue(notice.contains("OFL-1.1"))
        XCTAssertTrue(notice.contains("github.com/lxgw/LxgwWenKai-Lite"))

        for name in ["manifest.json", "OFL.txt", "THIRD_PARTY_NOTICES.md"] + Self.fontFiles {
            XCTAssertNotNil(packagedFontURL(name), name)
        }
    }

    func testBundledRegistrationCreatesOfflineFontsAndIsConcurrencySafe() async throws {
        let registrations = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<64 {
                group.addTask { PostcardBundledFontRegistry.registerFonts() }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(registrations.count, 64)
        XCTAssertTrue(registrations.allSatisfy { $0 })

        for entry in try loadManifest().fonts {
            let font = CTFontCreateWithName(entry.postScriptName as CFString, 17, nil)
            XCTAssertEqual(CTFontCopyPostScriptName(font) as String, entry.postScriptName)
            var characters = Array("猫旅风景心情".utf16)
            var glyphs = Array(repeating: CGGlyph(), count: characters.count)
            XCTAssertTrue(CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count))
        }
    }

    private func loadManifest() throws -> FontManifest {
        try JSONDecoder().decode(
            FontManifest.self,
            from: Data(contentsOf: repositoryFontURL("manifest.json"))
        )
    }

    private func repositoryFontURL(_ name: String) -> URL {
        repositoryRoot
            .appendingPathComponent("Sources/TravelUI/Resources/Fonts", isDirectory: true)
            .appendingPathComponent(name)
    }

    private func packagedFontURL(_ name: String) -> URL? {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        return TravelUIResources.bundle.url(
            forResource: parts[0],
            withExtension: parts.count == 2 ? parts[1] : nil,
            subdirectory: "Fonts"
        ) ?? TravelUIResources.bundle.url(
            forResource: parts[0],
            withExtension: parts.count == 2 ? parts[1] : nil
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let fontFiles = [
        "LXGWWenKaiLite-Light.ttf",
        "LXGWWenKaiLite-Regular.ttf",
        "LXGWWenKaiLite-Medium.ttf",
    ]

    private static let coverageText = String(
        (String(repeating: "黑猫旅行明信片湖光晨风山川海岸心情寄语", count: 5)).prefix(80)
    )
}

private struct FontManifest: Decodable {
    struct Font: Decodable {
        let file: String
        let postScriptName: String
        let sourceURL: String
        let sha256: String
        let size: Int
    }

    let fonts: [Font]
}
