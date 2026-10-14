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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if face == .message {
                    PostcardMessageFaceView(event: event, recipient: recipient, travelDate: travelDate, isUnread: isUnread, homeLocation: homeLocation)
                } else {
                    PostcardScenicFaceView(event: event, rootURL: rootURL, profile: .detail,
                        onImageVisible: onSceneryDisplayed)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .aspectRatio(1.5, contentMode: .fit)
            .transition(.opacity)
            HStack {
                Text(face.rawValue).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        face = face == .message ? .scenic : .message
                    }
                } label: {
                    Label(face == .message ? "翻看风景" : "翻回文字面", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .disabled(face == .message && !PostcardFace.hasScenery(for: event))
            }
            if !PostcardFace.hasScenery(for: event) {
                Text(event.postcardStatus == .pendingImage ? "风景图片正在准备，文字面可以先读。" : "风景图片暂时不可用，文字面已保留。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
