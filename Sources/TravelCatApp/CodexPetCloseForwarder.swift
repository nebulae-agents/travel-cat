import AppKit
import ApplicationServices

protocol CodexPetNativeMenuDriving: AnyObject {
    func postRightClick(at point: CGPoint)
    func pressCloseItem(ownerPID: pid_t, allowedTitles: Set<String>) -> Bool
}

final class CodexPetCloseForwarder {
    static let allowedCloseTitles: Set<String> = [
        "关闭宠物",
        "收起宠物",
        "Tuck Away Pet",
        "Close Pet"
    ]

    private let bypass: () -> Void
    private let driver: CodexPetNativeMenuDriving
    private let bundleIdentifierForOwnerPID: (pid_t) -> String?
    private let waitForNativeMenu: () -> Void

    init(
        bypass: @escaping () -> Void,
        driver: CodexPetNativeMenuDriving,
        bundleIdentifierForOwnerPID: @escaping (pid_t) -> String? = CodexPetLocator.currentBundleIdentifier(forOwnerPID:),
        waitForNativeMenu: @escaping () -> Void = { Thread.sleep(forTimeInterval: 0.18) }
    ) {
        self.bypass = bypass
        self.driver = driver
        self.bundleIdentifierForOwnerPID = bundleIdentifierForOwnerPID
        self.waitForNativeMenu = waitForNativeMenu
    }

    func close(selection: CodexPetSelection, clickPoint: CGPoint) -> Bool {
        let ownerBundleIdentifier = bundleIdentifierForOwnerPID(selection.ownerPID)
        guard selection.ownerPID > 0, ownerBundleIdentifier == "com.openai.codex",
              selection.inputBounds.isFiniteNonempty, selection.inputBounds.contains(clickPoint) else {
            return false
        }
        bypass()
        driver.postRightClick(at: clickPoint)
        waitForNativeMenu()
        return driver.pressCloseItem(
            ownerPID: selection.ownerPID,
            allowedTitles: Self.allowedCloseTitles
        )
    }
}

final class MacCodexPetNativeMenuDriver: CodexPetNativeMenuDriving {
    private let maxDepth = 6
    private let maxNodes = 256
    private let kRoleAttribute = "AXRole" as CFString
    private let kTitleAttribute = "AXTitle" as CFString
    private let kEnabledAttribute = "AXEnabled" as CFString
    private let kChildrenAttribute = "AXChildren" as CFString
    private let kPressAction = "AXPress" as CFString

    func postRightClick(at point: CGPoint) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        guard let down = CGEvent(
            mouseEventSource: source,
            mouseType: .rightMouseDown,
            mouseCursorPosition: point,
            mouseButton: .right
        ),
              let up = CGEvent(
                mouseEventSource: source,
                mouseType: .rightMouseUp,
                mouseCursorPosition: point,
                mouseButton: .right
              ) else { return
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    func pressCloseItem(ownerPID: pid_t, allowedTitles: Set<String>) -> Bool {
        guard NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier == "com.openai.codex" else {
            return false
        }
        let application = AXUIElementCreateApplication(ownerPID)
        var matches: [AXUIElement] = []
        var remaining = maxNodes
        findCloseMenuItems(
            in: application,
            depth: 0,
            maxDepth: maxDepth,
            remainingNodeBudget: &remaining,
                allowedTitles: allowedTitles,
                into: &matches
        )
        guard matches.count == 1 else { return false }
        return pressIfEnabled(menuItem: matches[0])
    }

    private func pressIfEnabled(menuItem: AXUIElement) -> Bool {
        guard let role = stringValue(for: menuItem, attribute: kRoleAttribute),
              role == (kAXMenuItemRole as String) else { return false }
        let enabled = boolValue(for: menuItem, attribute: kEnabledAttribute) ?? false
        guard enabled else { return false }
        return AXUIElementPerformAction(menuItem, kPressAction) == .success
    }

    private func findCloseMenuItems(
        in element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        remainingNodeBudget: inout Int,
        allowedTitles: Set<String>,
        into matches: inout [AXUIElement]
    ) {
        guard remainingNodeBudget > 0 else { return }
        guard depth <= maxDepth else { return }
        remainingNodeBudget -= 1

        let role = stringValue(for: element, attribute: kRoleAttribute)
        let title = stringValue(for: element, attribute: kTitleAttribute)
        if role == (kAXMenuItemRole as String),
           let title, allowedTitles.contains(title) {
            let enabled = boolValue(for: element, attribute: kEnabledAttribute) ?? false
            if enabled {
                matches.append(element)
            }
            if matches.count > 1 { return }
        }
        guard depth < maxDepth else { return }

        for child in children(of: element) {
            findCloseMenuItems(
                in: child,
                depth: depth + 1,
                maxDepth: maxDepth,
                remainingNodeBudget: &remainingNodeBudget,
                allowedTitles: allowedTitles,
                into: &matches
            )
            if matches.count > 1 || remainingNodeBudget <= 0 { return }
        }
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        guard let raw = value(for: element, attribute: kChildrenAttribute),
              let rawChildren = raw as? NSArray else {
            return []
        }
        return rawChildren.compactMap { child in
            guard let rawType = child as CFTypeRef? else { return nil }
            guard CFGetTypeID(rawType) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(rawType, to: AXUIElement.self)
        }
    }

    private func stringValue(for element: AXUIElement, attribute: CFString) -> String? {
        guard let value = value(for: element, attribute: attribute) else { return nil }
        return value as? String
    }

    private func boolValue(for element: AXUIElement, attribute: CFString) -> Bool? {
        guard let value = value(for: element, attribute: attribute) else { return nil }
        if let boolValue = value as? Bool {
            return boolValue
        }
        if let numberValue = value as? NSNumber {
            return numberValue.boolValue
        }
        return nil
    }

    private func value(for element: AXUIElement, attribute: CFString) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value
    }
}
