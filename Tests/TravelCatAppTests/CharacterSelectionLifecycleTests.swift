import XCTest
import TravelCore
import TravelStorage
import TravelUI
@testable import TravelCatApp

@MainActor
final class CharacterSelectionLifecycleTests: XCTestCase {
    func testSettingsDisplayTracksWatcherAndHistoryReplacementWhileOpen() {
        let first = profile(id: "first", name: "第一只")
        let second = profile(id: "second", name: "第二只")
        let model = AppModel(snapshot: .empty(now: Date()), characterProfile: first)
        let display = CharacterSettingsDisplayState(model: model)

        model.apply(next: model.snapshot, events: [], characterProfile: second)
        XCTAssertEqual(display.effectiveProfile, second)

        model.replaceAfterHistoryClear(next: .empty(now: Date()), events: [], characterProfile: .defaultBlackCat)
        XCTAssertEqual(display.effectiveProfile, .defaultBlackCat)
    }

    func testCodexPetsDirectoryUsesEnvironmentAndEmptyValueFallsBackToDotCodex() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        XCTAssertEqual(
            CodexPetsDirectoryResolver.preferred(environment: ["CODEX_HOME": "/Volumes/shared/codex"], home: home),
            URL(fileURLWithPath: "/Volumes/shared/codex/pets", isDirectory: true)
        )
        XCTAssertEqual(
            CodexPetsDirectoryResolver.preferred(environment: ["CODEX_HOME": ""], home: home),
            URL(fileURLWithPath: "/Users/example/.codex/pets", isDirectory: true)
        )
    }

    func testFailedConfigurationPreservesPublishedSelection() {
        let initial = CharacterConfigurationResponse(
            selectedProfile: .defaultBlackCat,
            effectiveProfile: .defaultBlackCat,
            dataRoot: URL(fileURLWithPath: "/tmp/data")
        )
        let lifecycle = CharacterSelectionLifecycle(initial: initial)

        let outcome = lifecycle.update { throw CharacterProfileStoreError.invalidManifest }

        XCTAssertEqual(lifecycle.configuration, initial)
        guard case let .failed(message) = outcome else { return XCTFail("Expected failure") }
        XCTAssertEqual(message, "角色清单 pet.json 格式无效，请选择包含有效清单的宠物文件夹。已保留当前选择。")
        XCTAssertFalse(message.contains("invalidManifest"))
    }

    private func profile(id: String, name: String) -> CharacterProfile {
        CharacterProfile(
            id: id, displayName: name, description: "", spriteVersionNumber: 2,
            sprite: .dataRootRelative("characters/\(id)/revision/assets/pet.webp"),
            referenceImages: [], source: .importedManifest("characters/\(id)/revision/source-manifest.json")
        )
    }
}
