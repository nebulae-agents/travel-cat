import SwiftUI
import TravelCore

/// A read-only illustration of travel facts, never a claim to mirror Codex animation.
@MainActor
public struct CurrentPetStatusView: View {
    @ObservedObject private var model: AppModel
    private let close: () -> Void
    private let openPostcard: (UUID) -> Void
    private let openAlbum: () -> Void

    public init(model: AppModel, close: @escaping () -> Void,
                openPostcard: @escaping (UUID) -> Void, openAlbum: @escaping () -> Void) {
        self.model = model
        self.close = close
        self.openPostcard = openPostcard
        self.openAlbum = openAlbum
    }

    public var body: some View {
        let status = CurrentPetStatus(snapshot: model.snapshot, events: model.events, now: Date())
        VStack(spacing: 0) {
            HStack {
                Label("当前状态", systemImage: "pawprint.fill").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("关闭")
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CurrentPetStatusArtwork(scene: status.scene, profile: model.characterProfile, dataRoot: model.dataRoot)
                        .frame(height: 176)
                        .frame(maxWidth: .infinity)
                        .background(Color.accentColor.opacity(0.045), in: RoundedRectangle(cornerRadius: 20))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(status.title).font(.system(size: 26, weight: .semibold, design: .rounded))
                        Text(sceneCaption(status.scene)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let location = status.location {
                        Label(location, systemImage: "mappin.and.ellipse").font(.subheadline)
                    }
                    if let transport = status.transport {
                        Label(transport, systemImage: "signpost.right").font(.subheadline)
                    }
                    if let summary = status.summary {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("最近记录").font(.caption).foregroundStyle(.secondary)
                            Text(summary).font(.body).textSelection(.enabled)
                        }
                    }
                    Label(status.codexActivityNotice, systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let updatedAt = status.updatedAt {
                        HStack(spacing: 4) {
                            Text("旅行记录更新于")
                            Text(updatedAt, format: .dateTime.month().day().hour().minute())
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("记录时间晚于当前时间，请检查系统时间。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            Divider()
            HStack {
                if let id = model.nextUnreadPostcardID {
                    Button("新明信片") { openPostcard(id) }.buttonStyle(.borderedProminent)
                }
                Button("旅行册", action: openAlbum)
                    .buttonStyle(.bordered).disabled(model.latestAvailableTripID() == nil)
                Spacer()
                Button("关闭", action: close).buttonStyle(.bordered)
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func sceneCaption(_ scene: CurrentPetStatus.Scene) -> String {
        switch scene {
        case .home: "黑猫在家；动画仅示意旅行阶段"
        case .packing: "准备行李，还没有正式离家"
        case .away: "正在外出；这里留一盏回家的灯"
        case .unknown: "暂时无法确认当前旅行状态"
        }
    }
}

@MainActor
struct CurrentPetStatusArtwork: View {
    let scene: CurrentPetStatus.Scene
    let profile: CharacterProfile
    let dataRoot: URL?

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                Ellipse().fill(Color.brown.opacity(0.10)).frame(width: 220, height: 18)
                switch scene {
                case .home, .packing:
                    HStack(alignment: .bottom, spacing: 4) {
                        Image(systemName: "house.fill")
                            .font(.system(size: 45)).foregroundStyle(Color.brown.opacity(0.23))
                            .padding(.bottom, 12)
                        CurrentPetPortrait(profile: profile, dataRoot: dataRoot)
                        if scene == .packing {
                            Image(systemName: "backpack.fill")
                                .font(.system(size: 38)).foregroundStyle(.orange.opacity(0.8))
                                .padding(.bottom, 10)
                        }
                    }
                case .away:
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "location.north.line")
                            Text("外出中").font(.caption)
                        }.foregroundStyle(.secondary)
                        Image(systemName: "house.fill")
                            .font(.system(size: 74)).foregroundStyle(Color.brown.opacity(0.5))
                    }.padding(.bottom, 10)
                case .unknown:
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 60, weight: .light)).foregroundStyle(.secondary)
                        .padding(.bottom, 25)
                }
            }
            .frame(height: 130)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(artworkLabel)
            Text("旅行阶段示意 · 非实时动作").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    var artworkLabel: String {
        switch scene {
        case .home: "\(profile.displayName)在家的角色示意"
        case .packing: "\(profile.displayName)与准备出游的背包"
        case .away: "外出中的空屋，没有宠物"
        case .unknown: "未知状态"
        }
    }
}

/// Frame zero only: the status page must not invent a live Codex animation.
@MainActor
private struct CurrentPetPortrait: View {
    private let image: NSImage?

    init(profile: CharacterProfile, dataRoot: URL?) {
        if case let .available(url) = CharacterSpriteResolver.resolve(profile: profile, dataRoot: dataRoot) {
            image = NSImage(contentsOf: url)
        } else {
            image = nil
        }
    }

    var body: some View {
        let layout = PetSpriteLayout.version2
        let scale = PetSpriteView.displayScale
        ZStack(alignment: .topLeading) {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: layout.sheetSize.width * scale, height: layout.sheetSize.height * scale)
            } else {
                Text("角色图片不可用").font(.caption).foregroundStyle(.secondary)
                    .frame(width: layout.frameSize.width * scale, height: layout.frameSize.height * scale)
            }
        }
        .frame(width: layout.frameSize.width * scale, height: layout.frameSize.height * scale, alignment: .topLeading)
        .clipped()
    }
}
