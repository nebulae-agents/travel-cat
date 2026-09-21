import AppKit
import SwiftUI
import XCTest
import TravelCore
import TravelStorage
import TravelUI
@testable import TravelCatApp

final class TravelCatAppSourceContractTests: XCTestCase {
    func testAcceptedPresentationReferencesReachFormalAndTestRoutes() throws {
        let app = try appSource()
        let settings = try settingsSource()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let views = try String(contentsOf: root.appendingPathComponent("Sources/TravelUI/TravelViews.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains("presentationReferences: loaded.presentationReferences"))
        XCTAssertTrue(settings.contains("presentationReferences: contents.presentationReferences"))
        for source in [app, views] {
            XCTAssertTrue(source.contains("presentationReference: model.presentationReferences[event.id]"))
            XCTAssertTrue(source.contains("presentationReferences: model.presentationReferences"))
        }
        XCTAssertTrue(views.contains("presentationReference: presentationReferences[event.id]"))
    }
    func testApplicationHasNoLegacyHostPermissionOrLocatorEntryPoints() throws {
        let app = try appSource()
        for legacy in ["CodexPetContextMenuCoordinator", "CodexPetLocator", "contextMenuPermissionState", "enableCodexPetTravelMenu"] {
            XCTAssertFalse(app.contains(legacy), legacy)
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let plist = try String(contentsOf: root.appendingPathComponent("packaging/Info.plist"))
        XCTAssertFalse(plist.contains("TravelCatPetMenuUsageDescription"))
    }
    func testStartupWatcherAndHistoryClearPropagateEffectiveCharacterProfile() throws {
        let app = try appSource()
        let settings = try settingsSource()
        XCTAssertTrue(app.contains("characterProfile: loaded.characterProfile"))
        XCTAssertTrue(settings.contains("characterProfile: contents.characterProfile"))
        XCTAssertTrue(app.contains("environment.applyRepositoryContents(contents)"))
        XCTAssertTrue(settings.contains("selectedCharacterProfile = contents.selectedCharacterProfile"))
        XCTAssertTrue(settings.contains("model.replaceAfterHistoryClear"))
    }

    func testSettingsExposesAtomicCharacterSelectionWithoutChangingCodexPet() throws {
        let settings = try settingsSource()
        XCTAssertTrue(settings.contains("Section(\"角色\")"))
        XCTAssertTrue(settings.contains("repository.configureCharacter"))
        XCTAssertTrue(settings.contains("NSOpenPanel"))
        XCTAssertTrue(settings.contains("恢复内置黑猫"))
        XCTAssertTrue(settings.contains("不会更改 Codex 自己的宠物设置"))
        XCTAssertTrue(settings.contains("panel.showsHiddenFiles = true"))
        XCTAssertTrue(settings.contains("ProcessInfo.processInfo.environment"))
        XCTAssertFalse(settings.contains("appendingPathComponent(\"Codex Pets\""))
        XCTAssertFalse(settings.contains("@Published private(set) var effectiveCharacterProfile"))
    }

    func testSettingsExplainsReferenceFreeCustomPetGenerationLimit() throws {
        let settings = try settingsSource()
        XCTAssertTrue(settings.contains("referenceImages.isEmpty"))
        XCTAssertTrue(settings.contains("跨图一致性有限"))
        XCTAssertTrue(settings.contains("不会改用内置黑猫"))
    }
    func testNativeSettingsObservesLaunchStateInsideHostedView() throws {
        let source = try appSource()
        XCTAssertTrue(source.contains("TravelCatSettingsSceneView(appDelegate: appDelegate)"))
        let viewStart = try XCTUnwrap(source.range(of: "struct TravelCatSettingsSceneView: View"))
        let viewSource = source[viewStart.lowerBound...]
        XCTAssertTrue(viewSource.contains("@ObservedObject var appDelegate: TravelCatAppDelegate"))
        XCTAssertTrue(viewSource.contains("if let environment = appDelegate.environment"))
        XCTAssertTrue(viewSource.contains("appDelegate.startupError"))
    }

    func testMenuBarContentAndLabelObservePublishedDelegateStateInsideHostedViews() throws {
        let source = try appSource()

        XCTAssertTrue(source.contains("TravelCatMenuContentView(appDelegate: appDelegate)"))
        XCTAssertTrue(source.contains("TravelCatMenuLabelView(appDelegate: appDelegate)"))

        for (viewName, nextViewName) in [
            ("TravelCatMenuContentView", "TravelCatMenuLabelView"),
            ("TravelCatMenuLabelView", "TravelCatSettingsSceneView"),
        ] {
            let viewStart = try XCTUnwrap(source.range(of: "private struct \(viewName): View"))
            let viewEnd = try XCTUnwrap(
                source.range(of: "private struct \(nextViewName): View", range: viewStart.upperBound..<source.endIndex)
            )
            let viewSource = source[viewStart.lowerBound..<viewEnd.lowerBound]
            XCTAssertTrue(viewSource.contains("@ObservedObject var appDelegate: TravelCatAppDelegate"))
        }
    }

    func testPetMenuConvertsClickCoordinatesAndRevalidatesCloseTarget() throws {
        let source = try appModuleSource()
        XCTAssertTrue(source.contains("at: selection.appKitPoint(fromInput: point)"))
        XCTAssertTrue(source.contains("let current = locator()"))
        XCTAssertTrue(source.contains("current.ownerPID == selection.ownerPID"))
    }

    func testAllPaperConsumersReceiveOwnedWindowLocator() throws {
        let app = try appSource()
        let settings = try settingsSource()
        XCTAssertFalse(settings.contains("CodexPetLocator"))
        XCTAssertEqual(settings.components(separatedBy: "locator: petLocator").count - 1, 2)
        XCTAssertEqual(app.components(separatedBy: "petLocator: { [weak self] in self?.desktopPetAnchor }").count - 1, 2)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let journey = try String(contentsOf: root.appendingPathComponent("Sources/TravelCatApp/JourneyTestPresentation.swift"))
        XCTAssertFalse(journey.contains("CodexPetLocator"))
        XCTAssertTrue(journey.contains("locator: petLocator"))
    }

    func testOwnedPetMenuUsesVisibilityControlWithoutCrossApplicationPermissionPrompt() throws {
        let source = try appSource()
        let start = try XCTUnwrap(source.range(of: "private struct TravelCatMenuContentView"))
        let end = try XCTUnwrap(source.range(of: "private struct TravelCatMenuLabelView"))
        let menu = source[start.lowerBound..<end.lowerBound]
        XCTAssertTrue(menu.contains("DesktopPetVisibilityButton(controller: controller, toggle: appDelegate.toggleDesktopPet)"))
        XCTAssertTrue(menu.contains("显示桌面小猫"))
        XCTAssertTrue(menu.contains("隐藏桌面小猫"))
        XCTAssertFalse(menu.contains("contextMenuPermissionState"))
        XCTAssertFalse(menu.contains("enableCodexPetTravelMenu"))
    }

    func testLaunchClaimsOwnershipBeforeResolvingDirectoriesOrOpeningRepository() throws {
        let source = try appSource()
        let launch = try XCTUnwrap(source.range(of: "func applicationDidFinishLaunching"))
        let ownership = try XCTUnwrap(source.range(of: "SingleInstancePolicy.claimApplicationOwnership()", range: launch.lowerBound..<source.endIndex))
        let currentDirectory = try XCTUnwrap(source.range(of: "FileManager.default.currentDirectoryPath", range: launch.lowerBound..<source.endIndex))
        let repository = try XCTUnwrap(source.range(of: "TravelRepository(root:", range: launch.lowerBound..<source.endIndex))

        XCTAssertLessThan(ownership.lowerBound, currentDirectory.lowerBound)
        XCTAssertLessThan(ownership.lowerBound, repository.lowerBound)
    }

    func testAppContainsApprovedMenuActionsInOrder() throws {
        let source = try appSource()
        let menuStart = try XCTUnwrap(source.range(of: "private struct TravelCatMenuContentView: View"))
        let menuEnd = try XCTUnwrap(source.range(of: "private struct TravelCatMenuLabelView: View", range: menuStart.upperBound..<source.endIndex))
        let menuSource = source[menuStart.lowerBound..<menuEnd.lowerBound]
        let labels = ["当前状态", "最新明信片", "旅行册", "设置…", "退出 Travel Cat"]
        var cursor = menuSource.startIndex

        for label in labels {
            let range = try XCTUnwrap(menuSource.range(of: "\"\(label)\"", range: cursor..<menuSource.endIndex))
            cursor = range.upperBound
        }

        XCTAssertTrue(source.contains("disabled(!appDelegate.hasLatestPostcard)"))
        XCTAssertTrue(source.contains("disabled(!appDelegate.hasLatestAlbum)"))
    }

    func testSettingsMenuUsesDedicatedFixedSizeWindow() throws {
        let source = try appSource()

        XCTAssertTrue(source.contains("private lazy var settingsWindowController = TravelUtilityWindowController()"))
        XCTAssertTrue(source.contains("Button(\"设置…\") { appDelegate.showSettings() }"))
        XCTAssertTrue(source.contains("func showSettings()"))
        XCTAssertTrue(source.contains("TravelUtilityWindowController.settingsSize"))
        XCTAssertFalse(source.contains("SettingsLink {"))
        XCTAssertTrue(source.contains(
            ".frame(minWidth: TravelUtilityWindowController.settingsSize.width, minHeight: TravelUtilityWindowController.settingsSize.height)"
        ))
    }

    func testFastTestIsTheOnlyTestControlAndGuardsEveryEntryPoint() throws {
        let app = try appSource()
        let settings = try settingsSource()

        XCTAssertTrue(settings.contains("Toggle(\"快速测试\""))
        XCTAssertTrue(settings.contains("if environment.effectiveSettings.isFastTestEnabled"))
        XCTAssertTrue(settings.contains("Section(\"完整旅程测试\")"))
        XCTAssertEqual(app.components(separatedBy: "requestFullJourney:").count - 1, 2)
        XCTAssertEqual(app.components(separatedBy: "requestRealJourney:").count - 1, 2)
        XCTAssertEqual(app.components(separatedBy: "requestTestAlbum:").count - 1, 2)
        XCTAssertTrue(app.contains("controller.start(fastTestEnabled: environment.effectiveSettings.isFastTestEnabled, mode: mode)"))
        XCTAssertTrue(app.contains("environment?.journeyTestController?.stop()"))
        XCTAssertTrue(app.contains("journeyTestPresentation?.dismiss()"))
        XCTAssertTrue(app.contains("journeyTestWindowController.window?.close()"))
        XCTAssertTrue(settings.contains("Section(\"旅行册展示测试\")"))
        XCTAssertTrue(settings.contains("Button(\"预览 6 张明信片\") { requestAlbumPreview() }"))
        XCTAssertFalse(settings.contains("Picker(\"旅行频率\""))
        XCTAssertEqual(app.components(separatedBy: "requestAlbumPreview:").count - 1, 2)
        XCTAssertTrue(app.contains("guard let environment,"))
        XCTAssertTrue(app.contains("environment.effectiveSettings.isFastTestEnabled else"))
        let promptStart = try XCTUnwrap(app.range(of: "private func triggerTestPrompt()"))
        let promptBody = app[promptStart.lowerBound...]
        XCTAssertTrue(promptBody.contains("environment.effectiveSettings.isFastTestEnabled else { return }"))
        XCTAssertTrue(settings.contains("bubbleController?.setTestActionsEnabled(settings.isFastTestEnabled)"))
        XCTAssertTrue(settings.contains("testModeChanged(settings.isFastTestEnabled)"))
        XCTAssertTrue(app.contains("self?.closeAlbumPreviewSession()"))
        XCTAssertTrue(app.contains("albumPreviewWindowController.window?.close()"))
    }

    func testAlbumPreviewPassesPackagedCatAssetsToThePreviewFactory() throws {
        let app = try appSource()

        XCTAssertTrue(app.contains("let catResourceURLs = try albumPreviewCatAssetURLs()"))
        XCTAssertTrue(app.contains("catResourceURLs: catResourceURLs"))
        XCTAssertTrue(app.contains("PreviewBlackCatPose.allCases.map"))
        XCTAssertTrue(app.contains("TravelAlbumPreviewCatalog.catResourceURL"))
    }

    func testStartupInstallsOwnedPetWithoutStartingCodexMenuListener() throws {
        let source = try appSource()
        let start = try XCTUnwrap(source.range(of: "func applicationDidFinishLaunching"))
        let end = try XCTUnwrap(source.range(of: "func installDesktopPet"))
        let launch = source[start.lowerBound..<end.lowerBound]
        XCTAssertTrue(launch.contains("installDesktopPet(model: model)"))
        XCTAssertFalse(launch.contains("makeCodexPetContextMenuCoordinator"))
        XCTAssertFalse(launch.contains("contextMenuCoordinator?.start"))
        XCTAssertFalse(launch.contains("refreshContextMenuPermissionState"))
    }

    func testPackagedAppModuleHasNoPetUIRuntimePath() throws {
        let source = try appModuleSource()

        XCTAssertFalse(source.contains("PetWindowController("))
        XCTAssertFalse(source.contains("showPet("))
        XCTAssertFalse(source.contains("setStartupErrorContent("))
        XCTAssertFalse(source.contains("PetRootView("))
        XCTAssertFalse(source.contains("PetHomeView("))
        XCTAssertFalse(source.contains("AwayTagView("))
        XCTAssertFalse(source.contains("PetSpriteView("))
        XCTAssertFalse(source.contains("返回小猫"))
        XCTAssertTrue(source.contains("MenuServiceRootView("))
        XCTAssertTrue(source.contains("CurrentPetStatusView("))
        XCTAssertTrue(source.contains("close: { perform(.closeWindow) }"))
    }

    func testBubbleUsesOneVectorPadAndFourVectorToesWithoutGlyphOrSymbolFallback() throws {
        let source = try bubbleViewSource()
        let pawStart = try XCTUnwrap(source.range(of: "struct PetTravelPawView: View"))
        let pointerStart = try XCTUnwrap(
            source.range(of: "struct PetTravelBubblePointer: Shape", range: pawStart.upperBound..<source.endIndex)
        )
        let pawSource = source[pawStart.lowerBound..<pointerStart.lowerBound]

        XCTAssertTrue(pawSource.contains("Canvas { context, size in"))
        XCTAssertEqual(pawSource.components(separatedBy: "Path(ellipseIn:").count - 1, 2)
        XCTAssertEqual(pawSource.components(separatedBy: "CGPoint(x:").count - 1, 4)
        XCTAssertTrue(pawSource.contains("for center in ["))
        XCTAssertTrue(pawSource.contains(".accessibilityHidden(true)"))
        XCTAssertFalse(source.contains("Text(\"🐾\")"))
        XCTAssertFalse(source.contains("Image(systemName:"))
    }

    func testSlipUsesVectorPointerButCollapsedPawHasNoPaperPointer() throws {
        let source = try bubbleViewSource()
        let slipStart = try XCTUnwrap(source.range(of: "private var paperSlip"))
        let pawStart = try XCTUnwrap(
            source.range(of: "private var pawBadge", range: slipStart.upperBound..<source.endIndex)
        )
        let alignmentStart = try XCTUnwrap(
            source.range(of: "private var pointerAlignment", range: pawStart.upperBound..<source.endIndex)
        )
        let slipSource = source[slipStart.lowerBound..<pawStart.lowerBound]
        let pawSource = source[pawStart.lowerBound..<alignmentStart.lowerBound]

        XCTAssertTrue(source.contains("struct PetTravelBubblePointer: Shape"))
        XCTAssertTrue(source.contains("func path(in rect: CGRect) -> Path"))
        XCTAssertTrue(slipSource.contains("PetTravelBubblePointer("))
        XCTAssertFalse(pawSource.contains("PetTravelBubblePointer("))
        XCTAssertFalse(source.contains("Text(\"➤\")"))
        XCTAssertFalse(source.contains("Text(\"▶\")"))
        XCTAssertFalse(source.contains("Image(systemName:"))
    }

    func testBubbleResolvesTypedLocationThroughTravelUIWithoutASecondAliasResolver() throws {
        let source = try bubbleViewSource()

        XCTAssertTrue(source.contains("PostcardDisplayLocation()"))
        XCTAssertTrue(source.contains("displayLocation.resolve(location)"))
        XCTAssertFalse(source.contains("resolveLocation"))
        XCTAssertFalse(source.contains("Otsu Port old pier"))
        XCTAssertFalse(source.contains("switch (country"))
    }

    func testTravelCatAppDelegateStillNeverConstructsLegacyPetUI() throws {
        let source = try appSource()
        let delegateStart = try XCTUnwrap(source.range(of: "final class TravelCatAppDelegate"))
        let delegateSource = source[delegateStart.lowerBound..<source.endIndex]

        XCTAssertFalse(delegateSource.contains("PetWindowController("))
        XCTAssertFalse(delegateSource.contains("PetSpriteView("))
    }

    func testMenuActionsUseDedicatedJourneySettingsAndAlbumPreviewWindows() throws {
        let source = try appSource()

        XCTAssertEqual(source.components(separatedBy: "TravelUtilityWindowController()").count - 1, 4)
        XCTAssertTrue(source.contains("private lazy var utilityWindowController"))
        XCTAssertTrue(source.contains("private lazy var settingsWindowController"))
        XCTAssertTrue(source.contains("private lazy var albumPreviewWindowController"))
        XCTAssertTrue(source.contains("private lazy var journeyTestWindowController"))
        XCTAssertTrue(source.contains("model.openStatusFromMenu()"))
        XCTAssertTrue(source.contains("model.openLatestPostcardFromMenu()"))
        XCTAssertTrue(source.contains("model.openLatestAlbumFromMenu()"))
        XCTAssertTrue(source.contains("StartupErrorView(message:"))
    }

    func testApplicationTerminationWaitsForOwnedTestProcessToDrain() throws {
        let source = try appSource()
        XCTAssertTrue(source.contains("func applicationShouldTerminate(_ sender: NSApplication)"))
        XCTAssertTrue(source.contains("await controller.shutdown()"))
        XCTAssertTrue(source.contains("return .terminateLater"))
        XCTAssertTrue(source.contains("sender.reply(toApplicationShouldTerminate: true)"))
    }

    func testWatcherAppliesModelBeforeRepositoryOwnedPromptIngestion() throws {
        let source = try appSource()
        let watcherStart = try XCTUnwrap(source.range(of: "private func startWatching"))
        let watcherSource = source[watcherStart.lowerBound..<source.endIndex]

        XCTAssertFalse(watcherSource.contains("PetTravelPromptDetector.detect"))
        XCTAssertFalse(watcherSource.contains("notificationService.process("))
        XCTAssertTrue(watcherSource.contains("notificationService.processUnavailable("))
        XCTAssertTrue(watcherSource.contains("petPromptService.ingestCurrent"))
        assertOrder(watcherSource, "environment.applyRepositoryContents", before: "petPromptService.ingestCurrent")
        assertOrder(watcherSource, "petPromptService.ingestCurrent", before: "previous = contents")
    }

    func testRuntimePathsReadOnlyEffectiveSettingsWhileUIBindsCandidate() throws {
        let app = try appSource()
        let settings = try settingsSource()

        XCTAssertFalse(app.contains("environment.settings"))
        XCTAssertTrue(app.contains("petPromptService.retry(settings: environment.effectiveSettings"))
        XCTAssertEqual(
            app.components(separatedBy: "settings: environment.effectiveSettings").count - 1,
            7,
            "startup, authorization, watcher and status toast must use effective settings"
        )
        XCTAssertTrue(settings.contains("var effectiveSettings: TravelSettings"))
        XCTAssertTrue(settings.contains("var lastPersistedSettings: TravelSettings"))
        XCTAssertTrue(settings.contains("$environment.settings.followCodexPet"))
        XCTAssertTrue(settings.contains(".onChange(of: environment.settings)"))
    }

    func testSettingsFormHasEnoughHeightToRenderInsideMacOSSettingsScene() throws {
        let settings = try settingsSource()

        XCTAssertTrue(
            settings.contains(".frame(width: 480)\n        .frame(minHeight: 520)"),
            "A scrollable Form has no useful intrinsic height in a macOS Settings scene"
        )
    }

    func testLaunchAndCallbacksRetryPersistedPromptDelivery() throws {
        let app = try appSource()
        let settings = try settingsSource()
        let launchStart = try XCTUnwrap(app.range(of: "func applicationDidFinishLaunching"))
        let launchEnd = try XCTUnwrap(app.range(of: "func applicationWillTerminate", range: launchStart.upperBound..<app.endIndex))
        let launchSource = app[launchStart.lowerBound..<launchEnd.lowerBound]

        XCTAssertTrue(launchSource.contains("petPromptService.retry"))
        XCTAssertTrue(launchSource.contains("notificationService.processUnavailable("))
        XCTAssertTrue(settings.contains("notificationService?.settingsDidChange(settings)"))
        XCTAssertTrue(settings.contains("petPromptService?.settingsDidChange(settings: settings, now: Date())"))
    }

    func testEnvironmentOwnsOneBubbleAndPromptServiceAfterPrimaryOwnership() throws {
        let app = try appSource()
        let settings = try settingsSource()
        let launchStart = try XCTUnwrap(app.range(of: "func applicationDidFinishLaunching"))
        let ownership = try XCTUnwrap(app.range(of: "SingleInstancePolicy.claimApplicationOwnership()", range: launchStart.lowerBound..<app.endIndex))
        let environment = try XCTUnwrap(app.range(of: "TravelCatEnvironment(", range: ownership.upperBound..<app.endIndex))

        XCTAssertLessThan(ownership.lowerBound, environment.lowerBound)
        XCTAssertEqual(settings.components(separatedBy: "PetTravelBubbleController(").count - 1, 1)
        XCTAssertEqual(settings.components(separatedBy: "PetTravelPromptService(").count - 1, 1)
        XCTAssertTrue(settings.contains("preferBubble: { $0.followCodexPet }"))
        XCTAssertTrue(settings.contains("bubbleController?.settingsDidChange(followCodexPet: enabled)"))
        XCTAssertTrue(settings.contains("Toggle(\"旅行纸条与状态变化提示\""))
        XCTAssertFalse(app.contains("PetWindowController("))
        XCTAssertFalse(app.contains("PetSpriteView("))
    }

    func testPromptRouteOpensExactContentAndFallsBackToCurrentJourney() throws {
        let source = try appSource()
        let routeStart = try XCTUnwrap(source.range(of: "func performPromptRoute(_ route: PetTravelRoute)"))
        let routeEnd = try XCTUnwrap(source.range(of: "private func show(model:", range: routeStart.upperBound..<source.endIndex))
        let routeSource = source[routeStart.lowerBound..<routeEnd.lowerBound]

        XCTAssertTrue(routeSource.contains("model.openPostcardFromPrompt(eventID: eventID, tripID: tripID)"))
        XCTAssertTrue(routeSource.contains("model.openAlbumFromPrompt(tripID: tripID)"))
        XCTAssertEqual(routeSource.components(separatedBy: "showCurrentJourney()").count - 1, 3)
        XCTAssertTrue(routeSource.contains("TravelUtilityWindowController.postcardSize"))
        XCTAssertTrue(routeSource.contains("TravelUtilityWindowController.albumSize"))
    }

    func testMenuPawReflectsPendingPromptState() throws {
        let source = try appSource()

        XCTAssertTrue(source.contains("petPromptPending ? \"pawprint.circle.fill\" : \"pawprint.fill\""))
    }

    @MainActor
    func testWatcherAndAuthorizationReadOldEffectiveSettingsUntilCandidateSaveSucceeds() {
        let initial = TravelSettings(followCodexPet: true)
        var persisted: [TravelSettings] = []
        var applied: [TravelSettings] = []
        var effectiveObservedWhilePersisting: [TravelSettings] = []
        var lifecycle: TravelSettingsLifecycle!
        lifecycle = TravelSettingsLifecycle(
            initialSettings: initial,
            persist: {
                persisted.append($0)
                effectiveObservedWhilePersisting.append(lifecycle.effectiveSettings)
            },
            apply: { applied.append($0) }
        )
        let candidate = TravelSettings(followCodexPet: false)
        var uiSettings = initial
        let watcherSettings = { lifecycle.effectiveSettings }
        let authorizationSettings = { lifecycle.effectiveSettings }

        uiSettings = candidate
        XCTAssertEqual(uiSettings, candidate, "the UI candidate changes before its onChange save runs")
        XCTAssertEqual(watcherSettings(), initial)
        XCTAssertEqual(authorizationSettings(), initial)
        XCTAssertEqual(lifecycle.lastPersistedSettings, initial)
        let outcome = lifecycle.save(uiSettings)

        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(persisted, [candidate])
        XCTAssertEqual(effectiveObservedWhilePersisting, [initial])
        XCTAssertEqual(applied, persisted)
        XCTAssertEqual(watcherSettings(), candidate)
        XCTAssertEqual(authorizationSettings(), candidate)
        XCTAssertEqual(lifecycle.lastPersistedSettings, candidate)
    }

    @MainActor
    func testFailedCandidateNeverChangesWatcherOrAuthorizationEffectiveSettings() throws {
        enum SaveFailure: Error { case denied }
        let persisted = TravelSettings(followCodexPet: true)
        var attempts: [TravelSettings] = []
        var applied: [TravelSettings] = []
        var effectiveObservedWhilePersisting: [TravelSettings] = []
        var lifecycle: TravelSettingsLifecycle!
        lifecycle = TravelSettingsLifecycle(
            initialSettings: persisted,
            persist: {
                attempts.append($0)
                effectiveObservedWhilePersisting.append(lifecycle.effectiveSettings)
                throw SaveFailure.denied
            },
            apply: { applied.append($0) }
        )
        let candidate = TravelSettings(followCodexPet: false)
        var uiSettings = persisted
        let watcherSettings = { lifecycle.effectiveSettings }
        let authorizationSettings = { lifecycle.effectiveSettings }

        uiSettings = candidate
        XCTAssertEqual(uiSettings, candidate, "the UI candidate changes before its onChange save runs")
        XCTAssertEqual(watcherSettings(), persisted)
        XCTAssertEqual(authorizationSettings(), persisted)
        let failure = lifecycle.save(uiSettings)
        XCTAssertEqual(watcherSettings(), persisted)
        XCTAssertEqual(authorizationSettings(), persisted)
        let rollback = lifecycle.save(persisted)

        guard case let .rollback(restored, message) = failure else {
            return XCTFail("expected rollback, got \(failure)")
        }
        XCTAssertEqual(restored, persisted)
        XCTAssertTrue(message.hasPrefix("设置保存失败："))
        XCTAssertEqual(rollback, .ignoredRollback)
        XCTAssertEqual(attempts, [candidate])
        XCTAssertEqual(effectiveObservedWhilePersisting, [persisted])
        XCTAssertTrue(applied.isEmpty, "runtime services must never observe settings that failed to persist")
        XCTAssertEqual(lifecycle.lastPersistedSettings, persisted)

        let settingsSource = try settingsSource()
        XCTAssertTrue(settingsSource.contains("case let .rollback(persisted, message):"))
        XCTAssertTrue(settingsSource.contains("settings = persisted"))
        XCTAssertTrue(settingsSource.contains("case .ignoredRollback:"))
        XCTAssertTrue(settingsSource.contains("break"), "rollback reentry must not clear the existing error")
    }

    @MainActor
    func testAlbumWindowCannotResizeBelowReadableArtworkWidth() {
        let controller = TravelUtilityWindowController()
        controller.show(content: AnyView(Text("album")), size: TravelUtilityWindowController.albumSize)

        XCTAssertEqual(controller.window?.contentMinSize.width, TripAlbumLayout.minimumWindowContentWidth)
    }

    private func appSource() throws -> String {
        let testsURL = URL(fileURLWithPath: #filePath)
        let packageRoot = testsURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/TravelCatApp/TravelCatApp.swift"),
            encoding: .utf8
        )
    }

    private func appModuleSource() throws -> String {
        let testsURL = URL(fileURLWithPath: #filePath)
        let packageRoot = testsURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceDirectory = packageRoot.appendingPathComponent("Sources/TravelCatApp", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .map { try String(contentsOf: $0, encoding: .utf8) }
        .joined(separator: "\n")
    }

    private func bubbleViewSource() throws -> String {
        let testsURL = URL(fileURLWithPath: #filePath)
        let packageRoot = testsURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/TravelCatApp/PetTravelBubbleView.swift"),
            encoding: .utf8
        )
    }

    private func settingsSource() throws -> String {
        let testsURL = URL(fileURLWithPath: #filePath)
        let packageRoot = testsURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/TravelCatApp/TravelCatSettingsView.swift"),
            encoding: .utf8
        )
    }

    private func assertOrder(
        _ source: some StringProtocol,
        _ first: String,
        before second: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let firstRange = source.range(of: first),
              let secondRange = source.range(of: second) else {
            XCTFail("Missing ordered markers: \(first), \(second)", file: file, line: line)
            return
        }
        XCTAssertLessThan(
            source.distance(from: source.startIndex, to: firstRange.lowerBound),
            source.distance(from: source.startIndex, to: secondRange.lowerBound),
            file: file,
            line: line
        )
    }
}

@MainActor
final class TravelCatMenuTitleTests: XCTestCase {
    func testTitleMapsEveryTravelPhase() {
        XCTAssertEqual(TravelCatAppDelegate.menuTitle(phase: .resting, currentPlace: nil), "Travel Cat · 在家休息")
        XCTAssertEqual(TravelCatAppDelegate.menuTitle(phase: .preparing, currentPlace: nil), "Travel Cat · 准备出发")
        XCTAssertEqual(TravelCatAppDelegate.menuTitle(phase: .transit, currentPlace: "西湖"), "Travel Cat · 旅途中")
        XCTAssertEqual(TravelCatAppDelegate.menuTitle(phase: .exploring, currentPlace: "西湖"), "Travel Cat · 西湖")
        XCTAssertEqual(TravelCatAppDelegate.menuTitle(phase: .postcardReady, currentPlace: "灵隐寺"), "Travel Cat · 灵隐寺")
        XCTAssertEqual(TravelCatAppDelegate.menuTitle(phase: .returning, currentPlace: "西湖"), "Travel Cat · 回家途中")
    }

    func testExploringAndPostcardReadyWithoutPlaceFallBackToTransitTitle() {
        XCTAssertEqual(TravelCatAppDelegate.menuTitle(phase: .exploring, currentPlace: nil), "Travel Cat · 旅途中")
        XCTAssertEqual(TravelCatAppDelegate.menuTitle(phase: .postcardReady, currentPlace: ""), "Travel Cat · 旅途中")
    }
}

final class MenuServiceRoutePolicyTests: XCTestCase {
    func testStatusClosesWindowButCanOpenAPostcard() {
        let postcardID = UUID()

        XCTAssertEqual(MenuServiceRoutePolicy.action(from: .status, to: .status), .closeWindow)
        XCTAssertEqual(
            MenuServiceRoutePolicy.action(from: .status, to: .postcard(postcardID)),
            .handle(.postcard(postcardID))
        )
    }

    func testPostcardBackPreservesItsModelReturnRouteAndAlbumNavigation() {
        let tripID = UUID()

        XCTAssertEqual(MenuServiceRoutePolicy.action(from: .postcard, to: .status), .modelClose)
        XCTAssertEqual(
            MenuServiceRoutePolicy.action(from: .postcard, to: .album(tripID)),
            .handle(.album(tripID))
        )
    }

    func testAlbumCanOpenPostcardAndClosesBackToStatus() {
        let postcardID = UUID()

        XCTAssertEqual(
            MenuServiceRoutePolicy.action(from: .album, to: .postcard(postcardID)),
            .handle(.postcard(postcardID))
        )
        XCTAssertEqual(MenuServiceRoutePolicy.action(from: .album, to: .status), .openStatus)
    }

    func testPetAndOtherUnsupportedDestinationsNormalizeToStatus() {
        for context in MenuServiceRouteContext.allCases {
            XCTAssertEqual(MenuServiceRoutePolicy.action(from: context, to: .pet), .openStatus)
            XCTAssertEqual(MenuServiceRoutePolicy.action(from: context, to: .awayTag), .openStatus)
            XCTAssertEqual(MenuServiceRoutePolicy.action(from: context, to: .supplies), .openStatus)
        }

        XCTAssertEqual(MenuServiceRoutePolicy.normalized(.pet), .status)
        XCTAssertEqual(MenuServiceRoutePolicy.normalized(.awayTag), .status)
        XCTAssertEqual(MenuServiceRoutePolicy.normalized(.supplies), .status)
        XCTAssertEqual(MenuServiceRoutePolicy.normalized(.album(UUID())), .album)
    }
}

@MainActor
final class TravelUtilityWindowControllerTests: XCTestCase {
    func testMakeWindowCreatesOrdinaryRetainedHostingWindow() {
        let window = TravelUtilityWindowController.makeWindow(
            content: AnyView(Text("status")),
            size: TravelUtilityWindowController.statusSize
        )

        XCTAssertEqual(window.title, "Travel Cat")
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(window.styleMask.contains(.miniaturizable))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.level, .normal)
        XCTAssertFalse(window is PetPanel)
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertTrue(window.contentView is NSHostingView<AnyView>)
        XCTAssertTrue((window.contentView as? NSHostingView<AnyView>)?.sizingOptions.isEmpty == true)
        XCTAssertEqual(window.contentView?.frame.size, NSSize(width: 420, height: 520))
    }

    func testRouteSizesMatchApprovedUtilityWindowDimensions() {
        XCTAssertEqual(TravelUtilityWindowController.statusSize, NSSize(width: 420, height: 520))
        XCTAssertEqual(TravelUtilityWindowController.postcardSize, NSSize(width: 520, height: 680))
        XCTAssertEqual(TravelUtilityWindowController.albumSize, NSSize(width: 760, height: 700))
    }

    func testRepeatedShowReusesOneWindowAndClosingDoesNotReleaseIt() throws {
        let controller = TravelUtilityWindowController()
        let originalWindow = try XCTUnwrap(controller.window)
        let originalIdentifier = ObjectIdentifier(originalWindow)

        controller.show(content: AnyView(Text("status")), size: TravelUtilityWindowController.statusSize)
        controller.show(content: AnyView(Text("postcard")), size: TravelUtilityWindowController.postcardSize)

        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(controller.window)), originalIdentifier)
        XCTAssertEqual(controller.window?.contentView?.frame.size, NSSize(width: 520, height: 680))
        originalWindow.close()
        controller.show(content: AnyView(Text("album")), size: TravelUtilityWindowController.albumSize)
        XCTAssertEqual(ObjectIdentifier(try XCTUnwrap(controller.window)), originalIdentifier)
        // AppKit may reduce the requested height on small CI displays. Compare
        // against its screen constraint, not a desktop-specific pixel height.
        var requestedContent = originalWindow.contentRect(forFrameRect: originalWindow.frame)
        requestedContent.size = TravelUtilityWindowController.albumSize
        let requestedFrame = originalWindow.frameRect(forContentRect: requestedContent)
        let constrainedFrame = originalWindow.constrainFrameRect(
            requestedFrame, to: originalWindow.screen ?? NSScreen.main
        )
        let expectedSize = originalWindow.contentRect(forFrameRect: constrainedFrame).size
        XCTAssertEqual(controller.window?.contentView?.frame.size, expectedSize)
    }
}
