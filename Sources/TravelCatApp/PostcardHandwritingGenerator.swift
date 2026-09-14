import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import TravelCore
import TravelStorage
import TravelUI

protocol PostcardHandwritingPreparing: Sendable {
  func prepare(event: TripEvent, sourceRelativePath: String, session: JourneyTestSession,
               leaseExpiresAt: Date, acceptedReference: PostcardPresentationReference?) async throws -> PostcardPresentationReference
}

/// Prepares immutable presentations. Only the controller may publish the returned reference.
struct PostcardHandwritingGenerator: PostcardHandwritingPreparing {
  typealias Hint = PostcardHandwritingPolicy.Hint
  typealias Select = @Sendable (TripEvent, Data) throws -> Hint
  typealias Verify = @Sendable (TripEvent, Data, Data) throws -> PostcardPresentationRect
  private enum Failure: String, Error { case deadline, generationFailed, invalidGeneratedImage }
  static let styleVersion = PostcardHandwritingPolicy.styleVersion
  private let model: (any JourneyTestModelGenerating)?
  private let select: Select
  private let verify: Verify
  private let read: @Sendable (String) throws -> Data
  private let clock: @Sendable () -> Date
  private let sleep: @Sendable (TimeInterval) async throws -> Void

  init(model: (any JourneyTestModelGenerating)?,
       select: @escaping Select = { event, bytes in
         try PostcardHandwritingPolicy.select(event: event, base: bytes)
       },
       verify: @escaping Verify = { event, base, ink in
         try PostcardHandwritingPolicy.verify(event: event, base: base, ink: ink)
       },
       read: @escaping @Sendable (String) throws -> Data = { try GeneratedPostcardImageReader().read(path: $0) },
       clock: @escaping @Sendable () -> Date = Date.init,
       sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
    self.model = model; self.select = select; self.verify = verify; self.read = read
    self.clock = clock; self.sleep = sleep
  }

  func prepare(event: TripEvent, sourceRelativePath: String, session: JourneyTestSession,
               leaseExpiresAt: Date, acceptedReference: PostcardPresentationReference?) async throws -> PostcardPresentationReference {
    try Task.checkCancellation()
    try session.validate()
    guard let physical = realpath(session.root.path, nil) else { throw PostcardPresentationError.unsafePath }
    let root = URL(fileURLWithPath: String(cString: physical)); free(physical)
    let store = PostcardPresentationStore(root: root)
    if let acceptedReference {
      do {
        _ = try store.load(reference: acceptedReference, event: event, expectedSourceRelativePath: sourceRelativePath)
        try Task.checkCancellation()
        return acceptedReference
      } catch is CancellationError { throw CancellationError() }
      catch { /* Invalid accepted artifacts are never reused. */ }
    }
    // Capture the fallback and its source binding before any suspension or generation.
    let fallback = try store.prepare(event: event, expectedSourceRelativePath: sourceRelativePath,
      handwriting: .localFallback(model == nil ? .unavailable : .generationFailed),
      placement: .init(x: 0, y: 0, width: 1, height: 1), styleVersion: Self.styleVersion)
    let captured = try store.load(reference: fallback, event: event, expectedSourceRelativePath: sourceRelativePath)
    func validFallback() throws -> PostcardPresentationReference {
      try Task.checkCancellation()
      try session.validate()
      _ = try store.load(reference: fallback, event: event, expectedSourceRelativePath: sourceRelativePath)
      return fallback
    }
    guard let model else { return try validFallback() }
    let deadline = min(leaseExpiresAt.addingTimeInterval(-15), clock().addingTimeInterval(600))
    guard deadline > clock() else { return try validFallback() }
    do {
      let result = try await withThrowingTaskGroup(of: Generated.self) { group in
        group.addTask {
          try await generate(event: event, base: captured.landscapeData, session: session, model: model, deadline: deadline)
        }
        group.addTask {
          try await sleep(max(0, deadline.timeIntervalSince(clock())))
          throw Failure.deadline
        }
        defer { group.cancelAll() }
        guard let value = try await group.next() else { throw Failure.generationFailed }
        return value
      }
      try Task.checkCancellation()
      guard clock() < deadline else { return try validFallback() }
      // Reject a changed source before writing, and again after prepare's independent reads.
      _ = try validFallback()
      let generated = try store.prepare(event: event, expectedSourceRelativePath: sourceRelativePath,
        handwriting: .generated(result.data), placement: result.placement, styleVersion: Self.styleVersion)
      let verified = try store.load(reference: generated, event: event, expectedSourceRelativePath: sourceRelativePath)
      guard verified.manifest.source.sha256 == captured.manifest.source.sha256,
            verified.manifest.landscape.sha256 == captured.manifest.landscape.sha256 else { throw PostcardPresentationError.invalidBinding }
      try Task.checkCancellation()
      try session.validate()
      return generated
    } catch {
      try Task.checkCancellation()
      if error is CancellationError { throw error }
      return try validFallback()
    }
  }

  private struct Generated: Sendable { let data: Data; let placement: PostcardPresentationRect }
  private func generate(event: TripEvent, base: Data, session: JourneyTestSession,
                        model: any JourneyTestModelGenerating, deadline: Date) async throws -> Generated {
    let hint = try await Self.offMain { try select(event, base) }
    var correction: PostcardHandwritingPolicy.Correction?
    for attempt in 0..<2 {
      try Task.checkCancellation()
      guard clock() < deadline else { throw Failure.deadline }
      do {
        let prompt = try PostcardHandwritingPolicy.prompt(event: event, hint: hint, correction: correction)
        let response = try await model.generateJSON(prompt: prompt, schema: Self.schema, session: session, referenceImage: nil)
        try Task.checkCancellation()
        guard clock() < deadline else { throw Failure.deadline }
        struct Output: Decodable { let imagePath: String }
        guard response.count <= 65_536,
              let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              Set(object.keys) == ["imagePath"] else { throw Failure.invalidGeneratedImage }
        let output = try JSONDecoder().decode(Output.self, from: response)
        let result = try await Self.offMain {
          let ink = try read(output.imagePath)
          let placement = try verify(event, base, ink)
          try Task.checkCancellation()
          return Generated(data: ink, placement: placement)
        }
        try Task.checkCancellation()
        guard clock() < deadline else { throw Failure.deadline }
        return result
      } catch {
        try Task.checkCancellation()
        if error is CancellationError { throw error }
        if case Failure.deadline = error { throw error }
        guard attempt == 0 else { throw error }
        correction = PostcardHandwritingPolicy.feedback(error)
      }
    }
    throw Failure.generationFailed
  }

  private static func offMain<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
    let task = Task.detached {
      try Task.checkCancellation()
      let result = try operation()
      try Task.checkCancellation()
      return result
    }
    return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
  }

  private static let schema = Data(#"{"type":"object","additionalProperties":false,"required":["imagePath"],"properties":{"imagePath":{"type":"string","minLength":1}}}"#.utf8)
}
