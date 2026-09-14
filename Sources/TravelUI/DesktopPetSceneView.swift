import SwiftUI
import TravelCore

/// Desktop presentation follows committed travel facts, not generation progress.
@MainActor
public struct DesktopPetSceneView: View {
    @ObservedObject private var model: AppModel
    private let showStatus: () -> Void
    private let showPostcard: () -> Void
    private let showAlbum: () -> Void
    private let showSettings: () -> Void
    private let hide: () -> Void

    public init(model: AppModel, showStatus: @escaping () -> Void,
                showPostcard: @escaping () -> Void, showAlbum: @escaping () -> Void,
                showSettings: @escaping () -> Void, hide: @escaping () -> Void) {
        self.model = model
        self.showStatus = showStatus
        self.showPostcard = showPostcard
        self.showAlbum = showAlbum
        self.showSettings = showSettings
        self.hide = hide
    }

    public var body: some View {
        let status = CurrentPetStatus(snapshot: model.snapshot, events: model.events, now: Date())
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 0) {
                if let phase = status.desktopSpritePhase {
                    PetSpriteView(state: phase, profile: model.characterProfile, dataRoot: model.dataRoot)
                    if status.scene == .packing {
                        Image(systemName: "suitcase.rolling.fill")
                            .font(.system(size: 28)).foregroundStyle(.orange)
                            .padding(.bottom, 12)
                    }
                } else {
                    Image(systemName: status.scene == .away ? "house.fill" : "questionmark.diamond")
                        .font(.system(size: 72, weight: .light))
                        .foregroundStyle(.brown)
                        .frame(height: 120)
                }
            }
            Text(status.title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
        }
        .padding(12)
        .contextMenu {
            Button("当前状态", action: showStatus)
            Button("最新明信片", action: showPostcard)
            Button("旅行册", action: showAlbum)
            Divider()
            Button("设置…", action: showSettings)
            Button("隐藏桌面小猫", action: hide)
        }
        .accessibilityLabel("Travel Cat，\(status.title)")
        .frame(width: PetWindowController.compactSize.width, height: PetWindowController.compactSize.height)
    }
}
