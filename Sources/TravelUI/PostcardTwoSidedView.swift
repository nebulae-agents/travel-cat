import SwiftUI
import TravelCore

public enum PostcardFace: String, CaseIterable, Sendable {
    case message = "文字面"
    case scenic = "风景面"

    public static func initial(isUnread: Bool, hasScenery: Bool = true) -> Self {
        isUnread || !hasScenery ? .message : .scenic
    }

    public static func hasScenery(for event: TripEvent) -> Bool {
        event.postcardStatus == .ready && !(event.postcardRelativePath ?? "").isEmpty
    }
}

@MainActor
struct PostcardTwoSidedView: View {
    let event: TripEvent
    let rootURL: URL?
    let recipient: PostcardRecipientInfo
    let travelDate: Date?
    let homeLocation: HomeLocation?
    let isUnread: Bool
    let onSceneryDisplayed: ((String) -> Void)?
    @Binding var face: PostcardFace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flipAnimation = PostcardFlipAnimation()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: flip) {
                Group {
                    if face == .message {
                        messageFace
                    } else {
                        PostcardScenicFaceView(event: event, rootURL: rootURL, profile: .detail,
                            onImageVisible: sceneryVisibilityHandler)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                .rotation3DEffect(.degrees(flipAnimation.isUnfolding ? 180 : 0),
                    axis: (x: 0, y: 1, z: 0), perspective: 0)
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
                .aspectRatio(1.5, contentMode: .fit)
                .rotation3DEffect(.degrees(flipAnimation.angle), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canFlip)
            .allowsHitTesting(!flipAnimation.isTurning)
            .accessibilityIdentifier("postcard.flip.card")
            .accessibilityValue(flipAnimation.isTurning ? "正在翻面" : face.rawValue)
            .accessibilityLabel(face == .message ? messageFace.completeAccessibilityLabel
                : "风景面，" + PostcardArtworkView.accessibilityText(event: event) + "，翻回文字面")
            HStack {
                Text(face.rawValue).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: flip) {
                    Label(face == .message ? "翻看风景" : "翻回文字面", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .disabled(!canFlip || flipAnimation.isTurning)
            }
            if !PostcardFace.hasScenery(for: event) {
                Text(event.postcardStatus == .pendingImage ? "风景图片正在准备，文字面可以先读。" : "风景图片暂时不可用，文字面已保留。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear { cancelTurn() }
        .onChange(of: event.id) { _, _ in cancelTurn() }
        .onChange(of: rootURL) { _, _ in cancelTurn() }
        .onChange(of: event.postcardStatus) { _, _ in cancelTurn() }
        .onChange(of: event.postcardRelativePath) { _, _ in cancelTurn() }
        .onChange(of: face) { _, newFace in
            if flipAnimation.isTurning && newFace != flipAnimation.expectedFace { cancelTurn() }
        }
        .onChange(of: reduceMotion) { _, _ in cancelTurn() }
    }

    private var messageFace: PostcardMessageFaceView {
        PostcardMessageFaceView(event: event, recipient: recipient, travelDate: travelDate,
            isUnread: isUnread, homeLocation: homeLocation)
    }

    private var canFlip: Bool {
        face == .scenic || PostcardFace.hasScenery(for: event)
    }

    private var sceneryVisibilityHandler: ((String) -> Void)? {
        guard !flipAnimation.isTurning, let onSceneryDisplayed else { return nil }
        let currentFace = $face
        return flipAnimation.visibilityHandler(face: { currentFace.wrappedValue }, onVisible: onSceneryDisplayed)
    }

    private func flip() {
        if reduceMotion {
            guard let target = flipAnimation.immediateFace(from: face, event: event) else { return }
            withoutAnimation { face = target }
            return
        }
        guard let turn = flipAnimation.begin(from: face, event: event) else { return }
        withAnimation(.easeIn(duration: 0.24), completionCriteria: .removed) {
            flipAnimation.angle = 90
        } completion: {
            var target: PostcardFace?
            withoutAnimation {
                target = flipAnimation.reveal(turn)
                if let target { face = target }
            }
            guard target != nil else { return }
            withAnimation(.easeOut(duration: 0.28), completionCriteria: .removed) {
                // Keep the outer angle continuous; the new face has a fixed
                // half-turn compensation so its lettering is never mirrored.
                flipAnimation.angle = 180
            } completion: {
                withoutAnimation { flipAnimation.finish(turn) }
            }
        }
    }

    private func cancelTurn() {
        withoutAnimation { flipAnimation.cancel() }
    }

    private func withoutAnimation(_ changes: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, changes)
    }
}
