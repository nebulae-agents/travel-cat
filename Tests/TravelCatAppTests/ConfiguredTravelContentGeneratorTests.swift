import Foundation
import XCTest
import CoreGraphics
import ImageIO
import TravelCore
import TravelStorage
@testable import TravelCatApp

private final class ConfiguredProviderProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest, Data) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 8192)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            let response = try Self.handler!(request, body)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor private final class ConfiguredCredentials: TravelServiceCredentialStoring {
    var reads = 0
    func read(id: String) throws -> String? { reads += 1; return "fixture-key" }
    func save(_ secret: String?, id: String) throws {}
}
@MainActor private final class ConfiguredCodex: TravelContentGenerating {
    var calls = 0
    func narrative(for request: TravelEventRequest) async throws -> TravelNarrative {
        calls += 1
        return TravelNarrative(summary: "Codex fixture", mood: request.claim.snapshot.mood, location: nil,
                               transport: nil, continuityReferences: ["家"], openHook: nil, consumedItemID: nil, scenePrompt: nil)
    }
    func image(for work: PendingImageWork, in workspace: URL) async throws -> URL { calls += 1; return workspace.appendingPathComponent("codex.png") }
}
private final class ConfiguredClock: TravelClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ date: Date) { lock.lock(); defer { lock.unlock() }; value = date }
}

@MainActor final class ConfiguredTravelContentGeneratorTests: XCTestCase {
    private func client() -> OpenAICompatibleTravelClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConfiguredProviderProtocol.self]
        return OpenAICompatibleTravelClient(session: URLSession(configuration: config))
    }
    private func configuration() -> TravelGenerationConfiguration {
        var config = TravelGenerationConfiguration()
        config.onboardingCompleted = true
        config.narrative = TravelServiceConfiguration(kind: .openAICompatible, baseURL: "http://localhost:3210/v1", model: "text-fixture")
        config.image = TravelServiceConfiguration(kind: .openAICompatible, baseURL: "http://localhost:3210/v1", model: "gpt-image-1", useImageEdits: true)
        return config
    }
    private func request(root: URL) throws -> TravelEventRequest {
        let repo = try TravelRepository(root: root)
        return TravelEventRequest(claim: DueClaim(due: true, snapshot: try repo.loadSnapshot(), previousEvent: nil), recentEvents: [], phase: .preparing)
    }
    private func png(width: Int = 1536, height: Int = 1024) throws -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.3, green: 0.4, blue: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
    func testIncompleteOnboardingBlocksBothBackendsAndCredentials() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = configuration(); config.onboardingCompleted = false
        let credentials = ConfiguredCredentials(), codex = ConfiguredCodex()
        let generator = ConfiguredTravelContentGenerator(configuration: { config }, credentials: credentials, codex: codex, client: client())
        do { _ = try await generator.narrative(for: request(root: root)); XCTFail() }
        catch { XCTAssertTrue(error is GenerationSetupError) }
        XCTAssertEqual(credentials.reads, 0); XCTAssertEqual(codex.calls, 0)
    }
    func testLiveConfigurationSwitchesNarrativeBackendAndEmbedsSchemaAndRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = configuration(); config.narrative.kind = .codex
        let credentials = ConfiguredCredentials(), codex = ConfiguredCodex()
        let generator = ConfiguredTravelContentGenerator(configuration: { config }, credentials: credentials, codex: codex, client: client())
        let eventRequest = try request(root: root)
        let first = try await generator.narrative(for: eventRequest)
        XCTAssertEqual(first.summary, "Codex fixture"); XCTAssertEqual(credentials.reads, 0)
        config.narrative.kind = .openAICompatible
        ConfiguredProviderProtocol.handler = { request, body in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
            let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            XCTAssertEqual(object["model"] as? String, "text-fixture")
            let messages = object["messages"] as! [[String: String]]
            XCTAssertTrue(messages[0]["content"]!.contains("OUTPUT SCHEMA:"))
            XCTAssertTrue(messages[0]["content"]!.contains("REQUEST JSON:"))
            return try Self.reply(to: body, ordinal: 1)
        }
        let second = try await generator.narrative(for: eventRequest)
        XCTAssertTrue(second.summary.contains("湖岸")); XCTAssertEqual(codex.calls, 1); XCTAssertEqual(credentials.reads, 1)
    }
    nonisolated private static func reply(to body: Data, ordinal: Int) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let prompt = (object["messages"] as! [[String: String]])[0]["content"]!
        let requestJSON = prompt.components(separatedBy: "REQUEST JSON:\n").last!
        let request = try JSONDecoder.travelCat.decode(TravelEventRequest.self, from: Data(requestJSON.utf8))
        let narrative = TravelNarrative(summary: "黑猫沿着湖岸继续慢慢前行，发现石桥边的新倒影，也记得上次离家时带上的小背包。",
            mood: Mood(level: request.claim.snapshot.mood.level, label: "平静", quote: "水里的倒影真有意思。"),
            location: [.exploring, .postcardReady].contains(request.phase) ? Location(country: "中国", city: "杭州", place: "湖岸石桥第\(ordinal)处") : nil,
            transport: request.phase == .transit ? "步行" : nil,
            continuityReferences: [request.claim.previousEvent?.summary ?? "从温暖的小屋出发"], openHook: nil, consumedItemID: nil,
            scenePrompt: request.phase == .postcardReady ? "黑猫坐在杭州湖岸的石桥旁看倒影" : nil)
        let content = String(decoding: try JSONEncoder.travelCat.encode(narrative), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
    }
    func testWorkerPublishesNarrativesAndReferencedImageThroughHTTPAndSurvivesRestart() async throws {
        try await exerciseWorker(validImage: true)
    }
    func testWorkerRejectsWrongImageRatioWithoutPublishingImage() async throws {
        try await exerciseWorker(validImage: false)
    }
    private func exerciseWorker(validImage: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var config = configuration()
        let store = TravelGenerationConfigurationStore(root: root)
        try store.save(config)
        config = try store.load(hasExistingHistory: false)
        let pngData = try png(width: validImage ? 1536 : 1024)
        nonisolated(unsafe) var narratives = 0
        nonisolated(unsafe) var images = 0
        ConfiguredProviderProtocol.handler = { request, body in
            if request.url?.path.hasSuffix("chat/completions") == true {
                narratives += 1
                return try Self.reply(to: body, ordinal: narratives)
            }
            images += 1
            XCTAssertEqual(request.url?.path, "/v1/images/edits")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")!.contains("multipart/form-data"))
            let multipart = String(decoding: body, as: UTF8.self)
            XCTAssertEqual(multipart.components(separatedBy: "name=\"image[]\"").count - 1, 3)
            XCTAssertTrue(multipart.contains("1536x1024")); XCTAssertTrue(multipart.contains("SCENE JSON:"))
            return try JSONSerialization.data(withJSONObject: ["data": [["b64_json": pngData.base64EncodedString()]]])
        }
        let clock = ConfiguredClock(Date(timeIntervalSince1970: 1_787_000_000))
        let repo = try TravelRepository(root: root, clock: clock)
        var now = try repo.loadSnapshot().lastUpdatedAt
        let generator = ConfiguredTravelContentGenerator(configuration: { config }, credentials: ConfiguredCredentials(), codex: ConfiguredCodex(), client: client())
        var worker = AutomaticTravelWorker(repository: repo, generator: generator, clock: { now })
        for index in 0..<40 {
            now = now.addingTimeInterval(121); clock.set(now)
            _ = try await worker.step(settings: TravelSettings(mode: .fast))
            if index == 3 { worker = AutomaticTravelWorker(repository: repo, generator: generator, clock: { now }) }
            if images > 0 { break }
        }
        XCTAssertGreaterThanOrEqual(narratives, 4); XCTAssertEqual(images, 1)
        let events = try repo.events()
        XCTAssertGreaterThanOrEqual(events.count, 4)
        let postcard = try XCTUnwrap(events.first { $0.phase == .postcardReady })
        if validImage {
            XCTAssertEqual(postcard.postcardStatus, .ready)
            let path = try XCTUnwrap(postcard.postcardRelativePath)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), pngData)
            let reopened = try TravelRepository(root: root, clock: clock)
            XCTAssertEqual(try reopened.events(), events)
        } else {
            XCTAssertNotEqual(postcard.postcardStatus, .ready)
            XCTAssertNil(postcard.postcardRelativePath)
        }
        for pair in zip(events, events.dropFirst()) { XCTAssertEqual(pair.1.previousEventID, pair.0.id) }
    }
}
