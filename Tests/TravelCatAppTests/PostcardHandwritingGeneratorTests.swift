import CoreGraphics
import Darwin
import Foundation
import ImageIO
import TravelCore
import TravelStorage
import TravelUI
import XCTest
@testable import TravelCatApp

final class PostcardHandwritingGeneratorTests: XCTestCase {
  func testTwoRejectedAttemptsProduceBoundFallbackAndStableExactPrompt() async throws {
    let f = try fixture(), model = InkModel()
    let service = PostcardHandwritingGenerator(model: model, select: { _, _ in Self.hint },
      verify: { _, _, _ in throw PostcardHandwritingVerifier.Rejection.invalidText }, read: { _ in Data([1]) })
    let ref = try await service.prepare(event: f.event, sourceRelativePath: f.path, session: f.session,
      leaseExpiresAt: Date().addingTimeInterval(100), acceptedReference: nil)
    let value = try f.store.load(reference: ref, event: f.event, expectedSourceRelativePath: f.path)
    XCTAssertEqual(value.manifest.handwriting, .localFallback(.generationFailed))
    let prompts = await model.prompts
    XCTAssertEqual(prompts.count, 2)
    XCTAssertEqual(prompts[0], try PostcardHandwritingPolicy.prompt(event: f.event, hint: Self.hint))
    XCTAssertEqual(prompts[1], try PostcardHandwritingPolicy.prompt(event: f.event, hint: Self.hint, correction: .invalidText))
    let first = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(prompts[0].utf8)) as? [String: Any])
    let correction = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(prompts[1].utf8)) as? [String: Any])
    XCTAssertEqual(first["quote"] as? String, f.event.mood.quote)
    XCTAssertEqual(first["style"] as? String, correction["style"] as? String)
    XCTAssertEqual(correction["correction"] as? String, "invalidText")
    XCTAssertEqual(correction["correctionInstructions"] as? String,
      "Write the exact quote with clearly separated, unambiguous glyphs. Do not add, omit or substitute characters.")
    XCTAssertFalse(prompts[1].contains("private-path"))
    let reused = try await service.prepare(event: f.event, sourceRelativePath: f.path, session: f.session,
      leaseExpiresAt: Date().addingTimeInterval(100), acceptedReference: ref)
    XCTAssertEqual(reused, ref)
    let count = await model.prompts.count
    XCTAssertEqual(count, 2)
  }

  func testVerifiedBytesArePreparedAndReusedWithoutFurtherGeneration() async throws {
    // Verifier injection tests orchestration and original-byte storage, not successful real OCR.
    let f = try fixture(), model = InkModel(), ink = try Self.png(ink: true)
    let service = PostcardHandwritingGenerator(model: model, select: { _, _ in Self.hint },
      verify: { _, _, _ in Self.hint.safeArea }, read: { _ in ink })
    let ref = try await service.prepare(event: f.event, sourceRelativePath: f.path, session: f.session,
      leaseExpiresAt: Date().addingTimeInterval(100), acceptedReference: nil)
    XCTAssertEqual(try f.store.load(reference: ref, event: f.event, expectedSourceRelativePath: f.path).handwritingData, ink)
    _ = try await service.prepare(event: f.event, sourceRelativePath: f.path, session: f.session,
      leaseExpiresAt: Date().addingTimeInterval(100), acceptedReference: ref)
    let count = await model.prompts.count
    XCTAssertEqual(count, 1)
  }

  func testNoGeneratorAndDeadlineHaveExplicitFallbackWithoutCalls() async throws {
    let f = try fixture(), model = InkModel()
    for service in [PostcardHandwritingGenerator(model: nil), PostcardHandwritingGenerator(model: model)] {
      let ref = try await service.prepare(event: f.event, sourceRelativePath: f.path, session: f.session,
        leaseExpiresAt: Date().addingTimeInterval(10), acceptedReference: nil)
      XCTAssertNil(try f.store.load(reference: ref, event: f.event, expectedSourceRelativePath: f.path).handwritingData)
    }
    let count = await model.prompts.count
    XCTAssertEqual(count, 0)
  }

  func testSourceMutationDuringModelAwaitCannotBindToNewBase() async throws {
    let f = try fixture(), replacement = try Self.png(gray: 0.4), ink = try Self.png(ink: true)
    let model = InkModel(action: { try replacement.write(to: f.session.root.appendingPathComponent(f.path), options: .atomic) })
    let service = PostcardHandwritingGenerator(model: model, select: { _, _ in Self.hint },
      verify: { _, _, _ in Self.hint.safeArea }, read: { _ in ink })
    do {
      _ = try await service.prepare(event: f.event, sourceRelativePath: f.path, session: f.session,
        leaseExpiresAt: Date().addingTimeInterval(100), acceptedReference: nil)
      XCTFail("Changed source must not yield any publishable reference")
    } catch { XCTAssertFalse(error is CancellationError) }
    let count = await model.prompts.count
    XCTAssertEqual(count, 1)
  }

  func testUserCancellationThrowsInsteadOfReturningFallback() async throws {
    let f = try fixture(), entered = InkGate()
    let model = InkModel(action: { await entered.enter(); try await Task.sleep(for: .seconds(100)) })
    let service = PostcardHandwritingGenerator(model: model, select: { _, _ in Self.hint })
    let task = Task { try await service.prepare(event: f.event, sourceRelativePath: f.path, session: f.session,
      leaseExpiresAt: Date().addingTimeInterval(100), acceptedReference: nil) }
    await entered.wait()
    task.cancel()
    do { _ = try await task.value; XCTFail("Cancellation cannot produce fallback") }
    catch { XCTAssertTrue(error is CancellationError) }
  }

  func testInFlightDeadlineCancelsModelAndReturnsCapturedFallback() async throws {
    let f = try fixture(), entered = InkGate()
    let model = InkModel(action: { await entered.enter(); try await Task.sleep(for: .seconds(100)) })
    let service = PostcardHandwritingGenerator(model: model, select: { _, _ in Self.hint },
      sleep: { _ in await entered.wait() })
    let ref = try await service.prepare(event: f.event, sourceRelativePath: f.path, session: f.session,
      leaseExpiresAt: Date().addingTimeInterval(100), acceptedReference: nil)
    XCTAssertEqual(try f.store.load(reference: ref, event: f.event, expectedSourceRelativePath: f.path).manifest.handwriting,
      .localFallback(.generationFailed))
    let count = await model.prompts.count
    XCTAssertEqual(count, 1)
  }

  private static var hint: PostcardHandwritingGenerator.Hint {
    .init(safeArea: .init(x: 0.1, y: 0.1, width: 0.5, height: 0.2), color: .init(red: 0, green: 0, blue: 0))
  }
  private struct Fixture: Sendable {
    let session: JourneyTestSession; let event: TripEvent; let path: String
    var store: PostcardPresentationStore {
      let path = realpath(session.root.path, nil)!
      defer { free(path) }
      return .init(root: URL(fileURLWithPath: String(cString: path)))
    }
  }
  private func fixture() throws -> Fixture {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    let parent = root.appendingPathComponent("JourneyTests"), production = root.appendingPathComponent("production")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: production, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let session = try JourneyTestSession.create(parent: parent, productionRoot: production), trip = UUID()
    let path = "postcards/\(trip.uuidString.lowercased())/original.png"
    try FileManager.default.createDirectory(at: session.root.appendingPathComponent(path).deletingLastPathComponent(), withIntermediateDirectories: true)
    try Self.png().write(to: session.root.appendingPathComponent(path))
    let event = TripEvent(id: UUID(), tripID: trip, previousEventID: nil, occurredAt: Date(), phase: .postcardReady,
      location: nil, transport: nil, summary: "summary", mood: .init(level: 1, label: "开心", quote: " café\n旅行正好 "),
      continuityReferences: [], openHook: nil, consumedItemID: nil, postcardStatus: .pendingImage, postcardRelativePath: nil)
    return .init(session: session, event: event, path: path)
  }
  private static func png(ink: Bool = false, gray: CGFloat = 1) throws -> Data {
    let w = ink ? 100 : 1152, h = ink ? 50 : 768
    let c = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    c.setFillColor(CGColor(gray: gray, alpha: 1))
    c.fill(ink ? CGRect(x: 4, y: 4, width: w - 8, height: h - 8) : CGRect(x: 0, y: 0, width: w, height: h))
    let bytes = NSMutableData(), dest = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(dest, try XCTUnwrap(c.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(dest)); return bytes as Data
  }
}

private actor InkModel: JourneyTestModelGenerating {
  var prompts: [String] = []
  let action: @Sendable () async throws -> Void
  init(action: @escaping @Sendable () async throws -> Void = {}) { self.action = action }
  func generateJSON(prompt: String, schema: Data, session: JourneyTestSession, referenceImage: URL?) async throws -> Data {
    prompts.append(prompt); try await action()
    return Data(#"{"imagePath":"/private-path/ink.png"}"#.utf8)
  }
}
private actor InkGate {
  var entered = false
  func enter() { entered = true }
  func wait() async { while !entered { await Task.yield() } }
}
