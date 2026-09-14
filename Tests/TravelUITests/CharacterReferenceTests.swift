import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class CharacterReferenceTests: XCTestCase {
    func testExtractorPublishesDeterministicallyAndPreservesPackOnUnsafeInputs() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("travel-cat-reference-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = temporaryRoot.appendingPathComponent("FixtureProject", isDirectory: true)
        let resourceDirectory = projectRoot.appendingPathComponent(
            "Sources/TravelUI/Resources",
            isDirectory: true
        )
        let runnerDirectory = temporaryRoot.appendingPathComponent("Runner", isDirectory: true)
        let copiedScript = runnerDirectory.appendingPathComponent(
            "extract-character-references.swift"
        )
        let copiedSource = resourceDirectory.appendingPathComponent(
            "cute-black-cat-spritesheet.webp"
        )
        let validSourceBackup = temporaryRoot.appendingPathComponent("authorized-sprite.webp")
        let outputDirectory = projectRoot.appendingPathComponent(
            "Assets/CharacterReference",
            isDirectory: true
        )
        try fileManager.createDirectory(at: resourceDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runnerDirectory, withIntermediateDirectories: true)
        try fileManager.copyItem(
            at: repositoryRoot.appendingPathComponent("Scripts/extract-character-references.swift"),
            to: copiedScript
        )
        try fileManager.copyItem(at: sourceSpriteURL(), to: copiedSource)
        try fileManager.copyItem(at: sourceSpriteURL(), to: validSourceBackup)
        defer {
            XCTAssertNoThrow(try fileManager.removeItem(at: temporaryRoot))
        }

        let firstRun = try runExtractor(script: copiedScript, projectRoot: projectRoot)
        XCTAssertEqual(firstRun.status, 0, firstRun.diagnostics)
        let firstPack = try artifactBytes(in: outputDirectory)
        XCTAssertEqual(firstPack, try artifactBytes(in: assetURL(".").standardizedFileURL))
        try assertReferencePNGs(in: outputDirectory)
        let generatedIdentity = try JSONDecoder().decode(
            CharacterIdentity.self,
            from: try XCTUnwrap(firstPack["identity.json"])
        )
        let expectedSourceHash = SHA256.hash(data: try Data(contentsOf: copiedSource))
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(generatedIdentity.sourceSpriteSHA256, expectedSourceHash)
        try assertNoStagingResidue(in: projectRoot.appendingPathComponent("Assets"))

        let secondRun = try runExtractor(script: copiedScript, projectRoot: projectRoot)
        XCTAssertEqual(secondRun.status, 0, secondRun.diagnostics)
        XCTAssertEqual(try artifactBytes(in: outputDirectory), firstPack)
        try assertNoStagingResidue(in: projectRoot.appendingPathComponent("Assets"))

        try fileManager.removeItem(at: copiedSource)
        try Data("not a valid image".utf8).write(to: copiedSource, options: .withoutOverwriting)
        let corruptRun = try runExtractor(script: copiedScript, projectRoot: projectRoot)
        XCTAssertNotEqual(corruptRun.status, 0, corruptRun.diagnostics)
        XCTAssertEqual(try artifactBytes(in: outputDirectory), firstPack)
        try assertNoStagingResidue(in: projectRoot.appendingPathComponent("Assets"))

        try fileManager.removeItem(at: copiedSource)
        try fileManager.createSymbolicLink(at: copiedSource, withDestinationURL: validSourceBackup)
        let sourceSymlinkRun = try runExtractor(script: copiedScript, projectRoot: projectRoot)
        XCTAssertNotEqual(sourceSymlinkRun.status, 0, sourceSymlinkRun.diagnostics)
        XCTAssertEqual(try artifactBytes(in: outputDirectory), firstPack)
        try assertNoStagingResidue(in: projectRoot.appendingPathComponent("Assets"))

        try fileManager.removeItem(at: copiedSource)
        try fileManager.copyItem(at: validSourceBackup, to: copiedSource)
        let externalTarget = temporaryRoot.appendingPathComponent("external-target.bin")
        let externalBytes = Data("must remain untouched".utf8)
        try externalBytes.write(to: externalTarget, options: .withoutOverwriting)
        let obstructedFront = outputDirectory.appendingPathComponent("front.png")
        try fileManager.removeItem(at: obstructedFront)
        try fileManager.createSymbolicLink(at: obstructedFront, withDestinationURL: externalTarget)
        let companionNames = ["identity.json", "side.png", "sitting.png"]
        let companionsBefore = try artifactBytes(in: outputDirectory, names: companionNames)

        let destinationSymlinkRun = try runExtractor(script: copiedScript, projectRoot: projectRoot)
        XCTAssertNotEqual(destinationSymlinkRun.status, 0, destinationSymlinkRun.diagnostics)
        XCTAssertEqual(try Data(contentsOf: externalTarget), externalBytes)
        XCTAssertEqual(
            try artifactBytes(in: outputDirectory, names: companionNames),
            companionsBefore
        )
        XCTAssertEqual(
            try fileManager.destinationOfSymbolicLink(atPath: obstructedFront.path),
            externalTarget.path
        )
        try assertNoStagingResidue(in: projectRoot.appendingPathComponent("Assets"))

        let invalidRootRun = try runExtractor(
            script: copiedScript,
            rawArguments: ["--project-root", "relative/path"]
        )
        XCTAssertNotEqual(invalidRootRun.status, 0, invalidRootRun.diagnostics)
        XCTAssertEqual(try Data(contentsOf: externalTarget), externalBytes)
        XCTAssertEqual(
            try artifactBytes(in: outputDirectory, names: companionNames),
            companionsBefore
        )
    }

    func testManifestExactlyDescribesAuthorizedIdentityAndFrames() throws {
        let data = try Data(contentsOf: assetURL("identity.json"))
        let manifest = try JSONDecoder().decode(CharacterIdentity.self, from: data)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(
            Set(object.keys),
            Set([
                "collarColor", "coordinates", "displayName", "eyeColor", "frameSize",
                "furColor", "identityMarker", "mustPreserve", "sourceSpriteSHA256",
                "species", "spriteVersionNumber",
            ])
        )
        XCTAssertEqual(manifest.displayName, "Cute Black Cat")
        XCTAssertEqual(manifest.species, "small round-faced black cat")
        XCTAssertEqual(manifest.furColor, "near-black with subtle violet highlights")
        XCTAssertEqual(manifest.eyeColor, "gold")
        XCTAssertEqual(manifest.collarColor, "violet")
        XCTAssertEqual(manifest.identityMarker, "small gold bell")
        XCTAssertEqual(
            manifest.mustPreserve,
            ["round face", "large gold eyes", "violet collar", "gold bell", "short black fur"]
        )
        XCTAssertEqual(manifest.spriteVersionNumber, 2)
        XCTAssertEqual(manifest.frameSize, FrameSize(width: 192, height: 208))
        XCTAssertEqual(manifest.coordinates.front, FrameCoordinate(column: 0, row: 0))
        XCTAssertEqual(manifest.coordinates.side, FrameCoordinate(column: 0, row: 2))
        XCTAssertEqual(manifest.coordinates.sitting, FrameCoordinate(column: 2, row: 8))

        let frameSizeObject = try XCTUnwrap(object["frameSize"] as? [String: Any])
        XCTAssertEqual(Set(frameSizeObject.keys), Set(["height", "width"]))
        XCTAssertTrue(frameSizeObject["height"] is NSNumber)
        XCTAssertTrue(frameSizeObject["width"] is NSNumber)
        let coordinatesObject = try XCTUnwrap(object["coordinates"] as? [String: Any])
        XCTAssertEqual(Set(coordinatesObject.keys), Set(["front", "side", "sitting"]))
        for name in ["front", "side", "sitting"] {
            let coordinate = try XCTUnwrap(coordinatesObject[name] as? [String: Any])
            XCTAssertEqual(Set(coordinate.keys), Set(["column", "row"]), name)
            XCTAssertTrue(coordinate["column"] is NSNumber, name)
            XCTAssertTrue(coordinate["row"] is NSNumber, name)
        }

        let expectedHash = SHA256.hash(data: try Data(contentsOf: sourceSpriteURL()))
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(manifest.sourceSpriteSHA256, expectedHash)
    }

    func testReferencePNGsHaveExactGeometryAlphaAndUnclippedSubjects() throws {
        try assertReferencePNGs(in: assetURL(".").standardizedFileURL)
    }

    private func assertReferencePNGs(in directory: URL) throws {
        for name in ["front", "side", "sitting"] {
            let url = directory.appendingPathComponent("\(name).png")
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), name)
            XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier, name)
            XCTAssertEqual(CGImageSourceGetCount(source), 1, name)

            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), name)
            XCTAssertEqual(image.width, 192, name)
            XCTAssertEqual(image.height, 208, name)
            XCTAssertTrue(image.hasAlphaChannel, name)

            let pixels = try rgbaPixels(for: image)
            let alphaThreshold: UInt8 = 1
            let corners = [
                pixels.alpha(x: 0, y: 0),
                pixels.alpha(x: image.width - 1, y: 0),
                pixels.alpha(x: 0, y: image.height - 1),
                pixels.alpha(x: image.width - 1, y: image.height - 1),
            ]
            XCTAssertTrue(corners.allSatisfy { $0 <= alphaThreshold }, "\(name): \(corners)")

            let subject = pixels.subjectBounds(alphaGreaterThan: 8)
            let bounds = try XCTUnwrap(subject.bounds, name)
            XCTAssertGreaterThan(subject.coverage, 0.10, name)
            XCTAssertLessThan(subject.coverage, 0.75, name)
            XCTAssertGreaterThan(bounds.minX, 0, name)
            XCTAssertGreaterThan(bounds.minY, 0, name)
            XCTAssertLessThan(bounds.maxX, CGFloat(image.width - 1), name)
            XCTAssertLessThan(bounds.maxY, CGFloat(image.height - 1), name)

            XCTAssertGreaterThan(pixels.goldPixelCount(inTopFraction: 0.72), 20, name)
            XCTAssertGreaterThan(pixels.violetPixelCount(), 20, name)
        }
    }

    func testCoordinatesUseVisualTopAsRowZeroWithoutAdjacentFrameBleed() throws {
        let sourceURL = sourceSpriteURL()
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(sourceURL as CFURL, nil))
        let sheet = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let coordinates = [
            (name: "front", column: 0, row: 0),
            (name: "side", column: 0, row: 2),
            (name: "sitting", column: 2, row: 8),
        ]

        for coordinate in coordinates {
            let expectedRect = CGRect(
                x: coordinate.column * 192,
                y: coordinate.row * 208,
                width: 192,
                height: 208
            )
            let expected = try XCTUnwrap(sheet.cropping(to: expectedRect), coordinate.name)
            let outputSource = try XCTUnwrap(
                CGImageSourceCreateWithURL(assetURL("\(coordinate.name).png") as CFURL, nil)
            )
            let output = try XCTUnwrap(CGImageSourceCreateImageAtIndex(outputSource, 0, nil))

            let outputHash = SHA256.hash(data: Data(try rgbaPixels(for: output).bytes))
            let expectedHash = SHA256.hash(data: Data(try rgbaPixels(for: expected).bytes))
            XCTAssertEqual(outputHash, expectedHash, coordinate.name)
        }
    }

    private func assetURL(_ name: String) -> URL {
        repositoryRoot
            .appendingPathComponent("Assets/CharacterReference", isDirectory: true)
            .appendingPathComponent(name)
    }

    private func sourceSpriteURL() -> URL {
        repositoryRoot.appendingPathComponent(
            "Sources/TravelUI/Resources/cute-black-cat-spritesheet.webp"
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func runExtractor(script: URL, projectRoot: URL) throws -> ProcessResult {
        try runExtractor(
            script: script,
            rawArguments: ["--project-root", projectRoot.standardizedFileURL.path]
        )
    }

    private func runExtractor(script: URL, rawArguments: [String]) throws -> ProcessResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = [script.path] + rawArguments
        process.currentDirectoryURL = script.deletingLastPathComponent()
        process.standardOutput = standardOutput
        process.standardError = standardError
        var environment = ProcessInfo.processInfo.environment
        let cacheRoot = script.deletingLastPathComponent().appendingPathComponent("ModuleCache")
        environment["CLANG_MODULE_CACHE_PATH"] = cacheRoot.path
        environment["SWIFTPM_MODULECACHE_OVERRIDE"] = cacheRoot.path
        process.environment = environment
        try process.run()

        let deadline = Date().addingTimeInterval(20)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            XCTFail("Extractor exceeded 20-second timeout")
        } else {
            process.waitUntilExit()
        }
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(
                decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ),
            stderr: String(
                decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }

    private func artifactBytes(
        in directory: URL,
        names: [String] = ["front.png", "identity.json", "side.png", "sitting.png"]
    ) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: names.map { name in
            (name, try Data(contentsOf: directory.appendingPathComponent(name)))
        })
    }

    private func assertNoStagingResidue(in assetsDirectory: URL) throws {
        let entries = try FileManager.default.contentsOfDirectory(atPath: assetsDirectory.path)
        XCTAssertTrue(
            entries.filter { $0.hasPrefix(".character-reference-stage-") }.isEmpty,
            "Unexpected staging residue: \(entries)"
        )
    }

    private func rgbaPixels(for image: CGImage) throws -> RGBAPixels {
        let bytesPerRow = image.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let rendered: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(rendered)
        return RGBAPixels(width: image.width, height: image.height, bytes: bytes)
    }
}

private struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String

    var diagnostics: String {
        "stdout:\n\(stdout)\nstderr:\n\(stderr)"
    }
}

private struct CharacterIdentity: Decodable {
    let collarColor: String
    let coordinates: Coordinates
    let displayName: String
    let eyeColor: String
    let frameSize: FrameSize
    let furColor: String
    let identityMarker: String
    let mustPreserve: [String]
    let sourceSpriteSHA256: String
    let species: String
    let spriteVersionNumber: Int
}

private struct Coordinates: Decodable {
    let front: FrameCoordinate
    let side: FrameCoordinate
    let sitting: FrameCoordinate
}

private struct FrameCoordinate: Codable, Equatable {
    let column: Int
    let row: Int
}

private struct FrameSize: Codable, Equatable {
    let width: Int
    let height: Int
}

private struct RGBAPixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    func alpha(x: Int, y: Int) -> UInt8 {
        bytes[(y * width + x) * 4 + 3]
    }

    func subjectBounds(alphaGreaterThan threshold: UInt8) -> (bounds: CGRect?, coverage: Double) {
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        var count = 0
        for y in 0..<height {
            for x in 0..<width where alpha(x: x, y: y) > threshold {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
                count += 1
            }
        }
        let coverage = Double(count) / Double(width * height)
        guard count > 0 else { return (nil, coverage) }
        return (
            CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
            coverage
        )
    }

    func goldPixelCount(inTopFraction fraction: Double) -> Int {
        let maxY = Int(Double(height) * fraction)
        return countPixels(maxY: maxY) { red, green, blue, alpha in
            alpha > 100 && red > 170 && green > 95 && blue < 90
        }
    }

    func violetPixelCount() -> Int {
        countPixels(maxY: height) { red, green, blue, alpha in
            alpha > 100 && red > 70 && blue > red && blue > green
        }
    }

    private func countPixels(
        maxY: Int,
        matching predicate: (UInt8, UInt8, UInt8, UInt8) -> Bool
    ) -> Int {
        var count = 0
        for y in 0..<maxY {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if predicate(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]) {
                    count += 1
                }
            }
        }
        return count
    }
}

private extension CGImage {
    var hasAlphaChannel: Bool {
        switch alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
            true
        case .none, .noneSkipFirst, .noneSkipLast:
            false
        @unknown default:
            false
        }
    }
}
