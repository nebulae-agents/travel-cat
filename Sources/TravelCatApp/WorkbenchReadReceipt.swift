import AppKit
import SwiftUI

/// Selection survives closing a window. Only a visibly presented detail can acknowledge a result.
struct WorkbenchReadReceipt: NSViewRepresentable {
    let taskID: UUID?
    let unread: Bool
    let acknowledge: (UUID) -> Void
    func makeNSView(context: Context) -> ReceiptView { ReceiptView() }
    func updateNSView(_ view: ReceiptView, context: Context) {
        view.acknowledge = {
            if unread, let taskID { acknowledge(taskID) }
        }
        view.scheduleReceipt()
    }
    @MainActor final class ReceiptView: NSView {
        var acknowledge: (() -> Void)?
        private var observations: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observations.forEach(NotificationCenter.default.removeObserver)
            observations = []
            if let window {
                observations = [NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification].map { name in
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        Task { @MainActor in self?.scheduleReceipt() }
                    }
                }
            }
            scheduleReceipt()
        }
        func scheduleReceipt() {
            Task { @MainActor [weak self] in
                guard let self, let window = self.window, window.isVisible, !window.isMiniaturized,
                      window.occlusionState.contains(.visible), !self.isHiddenOrHasHiddenAncestor else { return }
                self.acknowledge?()
            }
        }
        isolated deinit { observations.forEach(NotificationCenter.default.removeObserver) }
    }
}
