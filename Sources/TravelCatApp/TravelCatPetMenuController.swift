import AppKit

final class TravelCatPetMenuController: NSObject {
    private let menu = NSMenu()
    private let onAction: (TravelCatPetMenuAction) -> Void
    private var actionsByTag: [Int: TravelCatPetMenuAction] = [:]

    init(onAction: @escaping (TravelCatPetMenuAction) -> Void) {
        self.onAction = onAction
    }

    static func title(for action: TravelCatPetMenuAction) -> String {
        switch action {
        case .currentJourney: "当前状态"
        case .latestPostcard: "最新明信片"
        case .album: "旅行册"
        case .temporaryTest: "临时测试"
        case .closePet: "关闭宠物"
        }
    }

    func present(state: TravelCatPetMenuState, at screenPoint: NSPoint) {
        menu.removeAllItems()
        actionsByTag.removeAll()
        var tag = 0
        for descriptor in state.items {
            switch descriptor {
            case .separator:
                menu.addItem(.separator())
            case let .action(action, enabled):
                let nextTag = tag
                tag += 1
                actionsByTag[nextTag] = action

                let item = NSMenuItem(
                    title: Self.title(for: action),
                    action: #selector(performMenuItem(_:)),
                    keyEquivalent: ""
                )
                item.tag = nextTag
                item.target = self
                item.isEnabled = enabled
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil, at: screenPoint, in: nil)
        actionsByTag.removeAll()
    }

    func performForTesting(_ action: TravelCatPetMenuAction) {
        onAction(action)
    }

    @objc private func performMenuItem(_ sender: NSMenuItem) {
        guard sender.isEnabled,
              let action = actionsByTag[sender.tag] else { return }
        onAction(action)
    }
}
