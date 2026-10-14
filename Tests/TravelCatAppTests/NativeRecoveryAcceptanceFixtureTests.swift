import Foundation
import XCTest
import TravelCore
import TravelStorage
@testable import TravelCatApp

/// Opt-in data preparation only. Native interaction is performed separately.
final class NativeRecoveryAcceptanceFixtureTests: XCTestCase {
    func testPrepareIsolatedNativeRecoveryFixture() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TRAVEL_CAT_NATIVE_ACCEPTANCE_ROOT"],
              let portText = environment["TRAVEL_CAT_NATIVE_ACCEPTANCE_PORT"],
              let port = Int(portText), (1...65535).contains(port) else {
            throw XCTSkip("Opt-in isolated native recovery data preparation")
        }
        let requested = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let parent = requested.deletingLastPathComponent().resolvingSymlinksInPath()
        let root = parent.appendingPathComponent(requested.lastPathComponent, isDirectory: true)
        guard parent == URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath(),
              root.lastPathComponent.hasPrefix("travelcat-native-acceptance-"),
              root.resolvingSymlinksInPath().standardizedFileURL == root.standardizedFileURL,
              !FileManager.default.fileExists(atPath: root.path) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let repository = try TravelRepository(root: root)
        let now = Date().addingTimeInterval(-600)
        let trip = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        let previous = TripEvent(id: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
            tripID: trip, previousEventID: nil, occurredAt: now, phase: .preparing,
            location: nil, transport: nil, summary: "小黑整理好旅行册，准备回看湖边的照片。",
            mood: Mood(level: 0, label: "平静", quote: "我想慢慢看清这片风景。"),
            continuityReferences: ["隔离验收的虚构旅程"], openHook: nil, consumedItemID: nil,
            postcardStatus: .none, postcardRelativePath: nil)
        let next = TripSnapshot(stateVersion: 1, tripID: trip, lastEventID: previous.id,
            phase: .preparing, nextActionAt: Date().addingTimeInterval(86_400), lastUpdatedAt: now,
            usedItemIDs: [], visitedPlaces: [], mood: previous.mood)
        try repository.publish(event: previous, next: next)
        let backlog = try PostcardBacklogStore(root: root)
        let slot = try XCTUnwrap(backlog.reconcile(events: [previous]).first?.slots.first)
        let supplement = TripEvent(id: slot.id, tripID: trip, previousEventID: previous.id,
            occurredAt: now, phase: .postcardReady,
            location: Location(country: "中国", city: "杭州", place: "西湖湖岸"), transport: "步行",
            summary: "小黑在湖边停下，回想水纹如何慢慢散开，把安静留在旅行册中。",
            mood: Mood(level: 0, label: "平静", quote: "我坐着不动，湖水仍带来新的样子。"),
            continuityReferences: [previous.summary], openHook: nil, consumedItemID: nil,
            postcardStatus: .pendingImage, postcardRelativePath: nil, postcardStyleVersion: 4)
        try backlog.publishSupplement(supplement, slotID: slot.id)
        let stale = try XCTUnwrap(backlog.pendingImages(mode: .daily).first)
        var configuration = TravelGenerationConfiguration()
        configuration.onboardingCompleted = true
        configuration.narrative = TravelServiceConfiguration(kind: .openAICompatible,
            baseURL: "http://127.0.0.1:\(port)/v1", model: "native-text-acceptance")
        configuration.image = TravelServiceConfiguration(kind: .openAICompatible,
            baseURL: "http://127.0.0.1:\(port)/v1", model: "native-image-acceptance")
        try TravelGenerationConfigurationStore(root: root).save(configuration)
        try TravelSettingsStore(root: root).save(TravelSettings(followCodexPet: false, automaticTravelEnabled: true))
        try HomeLocationStore(root: root).save(HomeLocationState(
            location: HomeLocation(country: "中国", city: "北京", source: .manual, updatedAt: now), ipLookupEnabled: false))
        let damage = Data("{native acceptance damaged backlog".utf8)
        try damage.write(to: root.appendingPathComponent("state/postcard-backlog.json"))
        XCTAssertThrowsError(try backlog.supplementalEvents())
        let encoder = JSONEncoder.travelCat
        try encoder.encode(stale).write(to: root.appendingPathComponent("stale-work.json"))
        try encoder.encode(next).write(to: root.appendingPathComponent("initial-snapshot.json"))
        print("NATIVE_RECOVERY_FIXTURE=\(root.path)")
    }
}
