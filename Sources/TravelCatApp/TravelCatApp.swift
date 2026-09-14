import AppKit
import SwiftUI
import TravelCore
import TravelStorage
import TravelUI

@MainActor
final class TravelCatAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var model: AppModel?
    private lazy var utilityWindowController = TravelUtilityWindowController()
    private lazy var settingsWindowController = TravelUtilityWindowController()
    private lazy var albumPreviewWindowController = TravelUtilityWindowController()
    private lazy var journeyTestWindowController = TravelUtilityWindowController()
    private var journeyTestPresentation: JourneyTestPresentation?
    private var displayedTestPostcardID: UUID?
    private lazy var journeyTestRouteGate = JourneyTestRouteGate(
        isEnabled: { [weak self] in self?.environment?.effectiveSettings.isFastTestEnabled == true },
        currentSessionID: { [weak self] in self?.environment?.journeyTestController?.session?.id }
    )
    private var watcher: RepositoryWatcher?
    private var watcherTask: Task<Void, Never>?
    private var authorizationTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?
    private var albumPreviewSession: TravelAlbumPreviewSession?
    @Published private(set) var environment: TravelCatEnvironment?
    @Published private(set) var desktopPetController: DesktopPetController?
    @Published private(set) var startupError: String?
    @Published private(set) var statusTitle = "Travel Cat"
    @Published private(set) var hasLatestPostcard = false
    @Published private(set) var hasLatestAlbum = false
    @Published private(set) var petPromptPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard SingleInstancePolicy.claimApplicationOwnership() else { return }
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let isDevelopmentRoot = FileManager.default.fileExists(
            atPath: currentDirectory.appendingPathComponent("Package.swift").path
        ) && FileManager.default.fileExists(
            atPath: currentDirectory.appendingPathComponent("Sources/TravelCatApp", isDirectory: true).path
        )
        let developmentRoot = isDevelopmentRoot ? currentDirectory : nil
        let bundledDataRoot = (Bundle.main.object(forInfoDictionaryKey: "TravelCatDataRoot") as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { path in
                path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true) : nil
            }
        guard let applicationSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            showStartupError("Application Support directory is unavailable.")
            return
        }
        let rootURL = AppDataRootResolver().resolve(
            environment: ProcessInfo.processInfo.environment,
            bundledDataRoot: bundledDataRoot,
            developmentProjectRoot: developmentRoot,
            applicationSupportDirectory: applicationSupport
        )
        do {
            let repository = try TravelRepository(root: rootURL)
            let loaded = try repository.loadContents()
            let settings = try TravelSettingsStore(root: rootURL).load()
            let model = AppModel(
                snapshot: loaded.snapshot,
                events: loaded.events,
                dataRoot: rootURL,
                characterProfile: loaded.characterProfile,
                persistSupply: repository.updateCarriedItem
            )
            let environment = try TravelCatEnvironment(
                repository: repository,
                model: model,
                settings: settings,
                selectedCharacterProfile: loaded.selectedCharacterProfile,
                petLocator: { [weak self] in self?.desktopPetAnchor },
                route: { [weak self] route in self?.performPromptRoute(route) },
                testRequest: { [weak self] in self?.triggerTestPrompt() },
                testModeChanged: { [weak self] enabled in
                    self?.journeyTestSettingsChanged(enabled: enabled)
                    guard !enabled else { return }
                    self?.closeAlbumPreviewSession()
                },
                promptStateChanged: { [weak self] in self?.refreshPromptState() }
            )
            self.model = model
            self.environment = environment
            environment.notificationService.promptRouteHandler = { [weak self] route in
                self?.performPromptRoute(route)
            }
            refreshMenuState()
            installDesktopPet(model: model)
            environment.petPromptService.retry(settings: environment.effectiveSettings, now: Date())
            refreshPromptState()
            startWatching(repository: repository, initial: loaded, environment: environment)
            authorizationTask = Task { [weak environment] in
                guard let environment else { return }
                await environment.notificationService.requestAuthorization()
                guard !Task.isCancelled, let current = try? repository.loadContents() else { return }
                environment.notificationService.processUnavailable(
                    previous: loaded,
                    current: current,
                    settings: environment.effectiveSettings
                )
                environment.petPromptService.retry(settings: environment.effectiveSettings, now: Date())
                refreshPromptState()
            }
        } catch {
            showStartupError("\(error)")
        }
    }

    var desktopPetAnchor: PetCompanionAnchor? {
        DesktopPetAnchorProvider.current(controller: desktopPetController)
    }

    func installDesktopPet(model: AppModel, defaults: UserDefaults = .standard) {
        desktopPetController?.windowController.close()
        let scene = DesktopPetSceneView(
            model: model,
            showStatus: { [weak self] in self?.showCurrentJourney() },
            showPostcard: { [weak self] in self?.showLatestPostcard() },
            showAlbum: { [weak self] in self?.showLatestAlbum() },
            showSettings: { [weak self] in self?.showSettings() },
            hide: { [weak self] in self?.desktopPetController?.hide() }
        )
        let controller = DesktopPetController(content: AnyView(scene), defaults: defaults)
        desktopPetController = controller
        controller.restoreVisibility()
    }

    func toggleDesktopPet() {
        guard let controller = desktopPetController else { return }
        if controller.isHidden { controller.show() } else { controller.hide() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller = environment?.journeyTestController else { return .terminateNow }
        if terminationTask == nil {
            terminationTask = Task {
                await controller.shutdown()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        desktopPetController?.windowController.close()
        desktopPetController = nil
        environment?.statusToastController.dismiss()
        watcherTask?.cancel()
        authorizationTask?.cancel()
        closeAlbumPreviewSession()
        environment?.journeyTestController?.stop()
        journeyTestPresentation?.dismiss()
        journeyTestPresentation = nil
        watcherTask = nil
        authorizationTask = nil
        watcher = nil
    }

    private func startWatching(
        repository: TravelRepository,
        initial: RepositoryContents,
        environment: TravelCatEnvironment
    ) {
        let watcher = RepositoryWatcher(repository: repository) { message in
            try? FileHandle.standardError.write(
                contentsOf: Data("TravelCat repository watcher: \(message)\n".utf8)
            )
        }
        self.watcher = watcher
        watcherTask = Task { @MainActor [weak environment] in
            var previous: RepositoryContents? = initial
            for await contents in watcher.contents() {
                guard !Task.isCancelled, let environment else { break }
                let changed = contents != previous
                if changed {
                    environment.applyRepositoryContents(contents)
                    refreshMenuState()
                }
                environment.notificationService.processUnavailable(
                    previous: previous,
                    current: contents,
                    settings: environment.effectiveSettings
                )
                environment.petPromptService.ingestCurrent(
                    settings: environment.effectiveSettings,
                    now: Date()
                )
                petPromptPending = environment.petPromptService.hasPendingOrStorageError
                if changed {
                    if !petPromptPending, environment.bubbleController.presentation != .slip,
                       let content = TravelStatusToastPolicy.content(
                        previous: previous, current: contents, now: Date(), settings: environment.effectiveSettings
                       ) {
                        environment.statusToastController.show(content) { [weak self] in self?.showCurrentJourney() }
                    } else {
                        environment.statusToastController.dismiss()
                    }
                }
                previous = contents
            }
        }
    }

    func showCurrentJourney() {
        if let startupError {
            utilityWindowController.show(
                content: AnyView(StartupErrorView(message: startupError)),
                size: TravelUtilityWindowController.statusSize
            )
            return
        }
        guard let model else { return }
        model.openStatusFromMenu()
        show(model: model, size: TravelUtilityWindowController.statusSize)
    }

    func showLatestPostcard() {
        guard let model, hasLatestPostcard else { return }
        model.openLatestPostcardFromMenu()
        show(model: model, size: TravelUtilityWindowController.postcardSize)
    }

    func showLatestAlbum() {
        guard let model, hasLatestAlbum else { return }
        model.openLatestAlbumFromMenu()
        show(model: model, size: TravelUtilityWindowController.albumSize)
    }

    func showSettings() {
        guard let environment else { return }
        settingsWindowController.window?.title = "Travel Cat 设置"
        settingsWindowController.show(
            content: AnyView(
                TravelCatSettingsView(
                    environment: environment,
                    requestAlbumPreview: { [weak self] in
                        self?.showAlbumPreview()
                    },
                    requestFullJourney: { [weak self] in self?.startFullJourneyTest() },
                    requestRealJourney: { [weak self] in self?.startRealJourneyTest() },
                    requestTestAlbum: { [weak self] in self?.showTestJourneyAlbum() }
                )
            ),
            size: TravelUtilityWindowController.settingsSize
        )
    }

    func showAlbumPreview() {
        guard let environment,
              environment.effectiveSettings.isFastTestEnabled else {
            closeAlbumPreviewSession()
            return
        }
        guard let session = currentAlbumPreviewSession() else { return }
        albumPreviewWindowController.setCloseHandler({ [weak self] in
            self?.closeAlbumPreviewSession()
        })
        albumPreviewWindowController.show(
            content: AnyView(
                MenuServiceRootView(
                    model: session.model,
                    closeWindow: { [weak self] in
                        self?.albumPreviewWindowController.window?.close()
                    },
                    presentationChanged: { _ in }
                )
            ),
            size: TravelUtilityWindowController.albumSize
        )
        albumPreviewWindowController.bringToFront()
    }

    func startFullJourneyTest() {
        startJourneyTest(mode: .compact)
    }

    func startRealJourneyTest() {
        startJourneyTest(mode: .realGeneration)
    }

    private func startJourneyTest(mode: JourneyTestMode) {
        guard let environment, environment.effectiveSettings.isFastTestEnabled,
              let controller = prepareJourneyTestController() else { return }
        controller.start(fastTestEnabled: environment.effectiveSettings.isFastTestEnabled, mode: mode)
        showTestJourneyWindow()
    }

    func showTestJourneyAlbum() {
        guard environment?.effectiveSettings.isFastTestEnabled == true,
              let controller = prepareJourneyTestController() else { return }
        controller.model?.openLatestAlbumFromMenu()
        showTestJourneyWindow()
    }

    private func prepareJourneyTestController() -> JourneyTestController? {
        guard let environment, environment.effectiveSettings.isFastTestEnabled else { return nil }
        if let controller = environment.journeyTestController { return controller }
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let parent = support.appendingPathComponent("TravelCat/JourneyTests", isDirectory: true)
            // Session creation validates physical separation again before any repository writes.
            try JourneyTestParentDirectory.prepare(at: parent, productionRoot: environment.repository.root)
            let reference = try albumPreviewCatAssetURLs().first
            guard let reference else { throw TravelAlbumPreviewError.invalidAsset("preview-cat-front.png") }
            let generator = JourneyTestDiscoveredModelGenerator()
            let compactImage = try albumPreviewAssetURLs().first {
                $0.lastPathComponent == "preview-hangzhou-garden.png"
            }
            let compactCat = try albumPreviewCatAssetURLs().first {
                $0.lastPathComponent == "preview-cat-side.png"
            }
            let controller = JourneyTestController(
                parentRoot: parent,
                productionRoot: environment.repository.root,
                modelGenerator: generator,
                imageGenerator: JourneyTestCodexImageGenerator(model: generator),
                referenceImageURL: reference,
                compactImageURL: compactImage,
                compactCatImageURL: compactCat
            )
            environment.journeyTestController = controller
            controller.onRefresh = { [weak self] in self?.refreshTestJourneyPresentation() }
            controller.onProgress = { [weak self, weak controller] progress in
                if progress.state == .completed { controller?.model?.openLatestAlbumFromMenu() }
                self?.refreshTestJourneyPresentation()
            }
            refreshTestJourneyPresentation()
            return controller
        } catch {
            environment.errorMessage = "测试旅程无法打开：\(error.localizedDescription)"
            return nil
        }
    }

    private func refreshTestJourneyPresentation() {
        guard let environment, environment.effectiveSettings.isFastTestEnabled,
              let controller = environment.journeyTestController,
              let session = controller.session, let model = controller.model else { return }
        if journeyTestPresentation?.sessionID != session.id {
            journeyTestPresentation?.dismiss()
            displayedTestPostcardID = nil
            do {
                journeyTestPresentation = try JourneyTestPresentation(
                    session: session, model: model, gate: journeyTestRouteGate,
                    petLocator: { [weak self] in self?.desktopPetAnchor },
                    showWindow: { [weak self] in self?.showTestJourneyWindow() }
                )
            } catch {
                environment.errorMessage = "测试纸条无法打开：\(error.localizedDescription)"
                return
            }
        }
        if controller.isRunning,
           let postcard = model.events.last(where: { $0.postcardStatus == .ready }),
           displayedTestPostcardID != postcard.id {
            displayedTestPostcardID = postcard.id
            model.openLatestPostcardFromMenu()
        }
        journeyTestPresentation?.refresh(followCodexPet: environment.effectiveSettings.followCodexPet)
    }

    private func showTestJourneyWindow() {
        guard environment?.effectiveSettings.isFastTestEnabled == true,
              let controller = environment?.journeyTestController else { return }
        journeyTestWindowController.window?.title = "测试旅程 · Travel Cat"
        journeyTestWindowController.show(
            content: AnyView(JourneyTestView(controller: controller, closeWindow: { [weak self] in
                self?.journeyTestWindowController.window?.close()
            })),
            size: TravelUtilityWindowController.albumSize
        )
    }

    private func journeyTestSettingsChanged(enabled: Bool) {
        if enabled {
            refreshTestJourneyPresentation()
        } else {
            environment?.journeyTestController?.stop()
            journeyTestPresentation?.dismiss()
            journeyTestPresentation = nil
            journeyTestWindowController.window?.close()
        }
    }

    func performPromptRoute(_ route: PetTravelRoute) {
        guard let model else { return }
        switch route {
        case .status:
            model.openStatusFromMenu()
            show(model: model, size: TravelUtilityWindowController.statusSize)
        case let .postcard(eventID, tripID):
            if model.openPostcardFromPrompt(eventID: eventID, tripID: tripID) {
                show(model: model, size: TravelUtilityWindowController.postcardSize)
            } else {
                showCurrentJourney()
            }
        case let .album(tripID):
            if model.openAlbumFromPrompt(tripID: tripID) {
                show(model: model, size: TravelUtilityWindowController.albumSize)
            } else {
                showCurrentJourney()
            }
        }
    }

    private func triggerTestPrompt() {
        guard let environment,
              environment.effectiveSettings.isFastTestEnabled else { return }
        let model = environment.model
        environment.petPromptService.retry(settings: environment.effectiveSettings, now: Date())
        refreshPromptState()
        if model.latestAvailableTripID() != nil {
            showLatestPostcard()
        } else {
            showCurrentJourney()
        }
    }

    static func menuTitle(phase: TravelPhase, currentPlace: String?) -> String {
        switch phase {
        case .resting:
            "Travel Cat · 在家休息"
        case .preparing:
            "Travel Cat · 准备出发"
        case .transit:
            "Travel Cat · 旅途中"
        case .exploring, .postcardReady:
            if let currentPlace, !currentPlace.isEmpty {
                "Travel Cat · \(currentPlace)"
            } else {
                "Travel Cat · 旅途中"
            }
        case .returning:
            "Travel Cat · 回家途中"
        }
    }

    private func show(model: AppModel, size: NSSize) {
        utilityWindowController.show(
            content: AnyView(MenuServiceRootView(
                model: model,
                closeWindow: { [weak self] in self?.utilityWindowController.window?.close() },
                presentationChanged: { [weak self] presentation in
                    self?.resizeUtilityWindow(for: presentation)
                }
            )),
            size: size
        )
    }

    private func currentAlbumPreviewSession() -> TravelAlbumPreviewSession? {
        if let session = albumPreviewSession {
            return session
        }
        do {
            let resourceURLs = try albumPreviewAssetURLs()
            let catResourceURLs = try albumPreviewCatAssetURLs()
            albumPreviewSession = try TravelAlbumPreviewFactory.make(
                temporaryDirectory: FileManager.default.temporaryDirectory,
                resourceURLs: resourceURLs,
                catResourceURLs: catResourceURLs
            )
            return albumPreviewSession
        } catch {
            environment?.errorMessage = "预览创建失败：\(error.localizedDescription)"
            return nil
        }
    }

    private func albumPreviewAssetURLs() throws -> [URL] {
        let resourceBundle = Bundle.main.resourceURL
            .flatMap { Bundle(url: $0.appendingPathComponent("TravelCat_TravelUI.bundle")) } ?? Bundle.main
        return try TravelAlbumPreviewCatalog.definitions.map { definition in
            guard let result = TravelAlbumPreviewCatalog.resourceURL(
                for: definition,
                in: resourceBundle
            ) else {
                throw TravelAlbumPreviewError.invalidAsset(definition.filename)
            }
            return result
        }
    }

    private func albumPreviewCatAssetURLs() throws -> [URL] {
        let resourceBundle = Bundle.main.resourceURL
            .flatMap { Bundle(url: $0.appendingPathComponent("TravelCat_TravelUI.bundle")) } ?? Bundle.main
        return try PreviewBlackCatPose.allCases.map { pose in
            guard let result = TravelAlbumPreviewCatalog.catResourceURL(
                for: pose,
                in: resourceBundle
            ) else {
                throw TravelAlbumPreviewError.invalidAsset(pose.assetFilename)
            }
            return result
        }
    }

    private func closeAlbumPreviewSession() {
        albumPreviewWindowController.setCloseHandler(nil)
        albumPreviewWindowController.window?.close()
        albumPreviewWindowController.window?.contentView = nil
        albumPreviewSession?.cleanUp()
        albumPreviewSession = nil
    }

    private func resizeUtilityWindow(for presentation: PetPresentation) {
        let size: NSSize
        switch presentation {
        case .postcard:
            size = TravelUtilityWindowController.postcardSize
        case .album:
            size = TravelUtilityWindowController.albumSize
        case .pet, .awayTag, .status, .supplies:
            size = TravelUtilityWindowController.statusSize
        }
        utilityWindowController.window?.setContentSize(size)
    }

    private func refreshMenuState() {
        guard let model else { return }
        let snapshot = model.snapshot
        let currentPlace = model.events.first(where: { $0.id == snapshot.lastEventID })?.location?.place
            ?? snapshot.visitedPlaces.last
        statusTitle = Self.menuTitle(phase: snapshot.phase, currentPlace: currentPlace)
        hasLatestPostcard = model.latestAvailableTripID() != nil
        hasLatestAlbum = model.latestAvailableTripID() != nil
    }

    private func refreshPromptState() {
        petPromptPending = environment?.petPromptService.hasPendingOrStorageError ?? false
    }

    private func showStartupError(_ message: String) {
        startupError = message
        statusTitle = "Travel Cat · 需要处理"
        hasLatestPostcard = false
        hasLatestAlbum = false
        petPromptPending = false
        if let data = "TravelCat startup error: \(message)\n".data(using: .utf8) {
            try? FileHandle.standardError.write(contentsOf: data)
        }
    }
}

enum MenuServiceRouteContext: CaseIterable, Equatable {
    case status
    case postcard
    case album
}

enum MenuServiceRouteAction: Equatable {
    case closeWindow
    case modelClose
    case handle(PetPresentation)
    case openStatus
}

enum MenuServiceRoutePolicy {
    static func normalized(_ presentation: PetPresentation) -> MenuServiceRouteContext {
        switch presentation {
        case .status:
            .status
        case .postcard:
            .postcard
        case .album:
            .album
        case .pet, .awayTag, .supplies:
            .status
        }
    }

    static func action(
        from context: MenuServiceRouteContext,
        to destination: PetPresentation
    ) -> MenuServiceRouteAction {
        switch (context, destination) {
        case (.status, .status):
            .closeWindow
        case (.status, .postcard), (.postcard, .album), (.album, .postcard):
            .handle(destination)
        case (.postcard, .status):
            .modelClose
        default:
            .openStatus
        }
    }
}

@MainActor
struct MenuServiceRootView: View {
    @ObservedObject var model: AppModel
    let closeWindow: () -> Void
    let presentationChanged: (PetPresentation) -> Void

    var body: some View {
        content
            .onAppear {
                normalizePresentationIfNeeded()
                presentationChanged(model.presentation)
            }
            .onChange(of: model.presentation) { _, next in
                presentationChanged(next)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.presentation {
        case .status:
            statusView
        case let .postcard(id):
            if let event = model.events.first(where: { $0.id == id }) {
                PostcardView(event: event, rootURL: model.dataRoot) { destination in
                    handlePostcardRoute(destination)
                }
            } else {
                statusView
            }
        case let .album(tripID):
            TripAlbumView(tripID: tripID, events: model.events, rootURL: model.dataRoot) { destination in
                handleAlbumRoute(destination)
            }
        case .pet, .awayTag, .supplies:
            statusView
        }
    }

    private var statusView: some View {
        CurrentPetStatusView(
            model: model,
            close: { perform(.closeWindow) },
            openPostcard: { id in
                perform(MenuServiceRoutePolicy.action(from: .status, to: .postcard(id)))
            },
            openAlbum: { model.openLatestAlbumFromStatus() }
        )
    }

    private func handlePostcardRoute(_ destination: PetPresentation) {
        perform(MenuServiceRoutePolicy.action(from: .postcard, to: destination))
    }

    private func handleAlbumRoute(_ destination: PetPresentation) {
        perform(MenuServiceRoutePolicy.action(from: .album, to: destination))
    }

    private func perform(_ action: MenuServiceRouteAction) {
        switch action {
        case .closeWindow:
            closeWindow()
        case .modelClose:
            model.close()
        case let .handle(destination):
            model.handle(destination)
        case .openStatus:
            model.openStatusFromMenu()
        }
    }

    private func normalizePresentationIfNeeded() {
        if MenuServiceRoutePolicy.normalized(model.presentation) == .status,
           model.presentation != .status {
            model.openStatusFromMenu()
        }
    }
}

@main
struct TravelCatApp: App {
    @NSApplicationDelegateAdaptor(TravelCatAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            TravelCatMenuContentView(appDelegate: appDelegate)
        } label: {
            TravelCatMenuLabelView(appDelegate: appDelegate)
        }
        Settings {
            TravelCatSettingsSceneView(appDelegate: appDelegate)
        }
    }
}

private struct TravelCatMenuContentView: View {
    @ObservedObject var appDelegate: TravelCatAppDelegate

    var body: some View {
        Button("当前状态") { appDelegate.showCurrentJourney() }
        Button("最新明信片") { appDelegate.showLatestPostcard() }
            .disabled(!appDelegate.hasLatestPostcard)
        Button("旅行册") { appDelegate.showLatestAlbum() }
            .disabled(!appDelegate.hasLatestAlbum)
        Divider()
        Button("设置…") { appDelegate.showSettings() }
        if let controller = appDelegate.desktopPetController {
            DesktopPetVisibilityButton(controller: controller, toggle: appDelegate.toggleDesktopPet)
        }
        Divider()
        Button("退出 Travel Cat") { NSApplication.shared.terminate(nil) }
    }
}

private struct DesktopPetVisibilityButton: View {
    @ObservedObject var controller: DesktopPetController
    let toggle: () -> Void

    var body: some View {
        Button(controller.isHidden ? "显示桌面小猫" : "隐藏桌面小猫", action: toggle)
    }
}

private struct TravelCatMenuLabelView: View {
    @ObservedObject var appDelegate: TravelCatAppDelegate

    var body: some View {
        Label(
            appDelegate.statusTitle,
            systemImage: appDelegate.petPromptPending ? "pawprint.circle.fill" : "pawprint.fill"
        )
    }
}

// Observe startup publication in the hosted view, not only at the Scene boundary.
private struct TravelCatSettingsSceneView: View {
    @ObservedObject var appDelegate: TravelCatAppDelegate

    var body: some View {
        Group {
            if let environment = appDelegate.environment {
                TravelCatSettingsView(
                    environment: environment,
                    requestAlbumPreview: { appDelegate.showAlbumPreview() },
                    requestFullJourney: { appDelegate.startFullJourneyTest() },
                    requestRealJourney: { appDelegate.startRealJourneyTest() },
                    requestTestAlbum: { appDelegate.showTestJourneyAlbum() }
                )
            } else {
                Text(appDelegate.startupError ?? "Travel Cat 正在启动…")
                    .padding(24)
            }
        }
        .frame(minWidth: TravelUtilityWindowController.settingsSize.width, minHeight: TravelUtilityWindowController.settingsSize.height)
    }
}
