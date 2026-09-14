import AppKit
import ServiceManagement
import SwiftUI
import TravelCore
import TravelStorage
import TravelUI

enum TravelSettingsSaveOutcome: Equatable {
    case applied
    case rollback(TravelSettings, message: String)
    case ignoredRollback
}

enum CharacterSelectionOutcome: Equatable {
    case applied(CharacterConfigurationResponse)
    case failed(message: String)
}

@MainActor
struct CharacterSettingsDisplayState {
    let model: AppModel
    var effectiveProfile: CharacterProfile { model.characterProfile }
}

enum CodexPetsDirectoryResolver {
    static func preferred(environment: [String: String], home: URL) -> URL {
        let configured = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let root = configured.hasPrefix("/")
            ? URL(fileURLWithPath: configured, isDirectory: true)
            : home.appendingPathComponent(".codex", isDirectory: true)
        return root.appendingPathComponent("pets", isDirectory: true).standardizedFileURL
    }
}

enum CharacterSelectionErrorMessage {
    static func message(for error: Error) -> String {
        let guidance: String
        switch error as? CharacterProfileStoreError {
        case .unsafePath:
            guidance = "所选文件夹包含不安全的路径或链接，请选择普通本地文件夹。"
        case .invalidManifest:
            guidance = "角色清单 pet.json 格式无效，请选择包含有效清单的宠物文件夹。"
        case .unsupportedSprite:
            guidance = "角色图片格式或透明通道不受支持，请检查 spritesheet。"
        case .invalidAsset:
            guidance = "角色图片缺失、损坏或过大，请检查清单中引用的文件。"
        case .corruptSelection:
            guidance = "现有角色选择已损坏，请恢复内置黑猫或重新导入。"
        case .revisionConflict:
            guidance = "同名角色版本发生冲突，请检查宠物文件夹内容后重试。"
        case nil:
            guidance = "角色设置暂时无法保存，请检查数据目录权限后重试。"
        }
        return guidance + "已保留当前选择。"
    }
}

@MainActor
final class CharacterSelectionLifecycle {
    private(set) var configuration: CharacterConfigurationResponse

    init(initial: CharacterConfigurationResponse) {
        configuration = initial
    }

    func update(_ operation: () throws -> CharacterConfigurationResponse) -> CharacterSelectionOutcome {
        do {
            let next = try operation()
            configuration = next
            return .applied(next)
        } catch {
            return .failed(message: CharacterSelectionErrorMessage.message(for: error))
        }
    }
}

@MainActor
final class TravelSettingsLifecycle {
    private let persist: (TravelSettings) throws -> Void
    private let apply: (TravelSettings) -> Void
    private(set) var lastPersistedSettings: TravelSettings
    private var isRestoringSettings = false

    var effectiveSettings: TravelSettings { lastPersistedSettings }

    init(
        initialSettings: TravelSettings,
        persist: @escaping (TravelSettings) throws -> Void,
        apply: @escaping (TravelSettings) -> Void
    ) {
        lastPersistedSettings = initialSettings
        self.persist = persist
        self.apply = apply
    }

    func save(_ candidate: TravelSettings) -> TravelSettingsSaveOutcome {
        if isRestoringSettings {
            guard candidate != lastPersistedSettings else {
                isRestoringSettings = false
                return .ignoredRollback
            }
            isRestoringSettings = false
        }

        do {
            try persist(candidate)
            lastPersistedSettings = candidate
            apply(candidate)
            return .applied
        } catch {
            isRestoringSettings = candidate != lastPersistedSettings
            return .rollback(
                lastPersistedSettings,
                message: "设置保存失败：\(error)"
            )
        }
    }
}

@MainActor
final class TravelCatEnvironment: ObservableObject {
    let repository: TravelRepository
    let model: AppModel
    let settingsStore: TravelSettingsStore
    let notificationService: NotificationService
    let bubbleController: PetTravelBubbleController
    let statusToastController: TravelStatusToastController
    let testPaperController: TravelCatTestPaperController
    let petPromptService: PetTravelPromptService
    private let settingsLifecycle: TravelSettingsLifecycle
    private let characterSelectionLifecycle: CharacterSelectionLifecycle
    @Published var settings: TravelSettings
    @Published var errorMessage: String?
    @Published var launchAtLogin: Bool
    @Published var journeyTestController: JourneyTestController?
    @Published private(set) var selectedCharacterProfile: CharacterProfile
    var effectiveCharacterProfile: CharacterProfile { model.characterProfile }

    var effectiveSettings: TravelSettings { settingsLifecycle.effectiveSettings }
    var lastPersistedSettings: TravelSettings { settingsLifecycle.lastPersistedSettings }

    init(
        repository: TravelRepository,
        model: AppModel,
        settings: TravelSettings,
        selectedCharacterProfile initialSelectedCharacterProfile: CharacterProfile? = nil,
        petLocator: @escaping () -> PetCompanionAnchor?,
        route: @escaping (PetTravelRoute) -> Void,
        testRequest: @escaping () -> Void = {},
        testModeChanged: @escaping (Bool) -> Void = { _ in },
        promptStateChanged: @escaping () -> Void
    ) throws {
        self.repository = repository
        self.model = model
        self.settings = settings
        let characterConfiguration: CharacterConfigurationResponse
        if let initialSelectedCharacterProfile {
            characterConfiguration = CharacterConfigurationResponse(
                selectedProfile: initialSelectedCharacterProfile,
                effectiveProfile: model.characterProfile,
                dataRoot: repository.root
            )
        } else {
            characterConfiguration = try repository.characterConfiguration()
        }
        characterSelectionLifecycle = CharacterSelectionLifecycle(initial: characterConfiguration)
        selectedCharacterProfile = characterConfiguration.selectedProfile
        let settingsStore = TravelSettingsStore(root: repository.root)
        self.settingsStore = settingsStore
        let notificationService = NotificationService()
        self.notificationService = notificationService
        let bubbleController = PetTravelBubbleController(locator: petLocator, tapMenuEnabled: true)
        bubbleController.setTestActionsEnabled(settings.isFastTestEnabled)
        self.bubbleController = bubbleController
        let statusToastController = TravelStatusToastController()
        self.statusToastController = statusToastController
        testPaperController = TravelCatTestPaperController(locator: petLocator)
        petPromptService = PetTravelPromptService(
            coordinator: try PetTravelPromptCoordinator(repository: repository),
            showBubble: { [weak bubbleController, route] delivery, onTap, onAvailableForReplacement in
                bubbleController?.show(
                    delivery: delivery,
                    onTap: onTap,
                    onRouteSelected: route,
                    onTestRequested: testRequest,
                    onAvailableForReplacement: onAvailableForReplacement
                ) ?? false
            },
            postNotification: { [weak notificationService] delivery in
                await notificationService?.postTravelPromptFallback(delivery) ?? false
            },
            route: route,
            stateChanged: promptStateChanged,
            preferBubble: { $0.followCodexPet },
            applyBubblePreference: { [weak bubbleController] enabled in
                bubbleController?.settingsDidChange(followCodexPet: enabled)
            }
        )
        let petPromptService = self.petPromptService
        settingsLifecycle = TravelSettingsLifecycle(
            initialSettings: settings,
            persist: settingsStore.save,
            apply: { [weak notificationService, weak petPromptService, weak bubbleController, weak testPaperController, weak statusToastController] settings in
                statusToastController?.dismiss()
                notificationService?.settingsDidChange(settings)
                petPromptService?.settingsDidChange(settings: settings, now: Date())
                bubbleController?.setTestActionsEnabled(settings.isFastTestEnabled)
                testPaperController?.settingsDidChange(
                    isFastTestEnabled: settings.isFastTestEnabled,
                    followCodexPet: settings.followCodexPet
                )
                testModeChanged(settings.isFastTestEnabled)
            }
        )
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func showTestPaper() {
        let result = testPaperController.request(
            isFastTestEnabled: effectiveSettings.isFastTestEnabled,
            followCodexPet: effectiveSettings.followCodexPet
        )
        errorMessage = result.message
    }

    func saveSettings() {
        switch settingsLifecycle.save(settings) {
        case .applied:
            errorMessage = nil
        case let .rollback(persisted, message):
            settings = persisted
            errorMessage = message
        case .ignoredRollback:
            break
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            errorMessage = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            errorMessage = "登录启动设置失败：\(error)"
        }
    }

    func exportData() {
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Travel Cat Export \(formatter.string(from: now))"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        do {
            _ = try repository.export(to: selected)
            errorMessage = nil
        } catch {
            errorMessage = "导出失败：\(error)"
        }
    }

    func clearHistory() {
        do {
            let backup = try repository.clearHistory()
            let contents = try repository.loadContents()
            applyRepositoryContents(contents, replacingHistory: true)
            errorMessage = "历史已清除，可从备份恢复：\(backup.path)"
        } catch {
            errorMessage = "清除历史失败：\(error)"
        }
    }

    func applyRepositoryContents(_ contents: RepositoryContents, replacingHistory: Bool = false) {
        let configuration = CharacterConfigurationResponse(
            selectedProfile: contents.selectedCharacterProfile,
            effectiveProfile: contents.characterProfile,
            dataRoot: repository.root
        )
        _ = characterSelectionLifecycle.update { configuration }
        selectedCharacterProfile = contents.selectedCharacterProfile
        if replacingHistory {
            model.replaceAfterHistoryClear(
                next: contents.snapshot,
                events: contents.events,
                characterProfile: contents.characterProfile
            )
        } else {
            model.apply(
                next: contents.snapshot,
                events: contents.events,
                characterProfile: contents.characterProfile
            )
        }
    }

    func refreshCharacterConfiguration() {
        switch characterSelectionLifecycle.update({ try repository.characterConfiguration() }) {
        case let .applied(configuration):
            applyCharacterConfiguration(configuration)
            errorMessage = nil
        case let .failed(message):
            errorMessage = message.replacingOccurrences(of: "角色设置失败，已保留当前选择", with: "角色设置读取失败，已保留当前显示")
        }
    }

    func chooseCharacter() {
        let panel = NSOpenPanel()
        panel.title = "选择 Codex 宠物文件夹"
        panel.prompt = "选择角色"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        let suggested = CodexPetsDirectoryResolver.preferred(
            environment: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser
        )
        if FileManager.default.fileExists(atPath: suggested.path) { panel.directoryURL = suggested }
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        configureCharacter(.import(directory: directory.standardizedFileURL))
    }

    func resetCharacter() {
        configureCharacter(.default)
    }

    private func configureCharacter(_ request: CharacterConfigurationRequest) {
        switch characterSelectionLifecycle.update({ try repository.configureCharacter(request) }) {
        case let .applied(configuration):
            applyCharacterConfiguration(configuration)
            errorMessage = nil
        case let .failed(message):
            errorMessage = message
        }
    }

    private func applyCharacterConfiguration(_ response: CharacterConfigurationResponse) {
        selectedCharacterProfile = response.selectedProfile
        model.apply(next: model.snapshot, events: model.events, characterProfile: response.effectiveProfile)
    }
}

struct TravelCatSettingsView: View {
    @ObservedObject var environment: TravelCatEnvironment
    var requestAlbumPreview: () -> Void = {}
    var requestFullJourney: () -> Void = {}
    var requestRealJourney: () -> Void = {}
    var requestTestAlbum: () -> Void = {}
    @State private var confirmsClear = false

    var body: some View {
        Form {
            CharacterSettingsSection(environment: environment, model: environment.model)
            Toggle("快速测试", isOn: Binding(
                get: { environment.settings.isFastTestEnabled },
                set: { environment.settings.mode = $0 ? .fast : .daily }
            ))
            Picker("安静时段开始", selection: $environment.settings.quietStart) {
                ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
            }
            Picker("安静时段结束", selection: $environment.settings.quietEnd) {
                ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
            }
            Toggle("旅行纸条与状态变化提示", isOn: $environment.settings.followCodexPet)
            Toggle("登录时启动", isOn: Binding(
                get: { environment.launchAtLogin },
                set: { environment.setLaunchAtLogin($0) }
            ))
            if environment.effectiveSettings.isFastTestEnabled {
                Section("完整旅程测试") {
                    Text("紧凑测试约 15～20 秒，固定使用内置黑猫示例剧情与已有图片，不预览自定义宠物的生成效果，也不消耗模型额度。两种测试都只写入测试区域，不影响正式旅行册。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let controller = environment.journeyTestController {
                        JourneyTestSettingsControls(controller: controller, start: requestFullJourney, startReal: requestRealJourney, showAlbum: requestTestAlbum)
                    } else {
                        Button("紧凑测试完整旅程", action: requestFullJourney).buttonStyle(.borderedProminent)
                        Button("真实生成测试旅程", action: requestRealJourney)
                        Button("查看测试旅行册", action: requestTestAlbum)
                    }
                    Text("真实生成会消耗模型额度；新剧情和新图片需要额外等待。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("旅行册展示测试") {
                    Text("临时展示 6 张固定明信片，用于检验原生明信片布局、字体与猫爪显示。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("预览 6 张明信片") { requestAlbumPreview() }
                        .buttonStyle(.borderedProminent)
                    Button("立即显示测试纸条") { environment.showTestPaper() }
                }
            }
            HStack {
                Button("导出数据…") { environment.exportData() }
                Button("清除旅行历史…", role: .destructive) { confirmsClear = true }
            }
            if let message = environment.errorMessage {
                Text(message).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 480)
        .frame(minHeight: 520)
        .onChange(of: environment.settings) { _, _ in environment.saveSettings() }
        .onAppear { environment.refreshCharacterConfiguration() }
        .alert("清除所有旅行历史？", isPresented: $confirmsClear) {
            Button("取消", role: .cancel) {}
            Button("清除并创建备份", role: .destructive) { environment.clearHistory() }
        } message: {
            Text("当前行程、日志和明信片会移入可恢复备份；设置与旧备份会保留。")
        }
    }
}

private struct CharacterSettingsSection: View {
    @ObservedObject var environment: TravelCatEnvironment
    @ObservedObject var model: AppModel

    var body: some View {
        let display = CharacterSettingsDisplayState(model: model)
        Section("角色") {
            LabeledContent("当前显示", value: display.effectiveProfile.displayName)
            LabeledContent("已选择", value: environment.selectedCharacterProfile.displayName)
            if display.effectiveProfile != environment.selectedCharacterProfile {
                Text("当前旅程继续使用出发时的角色；新选择会在下一次旅行生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("从现有 Codex 宠物文件夹导入只会更改 Travel Cat，不会更改 Codex 自己的宠物设置。")
                .font(.caption).foregroundStyle(.secondary)
            if environment.selectedCharacterProfile != .defaultBlackCat,
               environment.selectedCharacterProfile.referenceImages.isEmpty {
                Text("所选宠物没有参考图，真实生成只能依据文字描述，跨图一致性有限；不会改用内置黑猫。")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("选择 Codex 宠物文件夹…") { environment.chooseCharacter() }
                Button("恢复内置黑猫") { environment.resetCharacter() }
            }
        }
    }
}

private struct JourneyTestSettingsControls: View {
    @ObservedObject var controller: JourneyTestController
    var start: () -> Void
    var startReal: () -> Void
    var showAlbum: () -> Void

    var body: some View {
        Text(controller.status).font(.caption).foregroundStyle(.secondary)
        HStack {
            Button("紧凑测试完整旅程", action: start)
                .buttonStyle(.borderedProminent).disabled(controller.isRunning)
            if controller.isRunning {
                Button("停止测试") { controller.stop() }
            }
        }
        HStack {
            Button("真实生成测试旅程", action: startReal).disabled(controller.isRunning)
            Button("查看测试旅行册", action: showAlbum).disabled(controller.session == nil)
        }
        if let error = controller.errorMessage {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }
}
