import SwiftUI
import TravelCore

public enum PostcardLibraryFilter: String, CaseIterable, Sendable {
    case all = "全部", unread = "未读", favourites = "收藏"
}

public enum PostcardLibrary {
    public static func isSealed(_ event: TripEvent, unreadIDs: Set<UUID>) -> Bool {
        guard unreadIDs.contains(event.id) else { return false }
        switch event.postcardStatus {
        case .ready, .pendingImage, .imageUnavailable: return true
        case .none, .rejected: return false
        }
    }

    public static func matches(_ event: TripEvent, filter: PostcardLibraryFilter, query: String,
                               unreadIDs: Set<UUID>, favouriteIDs: Set<UUID>) -> Bool {
        if filter == .unread && !unreadIDs.contains(event.id) { return false }
        if filter == .favourites && !favouriteIDs.contains(event.id) { return false }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        // A search never reveals a sealed card's narrative or photo.
        return PostcardDisplayLocation().resolveSpoken(event.location).localizedStandardContains(query)
    }
}

/// Compatibility entry point for album thumbnails that previously showed an envelope.
public struct PostcardEnvelopeView: View {
    public static let aspectRatio = PostcardMessageFaceView.aspectRatio
    public let event: TripEvent
    public let recipient: PostcardRecipientInfo
    public let travelDate: Date?
    public let isUnread: Bool
    public let homeLocation: HomeLocation?

    public init(event: TripEvent, recipient: PostcardRecipientInfo = .empty, travelDate: Date? = nil, isUnread: Bool = true, homeLocation: HomeLocation? = nil) {
        self.event = event
        self.recipient = recipient
        self.travelDate = travelDate
        self.isUnread = isUnread
        self.homeLocation = homeLocation
    }

    public var body: some View {
        PostcardMessageFaceView(event: event, recipient: recipient, travelDate: travelDate, isUnread: isUnread, homeLocation: homeLocation)
    }
}
