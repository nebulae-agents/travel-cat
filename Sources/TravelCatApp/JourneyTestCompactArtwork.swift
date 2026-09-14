import CoreGraphics
import Darwin
import Foundation
import ImageIO
import TravelStorage
import TravelUI

enum JourneyTestCompactArtworkError: Error, LocalizedError, Equatable {
  case invalidAsset
  case invalidPlacement
  case writeFailed

  var errorDescription: String? {
    switch self {
    case .invalidAsset: "紧凑测试的内置明信片素材无法读取。"
    case .invalidPlacement: "紧凑测试的黑猫位置配置无效。"
    case .writeFailed: "紧凑测试的明信片合成文件无法保存。"
    }
  }
}

enum JourneyTestCompactArtwork {
  private static let maximumDimension = 1_536
  private static let maximumInputBytes = 15 * 1_024 * 1_024

  static func compose(
    backgroundURL: URL, catURL: URL, placement: PreviewBlackCatPlacement,
    session: JourneyTestSession
  ) throws -> URL {
    guard placement.isValid,
      let background = try decodeRegularImage(backgroundURL),
      let cat = try decodeRegularImage(catURL)
    else { throw JourneyTestCompactArtworkError.invalidAsset }
    let sourceWidth = background.width
    let sourceHeight = background.height
    guard sourceWidth > 0, sourceHeight > 0 else {
      throw JourneyTestCompactArtworkError.invalidAsset
    }
    let scale = min(1, Double(maximumDimension) / Double(max(sourceWidth, sourceHeight)))
    let width = max(1, Int((Double(sourceWidth) * scale).rounded()))
    let height = max(1, Int((Double(sourceHeight) * scale).rounded()))
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw JourneyTestCompactArtworkError.invalidAsset }
    context.interpolationQuality = .high
    context.draw(background, in: CGRect(x: 0, y: 0, width: width, height: height))
    let topFrame = placement.frame(
      in: CGSize(width: width, height: height),
      sourceAspectRatio: CGFloat(cat.width) / CGFloat(cat.height))
    guard !topFrame.isEmpty else { throw JourneyTestCompactArtworkError.invalidPlacement }
    let frame = CGRect(
      x: topFrame.minX, y: CGFloat(height) - topFrame.maxY,
      width: topFrame.width, height: topFrame.height)
    context.saveGState()
    if placement.isMirrored {
      context.translateBy(x: frame.midX * 2, y: 0)
      context.scaleBy(x: -1, y: 1)
    }
    context.interpolationQuality = .none
    context.draw(cat, in: frame)
    context.restoreGState()
    guard let result = context.makeImage() else {
      throw JourneyTestCompactArtworkError.invalidAsset
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      data, "public.png" as CFString, 1, nil)
    else { throw JourneyTestCompactArtworkError.invalidAsset }
    CGImageDestinationAddImage(destination, result, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw JourneyTestCompactArtworkError.invalidAsset
    }
    return try write(Data(referencing: data), session: session)
  }

  private static func decodeRegularImage(_ url: URL) throws -> CGImage? {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw JourneyTestCompactArtworkError.invalidAsset }
    defer { _ = close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
      info.st_nlink == 1, info.st_size > 0, info.st_size <= maximumInputBytes
    else { throw JourneyTestCompactArtworkError.invalidAsset }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    let data = try handle.readToEnd() ?? Data()
    guard !data.isEmpty, data.count <= maximumInputBytes,
      let source = CGImageSourceCreateWithData(data as CFData, nil)
    else { throw JourneyTestCompactArtworkError.invalidAsset }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  private static func write(_ data: Data, session: JourneyTestSession) throws -> URL {
    try session.validate()
    let root = open(session.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard root >= 0 else { throw JourneyTestCompactArtworkError.writeFailed }
    defer { _ = close(root) }
    let directoryName = "compact-artwork"
    if mkdirat(root, directoryName, 0o700) != 0, errno != EEXIST {
      throw JourneyTestCompactArtworkError.writeFailed
    }
    let directory = openat(root, directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw JourneyTestCompactArtworkError.writeFailed }
    defer { _ = close(directory) }
    let filename = "\(UUID().uuidString.lowercased()).png"
    let descriptor = openat(
      directory, filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw JourneyTestCompactArtworkError.writeFailed }
    defer { _ = close(descriptor) }
    try data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { throw JourneyTestCompactArtworkError.writeFailed }
      var offset = 0
      while offset < raw.count {
        let count = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
        guard count > 0 else { throw JourneyTestCompactArtworkError.writeFailed }
        offset += count
      }
    }
    try session.validate()
    return session.root.appendingPathComponent("\(directoryName)/\(filename)")
  }
}
