#!/usr/bin/swift

import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let sheetWidth = 1_536
private let sheetHeight = 2_288
private let frameWidth = 192
private let frameHeight = 208
private let alphaThreshold: UInt8 = 1

private struct Frame: Codable {
    let column: Int
    let row: Int
}

private struct FrameSize: Codable {
    let width: Int
    let height: Int
}

private struct Coordinates: Codable {
    let front: Frame
    let side: Frame
    let sitting: Frame
}

private struct Identity: Codable {
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

private struct NamedFrame {
    let name: String
    let coordinate: Frame
}

private enum ExtractionError: LocalizedError {
    case invalidPath(String)
    case invalidSource(String)
    case invalidDestination(String)
    case image(String)
    case output(String)

    var errorDescription: String? {
        switch self {
        case let .invalidPath(message), let .invalidSource(message),
             let .invalidDestination(message), let .image(message), let .output(message):
            message
        }
    }
}

private let selectedFrames = [
    NamedFrame(name: "front", coordinate: Frame(column: 0, row: 0)),
    NamedFrame(name: "side", coordinate: Frame(column: 0, row: 2)),
    NamedFrame(name: "sitting", coordinate: Frame(column: 2, row: 8)),
]

private func fileMode(at url: URL) throws -> mode_t? {
    var value = stat()
    let result = url.path.withCString { lstat($0, &value) }
    if result == 0 {
        return value.st_mode & mode_t(S_IFMT)
    }
    if errno == ENOENT {
        return nil
    }
    throw ExtractionError.invalidPath("Cannot inspect \(url.path): \(String(cString: strerror(errno)))")
}

private func requireRegularFile(_ url: URL, label: String) throws {
    guard try fileMode(at: url) == mode_t(S_IFREG) else {
        throw ExtractionError.invalidSource("\(label) must be a regular, non-symlink file: \(url.path)")
    }
}

private func requireDirectoryIfPresent(_ url: URL, label: String) throws {
    guard let mode = try fileMode(at: url) else { return }
    guard mode == mode_t(S_IFDIR) else {
        throw ExtractionError.invalidDestination("\(label) must be a non-symlink directory: \(url.path)")
    }
}

private func explicitRepositoryRoot() throws -> URL? {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard !arguments.isEmpty else { return nil }
    guard arguments.count == 2, arguments[0] == "--project-root" else {
        throw ExtractionError.invalidPath(
            "Usage: swift Scripts/extract-character-references.swift [--project-root <absolute-path>]"
        )
    }
    let path = arguments[1]
    guard path.hasPrefix("/") else {
        throw ExtractionError.invalidPath("--project-root must be an absolute path")
    }
    let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    guard try fileMode(at: root) == mode_t(S_IFDIR) else {
        throw ExtractionError.invalidPath(
            "--project-root must identify a non-symlink directory: \(root.path)"
        )
    }
    let resources = root.appendingPathComponent(
        "Sources/TravelUI/Resources",
        isDirectory: true
    )
    guard try fileMode(at: resources) == mode_t(S_IFDIR) else {
        throw ExtractionError.invalidPath(
            "--project-root is missing Sources/TravelUI/Resources: \(root.path)"
        )
    }
    return root
}

private func repositoryRoot() throws -> URL {
    if let explicitRoot = try explicitRepositoryRoot() {
        return explicitRoot
    }
    let fileManager = FileManager.default
    let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
    let scriptPath = URL(fileURLWithPath: CommandLine.arguments[0], relativeTo: currentDirectory)
        .standardizedFileURL
    var candidates = [scriptPath.deletingLastPathComponent().deletingLastPathComponent()]
    var cursor = currentDirectory
    while cursor.path != cursor.deletingLastPathComponent().path {
        candidates.append(cursor)
        cursor.deleteLastPathComponent()
    }

    for candidate in candidates {
        let source = candidate.appendingPathComponent(
            "Sources/TravelUI/Resources/cute-black-cat-spritesheet.webp"
        )
        if try fileMode(at: source) != nil {
            return candidate.standardizedFileURL
        }
    }
    throw ExtractionError.invalidPath(
        "Could not locate the project root from the current directory or script path"
    )
}

private func loadAuthorizedSprite(at url: URL) throws -> CGImage {
    try requireRegularFile(url, label: "Authorized spritesheet")
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        throw ExtractionError.image("Cannot decode authorized spritesheet")
    }
    guard CGImageSourceGetType(source) as String? == UTType.webP.identifier else {
        throw ExtractionError.image("Authorized spritesheet must be WebP")
    }
    guard CGImageSourceGetCount(source) == 1,
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw ExtractionError.image("Authorized spritesheet must contain exactly one image")
    }
    guard image.width == sheetWidth, image.height == sheetHeight else {
        throw ExtractionError.image(
            "Authorized spritesheet must be exactly \(sheetWidth)x\(sheetHeight) pixels"
        )
    }
    guard image.hasAlphaChannel else {
        throw ExtractionError.image("Authorized spritesheet must contain an alpha channel")
    }
    return image
}

private func crop(_ frame: NamedFrame, from source: CGImage) throws -> CGImage {
    guard (0..<8).contains(frame.coordinate.column), (0..<11).contains(frame.coordinate.row) else {
        throw ExtractionError.image("Frame \(frame.name) is outside the 8x11 grid")
    }
    // The manifest numbers rows from the visual top. Compute the requested
    // Core Graphics bottom-origin cell, then translate it to CGImage's decoded
    // raster crop space, whose y offset advances from the first stored row.
    let bottomOriginY = sheetHeight - (frame.coordinate.row + 1) * frameHeight
    let rasterCropY = sheetHeight - bottomOriginY - frameHeight
    let rect = CGRect(
        x: frame.coordinate.column * frameWidth,
        y: rasterCropY,
        width: frameWidth,
        height: frameHeight
    )
    guard let image = source.cropping(to: rect),
          image.width == frameWidth, image.height == frameHeight else {
        throw ExtractionError.image("Cannot crop frame \(frame.name)")
    }
    return image
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw ExtractionError.output("Cannot create PNG destination for \(url.lastPathComponent)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw ExtractionError.output("Cannot finalize \(url.lastPathComponent)")
    }
}

private struct PixelInspection {
    let bounds: CGRect?
    let coverage: Double
    let corners: [UInt8]
}

private func inspectPixels(_ image: CGImage) throws -> PixelInspection {
    let bytesPerRow = image.width * 4
    var bytes = [UInt8](repeating: 0, count: bytesPerRow * image.height)
    let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    guard rendered else {
        throw ExtractionError.output("Cannot inspect output pixels")
    }

    func alpha(x: Int, y: Int) -> UInt8 {
        bytes[(y * image.width + x) * 4 + 3]
    }
    let corners = [
        alpha(x: 0, y: 0),
        alpha(x: image.width - 1, y: 0),
        alpha(x: 0, y: image.height - 1),
        alpha(x: image.width - 1, y: image.height - 1),
    ]
    var minX = image.width
    var minY = image.height
    var maxX = -1
    var maxY = -1
    var count = 0
    for y in 0..<image.height {
        for x in 0..<image.width where alpha(x: x, y: y) > 8 {
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
            count += 1
        }
    }
    let coverage = Double(count) / Double(image.width * image.height)
    let bounds = count == 0 ? nil : CGRect(
        x: minX,
        y: minY,
        width: maxX - minX,
        height: maxY - minY
    )
    return PixelInspection(bounds: bounds, coverage: coverage, corners: corners)
}

private func validatePNG(at url: URL, named name: String) throws {
    try requireRegularFile(url, label: "Generated \(name) PNG")
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          CGImageSourceGetType(source) as String? == UTType.png.identifier,
          CGImageSourceGetCount(source) == 1,
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw ExtractionError.output("\(name).png is not a single valid PNG")
    }
    guard image.width == frameWidth, image.height == frameHeight, image.hasAlphaChannel else {
        throw ExtractionError.output("\(name).png has invalid geometry or no alpha channel")
    }
    let inspection = try inspectPixels(image)
    guard inspection.corners.allSatisfy({ $0 <= alphaThreshold }) else {
        throw ExtractionError.output("\(name).png has nontransparent corners: \(inspection.corners)")
    }
    guard let bounds = inspection.bounds,
          inspection.coverage > 0.10, inspection.coverage < 0.75 else {
        throw ExtractionError.output("\(name).png has implausible subject alpha coverage")
    }
    guard bounds.minX > 0, bounds.minY > 0,
          bounds.maxX < CGFloat(image.width - 1),
          bounds.maxY < CGFloat(image.height - 1) else {
        throw ExtractionError.output("\(name).png subject is clipped at a frame edge")
    }
}

@discardableResult
private func writeManifest(sourceData: Data, to url: URL) throws -> Data {
    let identity = Identity(
        collarColor: "violet",
        coordinates: Coordinates(
            front: Frame(column: 0, row: 0),
            side: Frame(column: 0, row: 2),
            sitting: Frame(column: 2, row: 8)
        ),
        displayName: "Cute Black Cat",
        eyeColor: "gold",
        frameSize: FrameSize(width: frameWidth, height: frameHeight),
        furColor: "near-black with subtle violet highlights",
        identityMarker: "small gold bell",
        mustPreserve: [
            "round face", "large gold eyes", "violet collar", "gold bell", "short black fur",
        ],
        sourceSpriteSHA256: SHA256.hash(data: sourceData)
            .map { String(format: "%02x", $0) }
            .joined(),
        species: "small round-faced black cat",
        spriteVersionNumber: 2
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(identity)
    data.append(0x0A)
    try data.write(to: url, options: .withoutOverwriting)
    return data
}

private func validateExistingDestination(_ destination: URL) throws {
    guard try fileMode(at: destination) != nil else { return }
    try requireDirectoryIfPresent(destination, label: "Character reference destination")
    let expected = Set(selectedFrames.map { "\($0.name).png" } + ["identity.json"])
    let existing = try Set(FileManager.default.contentsOfDirectory(atPath: destination.path))
    guard existing.isSubset(of: expected) else {
        throw ExtractionError.invalidDestination(
            "Character reference destination contains unexpected entries"
        )
    }
    for name in existing {
        let item = destination.appendingPathComponent(name)
        guard try fileMode(at: item) == mode_t(S_IFREG) else {
            throw ExtractionError.invalidDestination(
                "Destination item must be a regular, non-symlink file: \(item.path)"
            )
        }
    }
}

private func publish(stagedPack: URL, to destination: URL) throws {
    let fileManager = FileManager.default
    if try fileMode(at: destination) == nil {
        try fileManager.moveItem(at: stagedPack, to: destination)
        return
    }
    _ = try fileManager.replaceItemAt(destination, withItemAt: stagedPack)
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

do {
    let fileManager = FileManager.default
    let root = try repositoryRoot()
    let sourceURL = root.appendingPathComponent(
        "Sources/TravelUI/Resources/cute-black-cat-spritesheet.webp"
    )
    let assetsURL = root.appendingPathComponent("Assets", isDirectory: true)
    let destinationURL = assetsURL.appendingPathComponent("CharacterReference", isDirectory: true)

    try requireDirectoryIfPresent(assetsURL, label: "Assets directory")
    if try fileMode(at: assetsURL) == nil {
        try fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: false)
    }
    try validateExistingDestination(destinationURL)

    let stagingRoot = assetsURL.appendingPathComponent(
        ".character-reference-stage-\(UUID().uuidString)",
        isDirectory: true
    )
    let stagedPack = stagingRoot.appendingPathComponent("CharacterReference", isDirectory: true)
    try fileManager.createDirectory(at: stagedPack, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: stagingRoot) }

    let sprite = try loadAuthorizedSprite(at: sourceURL)
    let sourceData = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
    for frame in selectedFrames {
        let outputURL = stagedPack.appendingPathComponent("\(frame.name).png")
        try writePNG(try crop(frame, from: sprite), to: outputURL)
        try validatePNG(at: outputURL, named: frame.name)
    }
    let manifestURL = stagedPack.appendingPathComponent("identity.json")
    let expectedManifest = try writeManifest(sourceData: sourceData, to: manifestURL)
    try requireRegularFile(manifestURL, label: "Generated identity manifest")
    guard try Data(contentsOf: manifestURL) == expectedManifest else {
        throw ExtractionError.output("Generated identity manifest failed validation")
    }

    try publish(stagedPack: stagedPack, to: destinationURL)
    print("Generated black-cat identity references in \(destinationURL.path)")
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
