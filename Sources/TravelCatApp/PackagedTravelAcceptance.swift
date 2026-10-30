import CoreGraphics
import Foundation
import ImageIO
import TravelCore
import TravelStorage
import TravelUI
import UniformTypeIdentifiers

/// A fixed, offline acceptance scenario. No paths, providers or configuration are
/// accepted from arguments or environment; only newly created synthetic data is used.
@MainActor
enum PackagedTravelAcceptance {
    enum Failure: String, Error {
        case invalidArguments, notPackagedApp, missingResource, invalidResource, lifecycleFailed, acceptanceFailed
    }
    struct Result: Encodable {
        let schemaVersion = 1
        let status = "ok"
        var packagedResourceCount = 0
        let pendingObserved: Bool
        let readyObserved: Bool
        let readbackVerified: Bool
        let narrativeCalls: Int
        let imageCalls: Int
        let copiedResourceCount: Int
    }
    static let flag = "--offline-packaged-acceptance"
    private static let assetNames = ["narrative.schema.json", "image.schema.json", "front.png", "side.png", "sitting.png", "identity.json"]

    static func isRequested(arguments: [String]) throws -> Bool {
        guard arguments.contains(where: { $0.hasPrefix("--offline-packaged") }) else { return false }
        guard arguments == [flag] else { throw Failure.invalidArguments }
        return true
    }

    static func failureJSON(_ error: Error) -> String {
        // Never interpolate provider text, paths, arguments or arbitrary error bodies.
        let code = (error as? Failure) ?? .acceptanceFailed
        return "{\"schemaVersion\":1,\"status\":\"failed\",\"code\":\"\(code.rawValue)\"}"
    }

    static func run() async throws -> Result {
        let app = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard app.pathExtension == "app" else { throw Failure.notPackagedApp }
        guard let resources = CodexTravelContentGenerator.generationResourceRoot() else { throw Failure.missingResource }
        let ownedPrefix = app.appendingPathComponent("Contents/Resources", isDirectory: true).path + "/"
        guard resources.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(ownedPrefix) else {
            throw Failure.invalidResource
        }
        for name in assetNames {
            let resource = resources.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: resource.path) else { throw Failure.missingResource }
            guard resource.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(ownedPrefix),
                  try FileManager.default.attributesOfItem(atPath: resource.path)[.type] as? FileAttributeType == .typeRegular else {
                throw Failure.invalidResource
            }
            try validateAsset(resource)
        }
        var result = try await runSyntheticLifecycle()
        result.packagedResourceCount = assetNames.count
        return result
    }

    /// Also exercised by XCTest using SwiftPM resources; only run() can authorize the
    /// packaged entry. The synthetic root is never caller-selected or reused.
    static func runSyntheticLifecycle() async throws -> Result {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("travelcat-offline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = AcceptanceClock()
        let repository = try TravelRepository(root: root, clock: clock)
        let fixture = OfflineExecution()
        let generator = CodexTravelContentGenerator(execute: { prompt, workspace, schema, images in
            try await fixture.execute(prompt: prompt, workspace: workspace, schema: schema, images: images)
        })
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let worker = AutomaticTravelWorker(repository: repository, generator: generator,
            clock: { clock.now }, calendar: { calendar })
        var pending: TripEvent?
        for _ in 0..<40 {
            let outcome = try await worker.step(settings: .init(mode: .fast))
            guard outcome.failure == nil else { throw Failure.lifecycleFailed }
            let contents = try repository.loadContents()
            if pending == nil {
                pending = contents.events.first { $0.postcardStatus == .pendingImage }
            }
            if let pending, let ready = contents.events.first(where: { $0.id == pending.id && $0.postcardStatus == .ready }) {
                var expected = pending
                expected.postcardStatus = .ready
                expected.postcardRelativePath = ready.postcardRelativePath
                guard ready == expected, let path = ready.postcardRelativePath,
                      fixture.imageCalls == 1, fixture.copiedResources == Set(assetNames) else {
                    throw Failure.lifecycleFailed
                }
                let reopened = try TravelRepository(root: root, clock: clock).loadContents()
                guard reopened.events.first(where: { $0.id == ready.id }) == ready else { throw Failure.lifecycleFailed }
                let bytes = try PostcardImageLoader.loadData(relativePath: path, rootURL: root)
                let thumbnail = try PostcardImageDecoder.decodeThumbnail(data: bytes)
                guard thumbnail.width == 1024, thumbnail.height > 0 else { throw Failure.lifecycleFailed }
                return Result(pendingObserved: true, readyObserved: true, readbackVerified: true,
                    narrativeCalls: fixture.narrativeCalls, imageCalls: fixture.imageCalls,
                    copiedResourceCount: fixture.copiedResources.count)
            }
            clock.set(max(clock.now.addingTimeInterval(1), outcome.nextCheckAt))
        }
        throw Failure.lifecycleFailed
    }

    private static func validateAsset(_ url: URL) throws {
        do {
            if url.pathExtension == "png" {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      CGImageSourceGetType(source) as String? == UTType.png.identifier,
                      CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw Failure.invalidResource }
            } else {
                guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                    throw Failure.invalidResource
                }
                if url.lastPathComponent == "identity.json" {
                    guard let species = object["species"] as? String, !species.isEmpty else { throw Failure.invalidResource }
                } else {
                    guard object["type"] as? String == "object", object["properties"] is [String: Any] else { throw Failure.invalidResource }
                }
            }
        } catch { throw Failure.invalidResource }
    }

    @MainActor
    private final class OfflineExecution {
        var narrativeCalls = 0
        var imageCalls = 0
        var copiedResources: Set<String> = []

        func execute(prompt: String, workspace: URL, schema: URL?, images: [URL]) async throws -> Data {
            guard !prompt.isEmpty, let schema, schema.deletingLastPathComponent() == workspace else { throw Failure.lifecycleFailed }
            try validateAsset(schema)
            copiedResources.insert(schema.lastPathComponent)
            if schema.lastPathComponent == "narrative.schema.json" {
                guard images.isEmpty else { throw Failure.lifecycleFailed }
                narrativeCalls += 1
                let request = try JSONDecoder.travelCat.decode(TravelEventRequest.self,
                    from: Data(contentsOf: workspace.appendingPathComponent("request.json")))
                let narrative = TravelNarrative(
                    summary: "黑猫沿着蜿蜒的小路继续旅行，记住沿途的风景，也惦记着温暖的小屋。",
                    mood: Mood(level: request.claim.snapshot.mood.level, label: "平静", quote: "今天也有新的风景。"),
                    location: [.exploring, .postcardReady].contains(request.phase) ? Location(country: "中国", city: "杭州", place: "合成湖边第\(narrativeCalls)站") : nil,
                    transport: nil, continuityReferences: [request.claim.previousEvent?.summary ?? "从温暖的小屋出发"],
                    openHook: "继续看看前方的小路", consumedItemID: nil,
                    scenePrompt: request.phase == .postcardReady ? "黑猫在湖边留下旅行合影" : nil)
                return try JSONEncoder.travelCat.encode(narrative)
            }
            guard schema.lastPathComponent == "image.schema.json",
                  images.map(\.lastPathComponent) == ["front.png", "side.png", "sitting.png"] else { throw Failure.lifecycleFailed }
            imageCalls += 1
            _ = try JSONDecoder.travelCat.decode(TripEvent.self, from: Data(contentsOf: workspace.appendingPathComponent("event.json")))
            for asset in images + [workspace.appendingPathComponent("identity.json")] {
                guard asset.deletingLastPathComponent() == workspace else { throw Failure.lifecycleFailed }
                try validateAsset(asset)
                copiedResources.insert(asset.lastPathComponent)
            }
            guard let context = CGContext(data: nil, width: 1152, height: 768, bitsPerComponent: 8,
                bytesPerRow: 1152 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw Failure.lifecycleFailed
            }
            context.setFillColor(CGColor(red: 0.4, green: 0.3, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1152, height: 768))
            let target = workspace.appendingPathComponent("postcard.png")
            guard let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw Failure.lifecycleFailed
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw Failure.lifecycleFailed }
            return Data("{\"status\":\"ready\",\"reason\":\"none\"}".utf8)
        }
    }
}

private final class AcceptanceClock: TravelClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ date: Date) { lock.lock(); defer { lock.unlock() }; value = date }
}
