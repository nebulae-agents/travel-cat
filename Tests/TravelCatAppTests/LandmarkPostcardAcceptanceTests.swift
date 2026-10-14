import Foundation
import ImageIO
import XCTest
import TravelCore
import TravelStorage
import TravelUI
@testable import TravelCatApp

/// Manual real-generation/render acceptance. Inputs are synthetic journeys;
/// no repository, formal journal, user settings or credentials are mutated.
@MainActor
final class LandmarkPostcardAcceptanceTests: XCTestCase {
    func testIsolatedLandmarkPostcards() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let mode = environment["TRAVEL_CAT_LANDMARK_ACCEPTANCE"],
              ["narrative", "render"].contains(mode) else {
            throw XCTSkip("Opt-in isolated landmark narrative and postcard acceptance")
        }
        let path = environment["TRAVEL_CAT_LANDMARK_ACCEPTANCE_ROOT"]
            ?? "/tmp/travelcat-landmark-acceptance-\(UUID().uuidString)"
        if let selected = environment["TRAVEL_CAT_LANDMARK_ACCEPTANCE_CASE"] {
            try require(["beijing", "guilin", "dunhuang"].contains(selected), "Unknown acceptance case")
        }
        let requestedRoot = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let parent = requestedRoot.deletingLastPathComponent().resolvingSymlinksInPath()
        let root = parent.appendingPathComponent(requestedRoot.lastPathComponent, isDirectory: true)
        let allowedParent = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath()
        guard parent.path == allowedParent.path,
              root.lastPathComponent.hasPrefix("travelcat-landmark-acceptance-"),
              root.resolvingSymlinksInPath().standardizedFileURL.path == root.standardizedFileURL.path else {
            print("LANDMARK_ACCEPTANCE_ROOT_REJECTED parent=\(parent.path) root=\(root.path) resolved=\(root.resolvingSymlinksInPath().path)")
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if mode == "render" {
            // Fictional shared home exercises same-city and longer-distance stamps.
            let stateFolder = try safeURL(root.appendingPathComponent("state", isDirectory: true), root: root)
            try FileManager.default.createDirectory(at: stateFolder, withIntermediateDirectories: true)
            let home = HomeLocation(country: "中国", city: "北京", source: .manual, updatedAt: Date())
            try write(JSONEncoder.travelCat.encode(HomeLocationState(location: home)),
                      to: stateFolder.appendingPathComponent("home-location.json"), root: root)
            var priorQuotes = Set<String>()
            for name in ["beijing", "guilin", "dunhuang"] {
                let folder = try safeURL(root.appendingPathComponent(name, isDirectory: true), root: root)
                try recordAcceptance(false, stage: "render-started", folder: folder, root: root)
                var event = try JSONDecoder.travelCat.decode(TripEvent.self,
                    from: Data(contentsOf: safeURL(folder.appendingPathComponent("event.json"), root: root)))
                let narrative = try JSONDecoder.travelCat.decode(TravelNarrative.self,
                    from: Data(contentsOf: safeURL(folder.appendingPathComponent("narrative.json"), root: root)))
                let validation = try JSONDecoder.travelCat.decode(ValidationResult.self,
                    from: Data(contentsOf: safeURL(folder.appendingPathComponent("validation.json"), root: root)))
                try require(validation.valid && validation.publishEnvelope?.event == event, "Saved structural validation must match event")
                try checkScene(event, narrative: narrative, name: name, priorQuotes: &priorQuotes)
                let photo = try safeURL(root.appendingPathComponent("postcards/\(event.tripID.uuidString)/photo.png"), root: root)
                try require(FileManager.default.fileExists(atPath: photo.path), "Missing generated photo")
                event.postcardStatus = .ready
                event.postcardRelativePath = "postcards/\(event.tripID.uuidString)/photo.png"
                for face in [PostcardFace.scenic, .message] {
                    let data = try await PostcardExporter.pngData(event: event, rootURL: root, face: face,
                        recipient: PostcardRecipientInfo(name: "亲爱的你", address: "北京 · 旅行中的家", postalCode: "100000"),
                        travelDate: event.occurredAt)
                    let image = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                    let pixels = try XCTUnwrap(CGImageSourceCreateImageAtIndex(image, 0, nil))
                    try require(pixels.width == 1536 && pixels.height == 1024, "Unexpected postcard dimensions")
                    try write(data, to: folder.appendingPathComponent(face == .scenic ? "scenic.png" : "message.png"), root: root)
                }
                try write(JSONEncoder.travelCat.encode(event), to: folder.appendingPathComponent("ready-event.json"), root: root)
                try recordAcceptance(true, stage: "rendered", folder: folder, root: root)
            }
            return
        }

        let generator = CodexTravelContentGenerator(executor: CodexTravelExecutor(timeout: 180))
        let places = [
            ("beijing", "北京", "天坛祈年殿南侧步道", "祈年殿",
             "小黑在北京天坛祈年殿南侧的铺装步道停下，日间自然光下，看见三层圆形蓝瓦屋檐、红柱和白石台基。它抬头看看，又低头看看自己小小的爪印。"),
            ("guilin", "桂林", "象鼻山景区滨江观景步道", "象鼻山",
             "小黑在桂林象鼻山景区滨江观景步道看风景，日间自然光里，灰白的石山像临江饮水的大象，水月洞与碧绿江水相映。它在岸边慢慢走，没有踏进河里。"),
            ("dunhuang", "敦煌", "鸣沙山月牙泉景区沙坡观景处", "月牙泉",
             "小黑在敦煌鸣沙山月牙泉景区的开放沙坡停下，日间自然光下远望沙丘环抱的月牙形泉水和岸边木构楼阁。微风掠过干燥的沙地，它等爪边的细沙安定下来。"),
        ]
        var priorQuotes = Set<String>()
        for (index, item) in places.enumerated() {
            if let selected = environment["TRAVEL_CAT_LANDMARK_ACCEPTANCE_CASE"], selected != item.0 { continue }
            let folder = try safeURL(root.appendingPathComponent(item.0, isDirectory: true), root: root)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try recordAcceptance(false, stage: "started", folder: folder, root: root)
            do {
                let time = Date()
                let tripID = UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", index + 1))!
                let priorID = UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", index + 1))!
                let eventID = UUID(uuidString: String(format: "30000000-0000-0000-0000-%012d", index + 1))!
                let mood = Mood(level: 0, label: "平静", quote: "我想慢慢看清这片风景。")
                let previous = TripEvent(id: priorID, tripID: tripID, previousEventID: nil,
                    occurredAt: time.addingTimeInterval(-600), phase: .exploring,
                    location: Location(country: "中国", city: item.1, place: item.2), transport: "步行",
                    summary: item.4, mood: mood, continuityReferences: ["已在这座城市探索"], openHook: nil,
                    consumedItemID: nil, postcardStatus: .none, postcardRelativePath: nil)
                let snapshot = TripSnapshot(stateVersion: 4, tripID: tripID, lastEventID: priorID,
                    phase: .exploring, nextActionAt: time, lastUpdatedAt: previous.occurredAt,
                    usedItemIDs: [], visitedPlaces: [item.2], mood: mood)
                let request = TravelEventRequest(claim: DueClaim(due: true, snapshot: snapshot, previousEvent: previous),
                    recentEvents: [previous], phase: .postcardReady, now: time)
                try write(JSONEncoder.travelCat.encode(request), to: folder.appendingPathComponent("request.json"), root: root)
                try write(Data(TravelGenerationPrompts.narrative().utf8), to: folder.appendingPathComponent("narrative-prompt.txt"), root: root)
                print("LANDMARK_ACCEPTANCE_REQUEST=\(item.0)")
                let narrative = try await generator.narrative(for: request)
                try write(JSONEncoder.travelCat.encode(narrative), to: folder.appendingPathComponent("narrative.json"), root: root)
                let candidate = AgentEventEnvelope(eventId: eventID, tripId: tripID, previousEventId: priorID,
                    occurredAt: Date(), phase: .postcardReady, location: narrative.location, transport: narrative.transport,
                    summary: narrative.summary, mood: narrative.mood, continuityReferences: narrative.continuityReferences,
                    openHook: narrative.openHook, consumedItemId: narrative.consumedItemID,
                    postcard: PostcardRequest(required: true, scenePrompt: narrative.scenePrompt))
                let result = candidate.validationResult(previous: snapshot, mode: .fast, calendar: .current, now: Date())
                try write(JSONEncoder.travelCat.encode(result), to: folder.appendingPathComponent("validation.json"), root: root)
                try require(result.valid, "\(result.violations)")
                let event = try XCTUnwrap(result.publishEnvelope).event
                try write(JSONEncoder.travelCat.encode(event), to: folder.appendingPathComponent("event.json"), root: root)
                try write(Data(TravelGenerationPrompts.image(for: event).utf8), to: folder.appendingPathComponent("image-prompt.txt"), root: root)
                try checkScene(event, narrative: narrative, name: item.0, priorQuotes: &priorQuotes)
                try recordAcceptance(true, stage: "narrative", folder: folder, root: root)
                print("LANDMARK_ACCEPTANCE_READY=\(item.0)")
            } catch {
                try recordAcceptance(false, stage: "failed", folder: folder, root: root)
                print("LANDMARK_ACCEPTANCE_FAILED=\(item.0)")
                throw error
            }
        }
    }

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else {
            XCTFail(message)
            throw AcceptanceError.failed(message)
        }
    }

    private func safeURL(_ url: URL, root: URL) throws -> URL {
        let value = url.standardizedFileURL
        guard value.path.hasPrefix(root.path + "/"),
              value.resolvingSymlinksInPath().path == value.path else {
            throw CocoaError(.fileWriteNoPermission)
        }
        return value
    }

    private func write(_ data: Data, to url: URL, root: URL) throws {
        try data.write(to: safeURL(url, root: root), options: .atomic)
    }

    private func recordAcceptance(_ passed: Bool, stage: String, folder: URL, root: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: ["passed": passed, "stage": stage], options: [.sortedKeys])
        try write(data, to: folder.appendingPathComponent("acceptance.json"), root: root)
    }

    private func checkScene(_ event: TripEvent, narrative: TravelNarrative, name: String,
                            priorQuotes: inout Set<String>) throws {
        let city = ["beijing": "北京", "guilin": "桂林", "dunhuang": "敦煌"][name]!
        let landmark = ["beijing": "祈年殿", "guilin": "象鼻山", "dunhuang": "月牙泉"][name]!
        let location = try XCTUnwrap(event.location)
        try require(event.postcardStyleVersion == 4 && location.country == "中国" && location.city == city,
                    "Unexpected postcard style or destination")
        // A real named viewpoint may differ from the landmark photographed there.
        let knownViewpoint = name == "beijing" && location.place == "天坛丹陛桥"
        try require(location.place.contains(landmark) || knownViewpoint, "Expected named landmark or documented nearby viewpoint")
        let summaryNamesTheSight = event.summary.contains(landmark) || (name == "guilin" && event.summary.contains("水月洞"))
        try require(summaryNamesTheSight && (narrative.scenePrompt?.contains(landmark) ?? false),
                    "Expected landmark in the story and photographed scene")
        try require(event.summary == narrative.summary && event.location == narrative.location && event.mood == narrative.mood,
                    "Saved event must retain the actual narrative")
        try require(priorQuotes.insert(event.mood.quote).inserted, "Quotes should not be identical across scenes")
    }

    private enum AcceptanceError: Error { case failed(String) }
}
