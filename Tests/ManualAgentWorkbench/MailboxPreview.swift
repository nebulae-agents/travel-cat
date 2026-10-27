// Offline mailbox acceptance. Only temporary data, in-memory fake keys and fake runtime.
import AppKit
import SwiftUI
import Combine
import TravelUI
import TravelCore
extension Bundle { static var module: Bundle { .main } }

@MainActor final class MailboxFixtureKeys: TravelServiceCredentialStoring {
    var values: [String: String] = [:]
    func read(id: String) throws -> String? { values[id] }
    func save(_ secret: String?, id: String) throws { values[id] = secret }
}
@MainActor final class MailboxFixtureRuntime: AgentRuntimeClient {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    func launch(python: String) throws {}
    func shutdown() { onExit?() }
    func request(_ method: String, _ params: [String: Any], timeout: UInt64) async throws -> [String: Any] {
        if method == "start" { return ["sessionId": "offline-session"] }
        if method == "prompt", let id = params["taskId"] as? String {
            onEvent?(["event": "permission", "taskId": id, "data": ["requestId": UUID().uuidString, "toolCall": ["title": "离线测试：读取示例文件", "description": "仅测试确认入口，没有真实文件访问。"], "options": [["optionId": "deny", "name": "拒绝", "kind": "reject_once"]]]])
        }
        return [:]
    }
}
@MainActor final class MailboxFixture: NSObject, ObservableObject {
    @Published var notice = "请选择无提示、单条或多条状态"
    let reader = TravelUtilityWindowController()
    var traceObservers: [NSObjectProtocol] = []
    var traceLines: [String] = []
    var desktop: StandalonePetController?
    var house: NSWindow? { desktop?.window }
    let detail = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 740), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)

    var model: AgentWorkbenchModel?
    var pet: AppModel?
    var subscriptions: [AnyCancellable] = []
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mailbox-ui-\(UUID())")
    let defaultsName = "MailboxPreview-\(UUID())"
    override init() {
        super.init()
        for name in [NSWindow.didMoveNotification, NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
            traceObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let label = note.name.rawValue
                MainActor.assumeIsolated { self?.record(label) }
            })
        }
        detail.isReleasedWhenClosed = false; detail.title = "邮筒 · 离线对话验收"
    }
    func record(_ event: String) {
        let windows = NSApp.windows.filter { $0.isVisible }.map { "\($0.title):\(NSStringFromRect($0.frame)):key=\($0.isKeyWindow):visible=\($0.occlusionState.contains(.visible))" }.joined(separator: " | ")
        traceLines.append("\(Date()) \(event) active=\(NSApp.isActive) unread=\(pet?.unreadPostcardIDs.count ?? -1) \(windows)")
        try? traceLines.joined(separator: "\n").write(toFile: "/tmp/mailbox-native-trace.txt", atomically: true, encoding: .utf8)
    }
    func configure(_ count: Int) {
        desktop?.hide(); model?.shutdown(); detail.orderOut(nil); reader.window?.orderOut(nil); subscriptions.removeAll()
        do {
            let directory = root.appendingPathComponent(UUID().uuidString)
            var state = WorkbenchSnapshot()
            var instance = WorkbenchInstance(name: "小屋开发助手", image: "offline@sha256:" + String(repeating: "a", count: 64), command: ["fixture"])
            instance.provider.model = "offline-fixture"; state.instances = [instance]
            if count > 0 {
                var result = WorkbenchTask(instanceID: instance.id, title: "花园整理计划已完成")
                result.status = .completed; result.unread = true
                result.messages = [.init(role: "user", text: "帮我整理小屋花园的待办。"), .init(role: "assistant", text: "离线示例结果：先浇花，再修整藤蔓，最后清理石板路。这里没有调用真实模型。")]
                state.tasks = [result]
            }
            try WorkbenchStore(root: directory).save(state)
            let keys = MailboxFixtureKeys(); try keys.save("fake-key", id: instance.provider.credentialID)
            let current = AgentWorkbenchModel(root: directory, credentials: keys, client: MailboxFixtureRuntime())
            current.preferredInstanceID = instance.id
            model = current
            let trip = UUID(), mood = Mood(level: 2, label: "期待", quote: "风吹过花园。")
            let snapshot = TripSnapshot(stateVersion: 1, tripID: trip, phase: .resting, nextActionAt: Date().addingTimeInterval(3600), lastUpdatedAt: Date(), usedItemIDs: [], visitedPlaces: [], mood: mood)
            let imageRelativePath = "postcards/\(trip.uuidString.lowercased())/preview.png"
            let imageDirectory = directory.appendingPathComponent("postcards/\(trip.uuidString.lowercased())")
            try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/preview.png"), to: imageDirectory.appendingPathComponent("preview.png"))
            let imageData = try PostcardImageLoader.loadData(relativePath: imageRelativePath, rootURL: directory)
            guard NSImage(data: imageData) != nil else { throw CocoaError(.fileReadCorruptFile) }
            let events: [TripEvent] = count > 1 ? [.init(id: UUID(), tripID: trip, previousEventID: nil, occurredAt: Date().addingTimeInterval(-100), phase: .exploring, location: nil, transport: nil, summary: "离线明信片：山间的一阵风", mood: mood, continuityReferences: [], openHook: nil, consumedItemID: nil, postcardStatus: .ready, postcardRelativePath: imageRelativePath)] : []
            let pet = AppModel(snapshot: snapshot, events: events, dataRoot: directory, defaults: UserDefaults(suiteName: defaultsName)!)
            self.pet = pet
            let showAgents: () -> Void = { [weak self, weak current] in
                guard let self, let current else { return }
                self.detail.contentView = NSHostingView(rootView: AgentWorkbenchView(model: current))
                self.detail.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            }
            desktop = StandalonePetController(model: pet, openJourney: { [weak self] in self?.notice = "小屋点击成功" },
                openPostcard: { [weak self] in guard let id = pet.nextUnreadPostcardID else { return }; self?.showCard(id) },
                openAlbum: { [weak self] in pet.openLatestAlbumFromStatus(); self?.showReader() }, openSupplies: {},
                positionStore: WindowPositionStore(defaults: UserDefaults(suiteName: defaultsName)!),
                openAgents: showAgents, openMailboxPostcard: { [weak self] id in self?.showCard(id) },
                agentWorkbench: current, mailboxPositionStore: MailboxPositionStore(defaults: UserDefaults(suiteName: defaultsName)!))
            house?.title = "小黑的小屋 · 离线验收"
            house?.setFrameOrigin(CGPoint(x: 500, y: 240))
            desktop?.show()
            subscriptions = [pet.objectWillChange.sink { [weak self] in Task { @MainActor in
                guard let self else { return }
                self.notice = "明信片未读：\(pet.unreadPostcardIDs.count) · 收藏：\(pet.favouritePostcardIDs.count)"
                self.record("model change")
            } }]
            notice = count == 0 ? "无提示：邮筒常驻、无角标" : count == 1 ? "单条：打开后直接看详情" : "多条：确认、结果、明信片汇总"
            if count > 1 { Task { await current.start(instanceID: instance.id, text: "需要确认的离线示例") } }
        } catch { notice = error.localizedDescription }
    }
    func showCard(_ id: UUID) {
        guard let pet, pet.openPostcardFromMailbox(eventID: id) else { return }
        showReader()
    }
    func showReader() {
        guard let pet else { return }
        reader.show(content: AnyView(MailboxFormalReader(model: pet) { [weak self] in self?.reader.window?.orderOut(nil) }
            .onChange(of: pet.presentation) { [weak self] _, route in
                if case .album = route { self?.reader.resize(to: TravelUtilityWindowController.albumSize) }
                else { self?.reader.resize(to: TravelUtilityWindowController.postcardSize) }
            }), size: TravelUtilityWindowController.postcardSize)
        reader.window?.title = "正式明信片 · 离线验收"
        record("show reader")
    }
    weak var controlWindow: NSWindow?
    @objc func showControls() { controlWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); record("controls") }
    func focusHouse() { house?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); record("focus house") }
    func focusMailbox() {
        NSApp.windows.first(where: { $0.title == "小黑的邮筒" && $0.isVisible })?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true); record("focus mailbox")
    }

    func moveToEdge() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        house?.setFrameOrigin(CGPoint(x: screen.maxX - 240, y: screen.minY + 80))

    }
    func finish() { desktop?.hide(); model?.shutdown(); house?.orderOut(nil); detail.orderOut(nil); reader.window?.orderOut(nil); UserDefaults.standard.removePersistentDomain(forName: defaultsName); try? FileManager.default.removeItem(at: root) }
}
@main @MainActor struct MailboxPreview {
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let fixture = MailboxFixture()
        let window = NSWindow(contentRect: NSRect(x: 120, y: 650, width: 610, height: 130), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "小黑邮筒 · 离线验收"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MailboxFixtureControls(fixture: fixture))
        fixture.controlWindow = window
        let menu = NSMenu(); let rootItem = NSMenuItem(); menu.addItem(rootItem)
        let submenu = NSMenu(); rootItem.submenu = submenu
        let controls = NSMenuItem(title: "显示验收控制", action: #selector(MailboxFixture.showControls), keyEquivalent: "0")
        controls.target = fixture; submenu.addItem(controls)
        submenu.addItem(NSMenuItem(title: "退出预览", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        app.mainMenu = menu
        fixture.configure(3); app.activate(ignoringOtherApps: true)
        app.run(); fixture.finish()
    }
}
struct MailboxFixtureControls: View {
    @ObservedObject var fixture: MailboxFixture
    var body: some View {
        VStack(spacing: 14) {
            HStack { Button("无提示") { fixture.configure(0) }; Button("单条提示") { fixture.configure(1) }; Button("多条提示") { fixture.configure(3) }; Button("靠右边缘") { fixture.moveToEdge() }; Button("聚焦小屋") { fixture.focusHouse() }; Button("聚焦邮筒") { fixture.focusMailbox() }; Button("结束验收") { fixture.finish(); NSApp.terminate(nil) } }
            Text(fixture.notice).font(.callout)
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity).cottageSurface()
    }
}

struct MailboxFormalReader: View {
    @ObservedObject var model: AppModel
    let close: () -> Void
    var body: some View {
        Group {
            switch model.presentation {
            case .postcard(let id):
                if let event = model.events.first(where: { $0.id == id }) {
                    PostcardView(event: event, rootURL: model.dataRoot,
                        isFavourite: model.favouritePostcardIDs.contains(id), toggleFavourite: { model.toggleFavourite(id) },
                        isUnread: model.unreadPostcardIDs.contains(id), recipient: model.postcardRecipient,
                        onSceneryDisplayed: { model.postcardFrontDidDisplay(id, relativePath: $0) }, recipientModel: model) { route in
                            if route == .status { close() } else { model.handle(route) }
                        }
                }
            case .album:
                TripAlbumView(tripID: nil, events: model.events, rootURL: model.dataRoot,
                    unreadIDs: Set(model.unreadPostcardIDs), favouriteIDs: model.favouritePostcardIDs, recipient: model.postcardRecipient) { route in
                        if route == .status { close() } else { model.handle(route) }
                    }
            default: Button("返回邮筒", action: close)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
