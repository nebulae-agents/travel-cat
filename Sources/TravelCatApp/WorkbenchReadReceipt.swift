import AppKit
import SwiftUI

/// Tokens own only Foundation notification registrations; cleanup needs no UI executor.
final class WorkbenchReceiptObservers {
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []
    init(center: NotificationCenter = .default) { self.center = center }
    func replace(_ next: [NSObjectProtocol]) {
        removeAll()
        tokens = next
    }
    func removeAll() {
        tokens.forEach(center.removeObserver)
        tokens = []
    }
    deinit { tokens.forEach(center.removeObserver) }
}

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
        private let observations = WorkbenchReceiptObservers()
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observations.removeAll()
            if let window {
                observations.replace([NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification].map { name in
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        Task { @MainActor in self?.scheduleReceipt() }
                    }
                })
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
        // Avoid isolated-deinit back deployment on older Swift runtimes. The token
        // owner performs Foundation cleanup; all view operations remain MainActor.
        nonisolated deinit {}
    }
}
