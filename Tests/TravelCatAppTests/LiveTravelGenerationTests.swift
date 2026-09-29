import Foundation
import XCTest
import TravelCore
import TravelStorage
@testable import TravelCatApp

@MainActor
final class LiveTravelGenerationTests: XCTestCase {
    func testLiveBackgroundNarrativeAndPostcard() async throws {
        guard ProcessInfo.processInfo.environment["TRAVEL_CAT_LIVE_GENERATION"] == "1" else {
            throw XCTSkip("Opt-in isolated real Codex generation")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("travelcat-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let now = Date()
        let snapshot = TripSnapshot.empty(now: now)
        let generator = CodexTravelContentGenerator(executor: CodexTravelExecutor(timeout: 900, diagnostics: { data in
            _ = FileManager.default.createFile(atPath: root.appendingPathComponent("codex-diagnostics.jsonl").path,
                contents: data, attributes: [.posixPermissions: 0o600])
        }))
        let request = TravelEventRequest(claim: DueClaim(due: true, snapshot: snapshot, previousEvent: nil), recentEvents: [], phase: .preparing)
        let narrative = try await generator.narrative(for: request)
        let candidate = AgentEventEnvelope(eventId: UUID(), tripId: UUID(), previousEventId: nil,
            occurredAt: now, phase: .preparing, location: narrative.location, transport: narrative.transport,
            summary: narrative.summary, mood: narrative.mood, continuityReferences: narrative.continuityReferences,
            openHook: narrative.openHook, consumedItemId: narrative.consumedItemID,
            postcard: PostcardRequest(required: false, scenePrompt: narrative.scenePrompt))
        let checked = try AgentEventEnvelope.decode(JSONEncoder.travelCat.encode(candidate))
        _ = try checked.validatedProjection(previous: snapshot, mode: .fast, calendar: .current, now: Date())
        try JSONEncoder.travelCat.encode(narrative).write(to: root.appendingPathComponent("narrative.json"))
        let event = TripEvent(id: UUID(), tripID: candidate.tripId, previousEventID: candidate.eventId,
            occurredAt: now, phase: .postcardReady, location: Location(country: "日本", city: "京都", place: "鸭川三条河岸"),
            transport: "步行", summary: "小黑沿着京都鸭川的河岸慢慢散步，夕阳把河水染成金色。它坐在石阶上，把小桥与远处的山一起装进这张明信片。",
            mood: Mood(level: 1, label: "惬意", quote: "把河边的风寄给你。"), continuityReferences: ["带上相机沿河散步"],
            openHook: "今晚沿着河岸回到小旅馆。", consumedItemID: nil, postcardStatus: .pendingImage, postcardRelativePath: nil)
        let work = PendingImageWork(event: event, retry: ImageRetry(attemptCount: 0, retryAt: nil, publishedNarrativeHash: String(repeating: "0", count: 64)))
        let image = try await generator.image(for: work, in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
        print("LIVE_TRAVEL_ARTIFACT=\(root.path)")
    }
}
