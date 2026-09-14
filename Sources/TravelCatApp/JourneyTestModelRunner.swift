import Darwin
import Foundation
import ImageIO
import TravelStorage

protocol JourneyTestModelGenerating: Sendable {
  func generateJSON(prompt: String, schema: Data, session: JourneyTestSession, referenceImage: URL?)
    async throws -> Data
}
enum JourneyTestModelRunnerError: Error, Equatable, Sendable {
  case invalidSchema, invalidReference, invalidResult, resultTooLarge, resultSymlink
}

final class JourneyTestModelRunner: JourneyTestModelGenerating, @unchecked Sendable {
  private static let maxReferenceBytes = 10_485_760

  private let transport: JourneyTestProcessTransport
  private let environment: [String: String]
  private let maxOutputBytes: Int

  init(
    executableURL: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
    timeout: TimeInterval = 600, maxOutputBytes: Int = 1_048_576
  ) throws {
    transport = try JourneyTestProcessTransport(
      executableURL: executableURL, timeout: timeout, maxOutputBytes: maxOutputBytes)
    self.environment = Self.safeEnvironment(environment)
    self.maxOutputBytes = maxOutputBytes
  }

  func generateJSON(prompt: String, schema: Data, session: JourneyTestSession, referenceImage: URL?)
    async throws -> Data
  {
    try Task.checkCancellation()
    guard let schemaObject = try? JSONSerialization.jsonObject(with: schema),
      schemaObject is [String: Any]
    else {
      throw JourneyTestModelRunnerError.invalidSchema
    }
    try session.validate()
    try Task.checkCancellation()
    let request = try requestDirectory(in: session.root)
    let schemaURL = request.appendingPathComponent("schema.json")
    let inputURL = request.appendingPathComponent("input.txt")
    let resultURL = request.appendingPathComponent("result.json")
    try write(schema, to: schemaURL)
    try write(Data(prompt.utf8), to: inputURL)
    var arguments = codexArguments(schemaURL: schemaURL, resultURL: resultURL, session: session)
    if let referenceImage {
      arguments += ["-i", try copyReference(referenceImage, to: request).path]
    }
    arguments.append("-")
    let cancellation = JourneyTestCancellation()
    let invocationArguments = arguments
    let invocationEnvironment = environment
    try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation { continuation in
          DispatchQueue.global(qos: .userInitiated).async { [transport] in
            do {
              try transport.run(
                arguments: invocationArguments, environment: invocationEnvironment,
                inputURL: inputURL, cancellation: cancellation)
              continuation.resume()
            } catch { continuation.resume(throwing: error) }
          }
        }
      }, onCancel: { cancellation.cancel() })
    try Task.checkCancellation()
    try session.validate()
    return try readResult(resultURL)
  }

  private func codexArguments(schemaURL: URL, resultURL: URL, session: JourneyTestSession)
    -> [String]
  {
    [
      "exec", "--ignore-user-config", "--ephemeral", "--skip-git-repo-check", "--sandbox",
      "read-only", "--disable", "apps", "--disable", "plugins", "--disable", "hooks", "--disable",
      "browser_use", "--disable", "computer_use", "-m", "gpt-5.6-luna", "--output-schema",
      schemaURL.path, "--output-last-message", resultURL.path, "--json", "-C", session.root.path,
    ]
  }
  private static func safeEnvironment(_ source: [String: String]) -> [String: String] {
    source.reduce(into: [:]) { result, item in
      let key = item.key
      if key == "HOME" || key == "PATH" || key == "TMPDIR" || key == "LANG" || key == "USER"
        || key.hasPrefix("LC_")
      {
        result[key] = item.value
      }
    }
  }
  private func requestDirectory(in root: URL) throws -> URL {
    let url = root.appendingPathComponent(
      "model-request-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return url
  }
  private func write(_ data: Data, to url: URL) throws {
    guard
      FileManager.default.createFile(
        atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
    else { throw CocoaError(.fileWriteUnknown) }
  }
  private func copyReference(_ source: URL, to request: URL) throws -> URL {
    let suffix = source.pathExtension.lowercased()
    guard suffix == "png" || suffix == "webp" else {
      throw JourneyTestModelRunnerError.invalidReference
    }
    let data = try readRegular(
      source,
      limit: Self.maxReferenceBytes,
      invalidFileError: .invalidReference,
      symlinkError: .invalidReference,
      tooLargeError: .invalidReference)
    guard let image = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceCreateImageAtIndex(image, 0, nil) != nil
    else { throw JourneyTestModelRunnerError.invalidReference }
    let target = request.appendingPathComponent("reference.\(suffix)")
    try write(data, to: target)
    return target
  }
  private func readResult(_ url: URL) throws -> Data {
    let data = try readRegular(
      url,
      limit: maxOutputBytes,
      invalidFileError: .invalidResult,
      symlinkError: .resultSymlink,
      tooLargeError: .resultTooLarge)
    guard !data.isEmpty,
      let resultObject = try? JSONSerialization.jsonObject(with: data),
      resultObject is [String: Any]
    else { throw JourneyTestModelRunnerError.invalidResult }
    return data
  }
  private func readRegular(
    _ url: URL,
    limit: Int,
    invalidFileError: JourneyTestModelRunnerError,
    symlinkError: JourneyTestModelRunnerError,
    tooLargeError: JourneyTestModelRunnerError
  ) throws
    -> Data
  {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
    if descriptor < 0 {
      throw errno == ELOOP ? symlinkError : invalidFileError
    }
    defer { close(descriptor) }
    var information = stat()
    guard fstat(descriptor, &information) == 0, (information.st_mode & S_IFMT) == S_IFREG else {
      throw invalidFileError
    }
    guard information.st_size >= 0, information.st_size <= off_t(limit) else {
      throw tooLargeError
    }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: min(65_536, limit + 1))
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count < 0 { throw JourneyTestModelRunnerError.invalidResult }
      if count == 0 { return result }
      result.append(buffer, count: count)
      if result.count > limit {
        throw tooLargeError
      }
    }
  }
}
