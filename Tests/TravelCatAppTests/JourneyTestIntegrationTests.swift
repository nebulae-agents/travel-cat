import XCTest
import TravelStorage
import TravelCore
import TravelUI
@testable import TravelCatApp

final class JourneyTestIntegrationTests: XCTestCase {
    func testSettingsSeparatesCompactAndRealJourneyActions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let settings = try String(contentsOf: root.appendingPathComponent("Sources/TravelCatApp/TravelCatSettingsView.swift"), encoding: .utf8)
        let app = try String(contentsOf: root.appendingPathComponent("Sources/TravelCatApp/TravelCatApp.swift"), encoding: .utf8)
        XCTAssertTrue(settings.contains("紧凑测试完整旅程"))
        XCTAssertTrue(settings.contains("真实生成测试旅程"))
        XCTAssertTrue(settings.contains("requestRealJourney"))
        XCTAssertTrue(settings.contains("不消耗模型额度"))
        XCTAssertFalse(settings.contains("阶段间隔约 10 秒"))
        XCTAssertTrue(app.contains("startJourneyTest(mode: .compact)"))
        XCTAssertTrue(app.contains("startJourneyTest(mode: .realGeneration)"))
        XCTAssertTrue(app.contains("compactImageURL:"))
    }

    func testParentCreationRejectsProductionOverlapBeforeCreatingAnyDirectory() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let production = temporary.appendingPathComponent("production")
        try FileManager.default.createDirectory(at: production, withIntermediateDirectories: false)
        let forbidden = production.appendingPathComponent("nested/JourneyTests")
        XCTAssertThrowsError(try JourneyTestParentDirectory.prepare(at: forbidden, productionRoot: production))
        XCTAssertFalse(FileManager.default.fileExists(atPath: production.appendingPathComponent("nested").path))
        let allowed = temporary.appendingPathComponent("tests/JourneyTests")
        try JourneyTestParentDirectory.prepare(at: allowed, productionRoot: production)
        XCTAssertTrue(FileManager.default.fileExists(atPath: allowed.path))
    }

    @MainActor
    func testOldPaperCallbackCannotBypassDisabledSwitchOrOpenReplacementSession() {
        let first = UUID()
        var enabled = false
        var current: UUID? = first
        let gate = JourneyTestRouteGate(isEnabled: { enabled }, currentSessionID: { current })
        let testModel = AppModel(snapshot: .empty(now: Date()))
        let productionModel = AppModel(snapshot: .empty(now: Date()))
        XCTAssertFalse(gate.route(.status, sessionID: first, model: testModel))
        XCTAssertEqual(testModel.presentation, .pet)
        enabled = true
        current = UUID()
        XCTAssertFalse(gate.route(.status, sessionID: first, model: testModel))
        current = first
        XCTAssertTrue(gate.route(.status, sessionID: first, model: testModel))
        XCTAssertEqual(testModel.presentation, .status)
        XCTAssertEqual(productionModel.presentation, .pet)
    }

    @MainActor
    func testFailedSettingsSaveDoesNotChangeEffectiveTestGate() {
        enum Failure: Error { case denied }
        var applied = 0
        let settings = TravelSettings(mode: .fast)
        let lifecycle = TravelSettingsLifecycle(
            initialSettings: settings, persist: { _ in throw Failure.denied },
            apply: { _ in applied += 1 }
        )
        _ = lifecycle.save(TravelSettings(mode: .daily))
        XCTAssertTrue(lifecycle.effectiveSettings.isFastTestEnabled)
        XCTAssertEqual(applied, 0)
    }

    func testTestPaperPreservesRealContentButClearlyLabelsIsolation() {
        let original = PetTravelBubbleContent(delivery: .prompt(.departed(
            eventID: UUID(), tripID: UUID(), location: nil, summary: "带着茶香出发。"
        )))
        let test = original.markedAsTestJourney
        XCTAssertEqual(test.eyebrow, "测试旅程 · 准备出发")
        XCTAssertEqual(test.title, original.title)
        XCTAssertEqual(test.message, original.message)
        XCTAssertEqual(original.eyebrow, "准备出发")
    }
}
