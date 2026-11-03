import AppKit
import Combine
import SwiftUI
import TravelCore
import TravelStorage
import TravelUI

@MainActor
final class TravelCatAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private var model: AppModel?
    private lazy var utilityWindowController = TravelUtilityWindowController()
    private lazy var generationWindowController = TravelUtilityWindowController()
    private var generationSetupSession = GenerationSetupPresentationSession()
    private let serviceCredentials = KeychainTravelServiceCredentialStore()
    private var generationServices: GenerationServiceController?
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
    private var homeLocationTask: Task<Void, Never>?
    private var agentX: AgentXController?
    private var agentXWindow: AgentXWindowController?
    private var workbenchSubscription: AnyCancellable?
    private var agentWorkbench: AgentWorkbenchModel?
    private var agentXHostStorage: AgentXHostStorage?
    private lazy var agentWindowController = TravelUtilityWindowController()
    private var mailboxCoordinator: DesktopMailboxCoordinator?
    private var codexDiagnosticStore: CodexGenerationDiagnosticStore?
    private lazy var codexExecutor = CodexTravelExecutor(diagnostics: { [codexDiagnosticStore] data in
        try? codexDiagnosticStore?.record(data)
    })
    private var automaticTravelController: AutomaticTravelController?
    private var postcardRecoveryController: PostcardRecoveryController?
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
        let developmentRoot = isDevelopmentRoot && Bundle.main.bundleURL.pathExtension != "app" ? currentDirectory : nil
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
        // AgentX remains usable even when the optional travel application fails to load.
        let hostEnvironment: AgentXHostEnvironment
        do { hostEnvironment = try AgentXHostEnvironment(environment: ProcessInfo.processInfo.environment, applicationSupport: applicationSupport) }
        catch { showStartupError(error.localizedDescription); return }
        let fallbackRoot = hostEnvironment.fallbackRoot
        let hostDirectory = hostEnvironment.hostDirectory
        let agentXRoot: URL
        var migrationNotice: String?
        do {
            let resolved = try AgentXRootCoordinator(locator: hostDirectory.appendingPathComponent("location.json")).resolve(fallback: fallbackRoot)
            let storage = AgentXHostStorage(root: resolved, hostDirectory: hostDirectory)
            do {
                let hadPendingMigration = storage.hasPendingMigration
                agentXRoot = try storage.applyPendingMigration(writersHaveStopped: storage.previousHostHasExited,
                    inspectLegacyWorkbench: { _ = try AgentXLegacyWorkbenchView.readSnapshot(root: $0) },
                    migrateCredentials: { try AgentXNativeCredentialMigration.system.migrate(from: $0, to: $1) })
                if hadPendingMigration { migrationNotice = "离线数据导入或根目录迁移已完成，原目录保留。" }
            } catch {
                agentXRoot = resolved
                migrationNotice = error.localizedDescription
                // This process will resume writes, invalidating any previous exit receipt.
                try storage.revokeExitReceipt()
            }
        } catch { showStartupError(error.localizedDescription); return }
        let hostStorage = AgentXHostStorage(root: agentXRoot, hostDirectory: hostDirectory)
        agentXHostStorage = hostStorage
        do {
            if hostStorage.offlineLifecycle.hasPendingOperation {
                guard !hostStorage.hasPendingMigration else { throw AgentXHostStorage.Failure.invalidRequest }
                let result = try hostStorage.offlineLifecycle.applyPending(writersHaveStopped: hostStorage.nativeDaemonsHaveExited)
                migrationNotice = result?.message ?? migrationNotice
            }
        } catch { migrationNotice = error.localizedDescription }
        do { try hostStorage.offlineLifecycle.revokeExitReceipt() }
        catch { showStartupError(error.localizedDescription); return }

        codexDiagnosticStore = CodexGenerationDiagnosticStore(fileURL: hostStorage.blackCatRoot.appendingPathComponent("diagnostics/codex-latest.json"))
        let hasAgentXState = FileManager.default.fileExists(atPath: agentXRoot.appendingPathComponent("agentx.yaml").path)
        let manager = AgentXController(repository: AgentXRepository(root: agentXRoot),
            credentials: KeychainTravelServiceCredentialStore(service: "com.nebulae.agentx.model-services"), hostStorage: hostStorage)
        if manager.isLoaded && !hasAgentXState {
            do { try manager.setBlackCatEnabled(!UserDefaults.standard.bool(forKey: "TravelCat.desktopPet.hidden")) }
            catch { manager.errorMessage = error.localizedDescription }
        }
        let providerResolver = AgentXProviderResolver(state: {
            guard manager.isLoaded else { throw AgentXError.unavailable }
            return manager.state
        }, credentials: KeychainTravelServiceCredentialStore(service: "com.nebulae.agentx.model-services"))
        agentX = manager
        manager.errorMessage = migrationNotice ?? manager.errorMessage
        manager.didChange = { [weak self] in self?.refreshAgentXEntry() }
        NSApp.setActivationPolicy(.regular)
        refreshAgentXEntry()
        if !manager.state.blackCatEnabled || !manager.isLoaded || manager.singleMode { showAgentXManager() }
        guard manager.isLoaded else { return }
        do {
            try manager.ensureWorkbenchApp()
            try hostStorage.prepareAppData(at: hostStorage.workbenchRoot,
                legacy: hostEnvironment.importsLegacyData ? applicationSupport.appendingPathComponent("TravelCatAgents", isDirectory: true) : nil)
            if !hostStorage.workbenchNeedsRebinding {
                agentWorkbench = AgentWorkbenchModel(root: hostStorage.workbenchRoot, managedRoot: hostStorage.root, providerResolver: providerResolver)
                workbenchSubscription = agentWorkbench?.objectWillChange.sink { [weak self] _ in
                    Task { @MainActor in self?.refreshAgentXEntry() }
                }
                agentWorkbench?.retryStorage()
            } else {
                manager.errorMessage = "旧工作台已复制校验并保留源目录。历史可在工作台只读查看；旧绝对 workspace 未获新授权，运行保持禁用。"
            }
        } catch { manager.errorMessage = error.localizedDescription; showAgentXManager() }
        do {
            let legacyRoot: URL?
            if hostEnvironment.importsLegacyData {
                let hasOverride = !(ProcessInfo.processInfo.environment["TRAVEL_CAT_DATA"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                let installedRoot = hasOverride || bundledDataRoot != nil || developmentRoot != nil ? nil
                    : try InstalledDataRootPreference.load(applicationSupportDirectory: applicationSupport)
                legacyRoot = AppDataRootResolver().resolve(
                    environment: ProcessInfo.processInfo.environment,
                    bundledDataRoot: bundledDataRoot ?? installedRoot,
                    developmentProjectRoot: developmentRoot,
                    applicationSupportDirectory: applicationSupport
                )
            } else { legacyRoot = nil }
            try hostStorage.prepareAppData(at: hostStorage.blackCatRoot, legacy: legacyRoot)
            let rootURL = hostStorage.blackCatRoot
            let repository = try TravelRepository(root: rootURL)
            let loaded = try repository.loadContents()
            let settings = try TravelSettingsStore(root: rootURL).load()
            let homeCareResult = Result { try repository.loadHomeCare() }
            let model = AppModel(
                snapshot: loaded.snapshot,
                events: loaded.events,
                presentationReferences: loaded.presentationReferences,
                dataRoot: rootURL,
                characterProfile: loaded.characterProfile,
                persistSupply: repository.updateCarriedItem,
                homeCare: (try? homeCareResult.get()) ?? HomeCareState(),
                homeCareErrorMessage: { if case .failure = homeCareResult { return "陪伴记录暂时无法读取，请稍后重试。" }; return nil }(),
                persistHomeCare: { try repository.performHomeCare($0, now: $1) }
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
                settingsChanged: { [weak self] in self?.automaticTravelController?.settingsDidChange() },
                promptStateChanged: { [weak self] in self?.refreshPromptState() }
            )
            self.model = model
            self.environment = environment
            homeLocationTask = Task { [weak environment] in
                guard let environment else { return }
                await environment.homeLocation.refresh()
            }
            environment.notificationService.promptRouteHandler = { [weak self] route in
                self?.performPromptRoute(route)
            }
            refreshMenuState()
            installDesktopPet(model: model)
            let services = try GenerationServiceController(
                store: TravelGenerationConfigurationStore(root: rootURL), credentials: serviceCredentials,
                hasExistingHistory: !loaded.events.isEmpty, providerResolver: providerResolver,
                didSave: { [weak self] in
                    self?.automaticTravelController?.settingsDidChange()
                    self?.postcardRecoveryController?.refresh()
                })
            generationServices = services
            environment.generationServices = services
            environment.openGenerationSetup = { [weak self] in self?.showGenerationSetup() }
            let generator = ConfiguredTravelContentGenerator(configuration: { services.configuration },
                credentials: serviceCredentials, codex: CodexTravelContentGenerator(executor: codexExecutor, diagnostics: { [codexDiagnosticStore] data in try? codexDiagnosticStore?.record(data) }), providerResolver: providerResolver)
            let worker = AutomaticTravelWorker(repository: repository, generator: generator,
                didChange: { [weak self] in
                    self?.postcardRecoveryController?.refresh()
                    self?.automaticTravelController?.refreshSuccessfulPublicationDate()
                })
            let recovery = PostcardRecoveryController(repository: repository, model: model, worker: worker,
                settings: { [weak environment] in environment?.effectiveSettings ?? TravelSettings() },
                isReady: { [weak services] in services?.isReady ?? false },
                applyContents: { [weak environment] contents, supplemental, references in
                    guard let environment else { return }
                    environment.applyRepositoryContents(RepositoryContents(
                        snapshot: contents.snapshot, events: contents.events + supplemental,
                        characterProfile: contents.characterProfile,
                        selectedCharacterProfile: contents.selectedCharacterProfile,
                        presentationReferences: contents.presentationReferences.merging(references) { _, extra in extra }))
                },
                didRefresh: { [weak self] in self?.refreshMenuState() })
            postcardRecoveryController = recovery
            recovery.start()
            environment.postcardBacklogRecovered = { [weak recovery] in recovery?.refresh() }
            let automaticTravel = AutomaticTravelController(
                isEnabled: { [weak environment, weak services] in
                    (environment?.effectiveSettings.automaticTravelEnabled ?? false) && (services?.isReady ?? false)
                        && environment?.selectedCharacterProfile == .defaultBlackCat
                        && environment?.effectiveCharacterProfile == .defaultBlackCat
                },
                runWithProgress: { [weak environment] progress in
                    guard let environment else { throw CancellationError() }
                    return try await worker.step(settings: environment.effectiveSettings, progress: progress)
                }, retryWithProgress: { [weak environment] progress in
                    guard let environment else { throw CancellationError() }
                    return try await worker.step(settings: environment.effectiveSettings, retryFailure: true, progress: progress)
                }, lastSuccessDate: worker.lastSuccessfulPublicationDate(),
                readLastSuccessDate: { worker.lastSuccessfulPublicationDate() })
            automaticTravelController = automaticTravel
            environment.automaticTravel = automaticTravel
            automaticTravel.start()
            if !services.isReady && manager.state.blackCatEnabled { showGenerationSetup() }
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
            manager.errorMessage = error.localizedDescription
            showAgentXManager()
        }
    }

    var desktopPetAnchor: PetCompanionAnchor? {
        DesktopPetAnchorProvider.current(controller: desktopPetController)
    }

    func installDesktopPet(model: AppModel, defaults: UserDefaults = .standard) {
        mailboxCoordinator?.shutdown()
        mailboxCoordinator = nil
        desktopPetController?.windowController.close()
        let scene = OwnedPetSceneView(
            model: model,
            showStatus: { [weak self] in self?.showCurrentJourney() },
            showHouse: { [weak self] in self?.showAgentXManager() },
            showPostcard: { [weak self] in self?.showLatestPostcard() },
            showAlbum: { [weak self] in self?.showLatestAlbum() },
            showSettings: { [weak self] in self?.showSettings() },
            showSupplies: { [weak self] in self?.showSupplies() },
            hide: { [weak self] in self?.setBlackCatEnabled(false) }
        )
        let controller = DesktopPetController(content: AnyView(scene), defaults: defaults)
        desktopPetController = controller
        controller.restoreVisibility()
        refreshAgentXEntry()
        // Postcards and the mailbox remain available when imported workbench history is read-only.
        mailboxCoordinator = DesktopMailboxCoordinator(desktop: controller, pet: model, agents: agentWorkbench,
            openPostcard: { [weak self] id in self?.showMailboxPostcard(id) },
            openAlbum: { [weak self] in self?.showLatestAlbum() },
            openAgents: { [weak self] in self?.showAgentWorkbench() })
    }

    func toggleDesktopPet() {
        guard let controller = desktopPetController else { return }
        setBlackCatEnabled(controller.isHidden)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationTask == nil {
            terminationTask = Task {
                let migrationRequested = agentXHostStorage?.hasPendingMigration == true
                let lifecycleRequested = agentXHostStorage?.offlineLifecycle.hasPendingOperation == true
                let offlineRequested = migrationRequested || lifecycleRequested
                // Capture lifecycle evidence before shutdown invalidates the live observations.
                let workbenchBlock = agentWorkbench.flatMap { workbench -> String? in
                    guard workbench.isStorageReady else { return "工作台安全存储尚未就绪" }
                    guard workbench.canManageRetention, workbench.nativeBusy.isEmpty,
                          !workbench.discovering, !workbench.probingLocal, !workbench.scanningLocal,
                          workbench.retainedProbe == nil else { return "工作台仍有启动、探测或未清理运行操作" }
                    for task in workbench.state.tasks {
                        if let reason = workbench.archiveBlockReason(task.id) { return "\(task.displayTitle)：\(reason)" }
                    }
                    return nil
                }
                agentX?.cancelAll()
                automaticTravelController?.stop()
                postcardRecoveryController?.stop()
                var nativeStopped = !offlineRequested
                if offlineRequested {
                    if let client = agentWorkbench?.client as? AgentSidecarClient {
                        do {
                            let result = try await client.request("native_quiesce", [:], timeout: 90)
                            nativeStopped = result["stopped"] as? Bool == true
                        } catch { nativeStopped = agentXHostStorage?.nativeDaemonsHaveExited() == true }
                    } else { nativeStopped = agentXHostStorage?.nativeDaemonsHaveExited() == true }
                }
                agentWorkbench?.shutdown()
                if let controller = environment?.journeyTestController { await controller.shutdown() }
                let codexStopped = await codexExecutor.shutdownAndWait(timeout: .seconds(10))
                let sidecarStopped: Bool
                if let client = agentWorkbench?.client as? AgentSidecarClient {
                    sidecarStopped = await client.waitForExit(timeout: .seconds(10))
                } else { sidecarStopped = agentWorkbench == nil }
                if offlineRequested {
                    if workbenchBlock == nil && codexStopped && sidecarStopped && nativeStopped && agentXHostStorage?.nativeDaemonsHaveExited() == true {
                        do {
                            guard !(migrationRequested && lifecycleRequested) else { throw AgentXHostStorage.Failure.invalidRequest }
                            try agentXHostStorage?.recordCleanChildExit()
                            try agentXHostStorage?.offlineLifecycle.recordCleanChildExit()
                        }
                        catch { showMigrationExitNotice(error.localizedDescription) }
                    } else {
                        showMigrationExitNotice(workbenchBlock ?? "旧执行器尚未确认完全退出")
                    }
                }
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    private func showMigrationExitNotice(_ reason: String) {
        let alert = NSAlert()
        alert.messageText = "此次退出未批准根目录迁移"
        alert.informativeText = reason + "。请求和原数据保留。重新打开后请进入 Agent 工作台处理会话，再正常退出重试；也可在设置中取消请求。"
        alert.addButton(withTitle: "继续退出")
        alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        agentX?.cancelAll()
        NSApp.dockTile.badgeLabel = nil
        mailboxCoordinator?.shutdown()
        mailboxCoordinator = nil
        workbenchSubscription = nil
        agentWorkbench?.shutdown()
        desktopPetController?.windowController.close()
        desktopPetController = nil
        environment?.statusToastController.dismiss()
        watcherTask?.cancel()
        authorizationTask?.cancel()
        automaticTravelController?.stop()
        homeLocationTask?.cancel()
        postcardRecoveryController?.stop()
        codexExecutor.cancelAll()
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
                    if let postcardRecoveryController { postcardRecoveryController.refresh() }
                    else { environment.applyRepositoryContents(contents) }
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
                refreshAgentXEntry()
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

    private func managedWorkbenchContent() -> AnyView {
        if let storage = agentXHostStorage, storage.workbenchNeedsRebinding {
            return AnyView(AgentXLegacyWorkbenchView(root: storage.workbenchRoot))
        }
        if let agentWorkbench { return AnyView(AgentWorkbenchView(model: agentWorkbench)) }
        return AnyView(VStack(alignment: .leading, spacing: 12) {
            Text("工作台尚未就绪").font(.title2)
            Text(agentX?.errorMessage ?? "请完成已登记的离线导入后重新启动。历史和原目录保持不变。")
                .textSelection(.enabled)
        }.padding())
    }

    func showAgentWorkbench() {
        if let storage = agentXHostStorage, storage.workbenchNeedsRebinding {
            agentWindowController.show(content: AnyView(AgentXLegacyWorkbenchView(root: storage.workbenchRoot)),
                size: NSSize(width: 1000, height: 740), minimumContentSize: NSSize(width: 760, height: 600))
            agentWindowController.window?.title = "工作台 · 只读历史与待重绑配置"
            return
        }
        guard let agentWorkbench else { showAgentXManager(); return }
        agentWindowController.show(content: AnyView(AgentWorkbenchView(model: agentWorkbench)),
            size: NSSize(width: 1000, height: 740), minimumContentSize: NSSize(width: 760, height: 600))
        agentWindowController.window?.title = "Agent 工作台"
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

    func showMailboxPostcard(_ id: UUID) {
        guard let model, model.openPostcardFromMailbox(eventID: id) else { return }
        show(model: model, size: TravelUtilityWindowController.postcardSize)
    }

    func showLatestPostcard() {
        guard let model, hasLatestPostcard else { return }
        model.openLatestPostcardFromMenu()
        show(model: model, size: TravelUtilityWindowController.postcardSize)
    }

    func showHouseArrival() {
        guard startupError == nil, let model else { showCurrentJourney(); return }
        model.openHouseFromDesktop()
        let size = model.presentation == .status
            ? TravelUtilityWindowController.statusSize : TravelUtilityWindowController.postcardSize
        show(model: model, size: size)
    }

    func showLatestAlbum() {
        guard let model, hasLatestAlbum else { return }
        model.openLatestAlbumFromMenu()
        show(model: model, size: TravelUtilityWindowController.albumSize)
    }

    func showGenerationSetup() {
        guard let services = generationServices else { return }
        generationWindowController.setCloseHandler { [weak self] in
            self?.generationSetupSession.windowDidClose()
        }
        generationWindowController.show(
            content: generationSetupSession.content(
                GenerationSetupView(controller: services, credentials: serviceCredentials,
                    executor: codexExecutor, completed: { [weak self] in
                        self?.generationWindowController.window?.close()
                    })),
            size: NSSize(width: 640, height: 760), minimumContentSize: NSSize(width: 600, height: 630))
        generationWindowController.window?.title = "Travel Cat · 模型与连接"
        generationWindowController.bringToFront()
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
            guard let hostStorage = agentXHostStorage else { return nil }
            let parent = hostStorage.root.appendingPathComponent("apps/blackcat/journey-tests", isDirectory: true)
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
                handwritingPreparer: PostcardHandwritingGenerator(model: generator),
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
        utilityWindowController.setCloseHandler { [weak model] in
            model?.close()
        }
        utilityWindowController.show(
            content: AnyView(MenuServiceRootView(
                model: model,
                closeWindow: { [weak self] in self?.utilityWindowController.window?.close() },
                presentationChanged: { [weak self] presentation in
                    self?.resizeUtilityWindow(for: presentation)
                },
                automaticTravel: automaticTravelController
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
        utilityWindowController.resize(to: size)
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
        refreshAgentXEntry()
    }

    func showPet() { setBlackCatEnabled(true) }

    private func setBlackCatEnabled(_ enabled: Bool) {
        guard let agentX else {
            if enabled { desktopPetController?.show() } else { desktopPetController?.hide() }
            return
        }
        do { try agentX.setBlackCatEnabled(enabled) }
        catch { agentX.errorMessage = error.localizedDescription; showAgentXManager() }
    }

    private func refreshAgentXEntry() {
        guard let agentX else { return }
        if let pet = desktopPetController {
            if agentX.state.blackCatEnabled && pet.isHidden { pet.show() }
            else if !agentX.state.blackCatEnabled && !pet.isHidden { pet.hide() }
        }
        let count = agentX.state.unreadCount + (petPromptPending ? 1 : 0) + (agentWorkbench?.attentionCount ?? 0)
        NSApp.dockTile.badgeLabel = count == 0 ? nil : String(count)
        agentXWindow?.updateTravelPending(petPromptPending)
        agentXWindow?.updateWorkbenchPending(agentWorkbench?.attentionCount ?? 0)
        agentXWindow?.updateWorkbenchContent { [weak self] in self?.managedWorkbenchContent() ?? AnyView(EmptyView()) }
    }

    func showAgentXManager() {
        guard let agentX else { return }
        if agentXWindow == nil {
            agentXWindow = AgentXWindowController(controller: agentX,
                openJourney: { [weak self] in self?.showCurrentJourney() },
                openAlbum: { [weak self] in self?.showLatestAlbum() }, travelPending: petPromptPending,
                openTravelPrompt: { [weak self] in self?.openTravelPromptFromManager() },
                workbenchPending: agentWorkbench?.attentionCount ?? 0,
                openWorkbench: { [weak self] in self?.showAgentWorkbench() },
                workbenchContent: { [weak self] in self?.managedWorkbenchContent() ?? AnyView(EmptyView()) })
        }
        agentXWindow?.present()
    }

    private func openTravelPromptFromManager() {
        guard let environment else { showCurrentJourney(); return }
        if !environment.petPromptService.openPendingFromInbox() {
            if environment.petPromptService.storageError != nil {
                agentX?.errorMessage = "旅行提醒存储异常，未确认或清除记录。请检查旅行数据后重试。"
            } else { showCurrentJourney() }
        }
        refreshPromptState()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        agentX?.openFromDock(travelPending: petPromptPending || (agentWorkbench?.attentionCount ?? 0) > 0)
        showAgentXManager()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func showSupplies() {
        guard let model else { return }
        utilityWindowController.show(content: AnyView(StandaloneSuppliesView(model: model, close: { [weak self] in self?.utilityWindowController.window?.close() })),
            size: TravelUtilityWindowController.statusSize)
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
    var automaticTravel: AutomaticTravelController? = nil

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
                PostcardView(event: event, rootURL: model.dataRoot, presentationReference: model.presentationReferences[event.id],
                    workItem: model.postcardWorkItems.first { $0.eventID == event.id },
                    travelDate: TripAlbumChronology.dates(events: model.events, workItems: model.postcardWorkItems)[event.id],
                    retry: model.retryPostcard, error: model.postcardWorkError, notice: model.manualRetryMessage,
                    isFavourite: model.favouritePostcardIDs.contains(event.id), toggleFavourite: { model.toggleFavourite(event.id) },
                    isUnread: model.unreadPostcardIDs.contains(event.id), recipient: model.postcardRecipient,
                    onSceneryDisplayed: { model.postcardFrontDidDisplay(event.id, relativePath: $0) }, recipientModel: model) { destination in
                    handlePostcardRoute(destination)
                }
            } else {
                statusView
            }
        case .album:
            TripAlbumView(tripID: nil, events: model.events, rootURL: model.dataRoot, presentationReferences: model.presentationReferences,
                workItems: model.postcardWorkItems, retry: model.retryPostcard,
                error: model.postcardWorkError, notice: model.manualRetryMessage,
                unreadIDs: Set(model.unreadPostcardIDs), favouriteIDs: model.favouritePostcardIDs, recipient: model.postcardRecipient) { destination in
                handleAlbumRoute(destination)
            }
        case .pet, .awayTag, .supplies:
            statusView
        }
    }

    private var statusView: some View {
        VStack(spacing: 4) {
            if let automaticTravel { AutomaticTravelStatusView(controller: automaticTravel) }
        CurrentPetStatusView(
            model: model,
            close: { perform(.closeWindow) },
            openPostcard: { id in
                perform(MenuServiceRoutePolicy.action(from: .status, to: .postcard(id)))
            },
            openAlbum: { model.openLatestAlbumFromStatus() }
        )
        }
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
        .commands {
            CommandMenu("Agent") {
                Button("AgentX 管理平台…") { appDelegate.showAgentXManager() }
                Button("Agent 工作台…") { appDelegate.showAgentWorkbench() }
                    .keyboardShortcut("a", modifiers: [.command, .option])
            }
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
        Button("AgentX 管理平台…") { appDelegate.showAgentXManager() }
        Button("Agent 工作台…") { appDelegate.showAgentWorkbench() }
        Button("模型与连接…") { appDelegate.showGenerationSetup() }
        Button("用品与陪伴…") { appDelegate.showSupplies() }
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

@MainActor
private struct OwnedPetSceneView: View {
    @ObservedObject var model: AppModel
    @Environment(\.petPlaybackEnabled) private var playbackEnabled
    let showStatus: () -> Void
    let showHouse: () -> Void
    let showPostcard: () -> Void
    let showAlbum: () -> Void
    let showSettings: () -> Void
    let showSupplies: () -> Void
    let hide: () -> Void

    var body: some View {
        Group {
            if model.characterProfile == .defaultBlackCat {
                PetHouseView(phase: model.snapshot.phase, hasUnreadPostcard: false,
                             isActive: playbackEnabled, reaction: model.homeCareReaction)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: showHouse)
                    .contextMenu {
                        Button("AgentX 管理平台", action: showHouse)
                        Button("当前状态", action: showStatus)
                        Button("最新明信片", action: showPostcard).disabled(model.latestAvailableTripID() == nil)
                        Button("旅行册", action: showAlbum).disabled(model.latestAvailableTripID() == nil)
                        Button("用品与陪伴…", action: showSupplies)
                        Button("设置…", action: showSettings)
                        Divider()
                        Button("隐藏桌面小猫", action: hide)
                    }
            } else {
                DesktopPetSceneView(model: model, showStatus: showStatus, showPostcard: showPostcard,
                                    showAlbum: showAlbum, showSettings: showSettings, hide: hide)
            }
        }
    }
}

@MainActor
private struct StandaloneSuppliesView: View {
    @ObservedObject var model: AppModel
    var close: () -> Void
    var body: some View {
        SupplyDrawerView(supplies: model.supplies, selectedID: model.snapshot.carriedItemID,
            isCatAway: !(model.snapshot.phase == .resting || model.snapshot.phase == .preparing),
            errorText: model.supplyErrorMessage,
            homeCare: model.homeCare, homeCareErrorText: model.homeCareErrorMessage,
            care: model.performHomeCare, select: { try? model.selectSupply($0) }, close: close)
    }
}
