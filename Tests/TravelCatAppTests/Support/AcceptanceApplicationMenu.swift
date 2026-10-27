import AppKit

/// Shared by the manual AppKit preview and its menu-dispatch regressions.
@MainActor
enum AcceptanceApplicationMenu {
    static func make(target: AnyObject, show: Selector, close: Selector) -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(); menu.addItem(item)
        let appMenu = NSMenu(); item.submenu = appMenu
        let showItem = NSMenuItem(title: "显示独立验收窗口", action: show, keyEquivalent: "0")
        showItem.target = target; appMenu.addItem(showItem)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "关闭独立验收", action: close, keyEquivalent: "q")
        quit.target = target; appMenu.addItem(quit)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "编辑"); editItem.submenu = edit; menu.addItem(editItem)
        let commands: [(String, String, String, NSEvent.ModifierFlags)] = [
            ("撤销", "undo:", "z", .command), ("重做", "redo:", "z", [.command, .shift]),
            ("剪切", "cut:", "x", .command), ("拷贝", "copy:", "c", .command),
            ("粘贴", "paste:", "v", .command), ("全选", "selectAll:", "a", .command)
        ]
        for (index, command) in commands.enumerated() {
            if index == 2 { edit.addItem(.separator()) }
            let item = NSMenuItem(title: command.0, action: Selector(command.1), keyEquivalent: command.2)
            item.keyEquivalentModifierMask = command.3
            // Nil target and automatic validation keep the active editor in control.
            edit.addItem(item)
        }
        return menu
    }
}
