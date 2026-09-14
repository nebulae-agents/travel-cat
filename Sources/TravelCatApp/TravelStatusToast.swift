import AppKit
import SwiftUI
import TravelStorage
import TravelUI

struct TravelStatusToastContent: Equatable {
    let title: String
    let message: String
}

@MainActor
final class TravelStatusToastController: NSWindowController {
    private(set) var content: TravelStatusToastContent?
    private let scheduler: BubbleScheduling
    private var expiry: BubbleCancellation?
    private var onTap: (() -> Void)?
    private var generation = UUID()

    init(scheduler: BubbleScheduling = TimerBubbleScheduler()) {
        self.scheduler = scheduler
        super.init(window: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func show(_ content: TravelStatusToastContent, onTap: @escaping () -> Void) {
        dismiss()
        self.content = content
        self.onTap = onTap
        if let screen = NSScreen.main {
            let panel = window ?? makePanel()
            window = panel
            panel.contentView = NSHostingView(rootView:
                HStack(alignment: .top, spacing: 12) {
                    Button { [weak self] in self?.activate() } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "pawprint.fill").font(.title2).foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(content.title).font(.headline)
                                Text(content.message).font(.subheadline).lineLimit(2).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityHint("打开当前状态")
                    Button { [weak self] in self?.dismiss() } label: {
                        Image(systemName: "xmark").font(.caption)
                    }.buttonStyle(.plain).accessibilityLabel("关闭提示")
                }
                .padding(16).frame(width: 320, height: 112)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            )
            let frame = screen.visibleFrame
            panel.setFrame(NSRect(x: max(frame.minX, frame.maxX - 340),
                                  y: max(frame.minY, frame.maxY - 132), width: 320, height: 112), display: true)
            panel.orderFrontRegardless()
        }
        let currentGeneration = generation
        expiry = scheduler.after(4) { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.dismiss()
        }
    }

    func dismiss() {
        generation = UUID()
        expiry?.cancel()
        expiry = nil
        onTap = nil
        content = nil
        window?.orderOut(nil)
    }

    func activate() {
        let action = onTap
        dismiss()
        action?()
    }

    override func close() {
        dismiss()
        super.close()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 112),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        return panel
    }
}

enum TravelStatusToastPolicy {
    static func content(previous: RepositoryContents?, current: RepositoryContents,
                        now: Date, settings: TravelSettings) -> TravelStatusToastContent? {
        guard let previous, settings.followCodexPet,
              !NotificationPolicy(quietStart: settings.quietStart, quietEnd: settings.quietEnd)
                .isQuiet(hour: Calendar.current.component(.hour, from: now)),
              current.snapshot.stateVersion > previous.snapshot.stateVersion,
              current.snapshot.lastUpdatedAt <= now,
              let eventID = current.snapshot.lastEventID,
              eventID != previous.snapshot.lastEventID,
              !previous.events.contains(where: { $0.id == eventID }),
              [.transit, .exploring, .returning].contains(current.snapshot.phase) else { return nil }
        let matches = current.events.filter { $0.id == eventID }
        guard matches.count == 1, let event = matches.first,
              event.tripID == current.snapshot.tripID, event.phase == current.snapshot.phase,
              event.occurredAt <= current.snapshot.lastUpdatedAt,
              PetTravelPromptDetector.detect(previous: previous, current: current).isEmpty,
              !current.events.contains(where: { item in
                  item.postcardStatus == .imageUnavailable &&
                    !previous.events.contains(where: { $0.id == item.id && $0.postcardStatus == .imageUnavailable })
              }) else { return nil }
        let before = CurrentPetStatus(snapshot: previous.snapshot, events: previous.events, now: now)
        let after = CurrentPetStatus(snapshot: current.snapshot, events: current.events, now: now)
        guard before.title != after.title || before.location != after.location else { return nil }
        return TravelStatusToastContent(title: after.title,
            message: after.location ?? after.summary.map { String($0.prefix(70)) } ?? "点击查看当前状态")
    }
}
