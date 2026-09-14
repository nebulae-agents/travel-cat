import Combine
import Foundation
import TravelCore

public enum PetPresentation: Equatable, Sendable {
    case pet
    case awayTag
    case status
    case postcard(UUID)
    case album(UUID)
    case supplies
}

public enum AppModelError: Error, Equatable, Sendable {
    case catIsAway
    case unknownSupply(String)
}

@MainActor
public final class AppModel: ObservableObject {
    public typealias SupplyPersistence = @MainActor (String?) throws -> TripSnapshot
    @Published public private(set) var snapshot: TripSnapshot
    @Published public private(set) var events: [TripEvent]
    @Published public private(set) var unreadPostcardIDs: [UUID]
    @Published public private(set) var readPostcardIDs: [UUID]
    @Published public private(set) var presentation: PetPresentation
    @Published public private(set) var supplyErrorMessage: String?
    @Published public private(set) var characterProfile: CharacterProfile

    public let supplies: [Supply]
    public let dataRoot: URL?

    private let defaults: UserDefaults
    private let readDefaultsKey: String
    private let persistSupply: SupplyPersistence?
    private let clock: () -> Date
    private var postcardReturnPresentation = PetPresentation.status

    public init(
        snapshot: TripSnapshot,
        events: [TripEvent] = [],
        dataRoot: URL? = nil,
        defaults: UserDefaults = .standard,
        supplies: [Supply] = SupplyCatalog.loadOrEmpty(),
        characterProfile: CharacterProfile = .defaultBlackCat,
        persistSupply: SupplyPersistence? = nil,
        clock: @escaping () -> Date = Date.init
    ) {
        self.snapshot = snapshot
        self.events = events
        self.dataRoot = dataRoot
        self.defaults = defaults
        self.supplies = supplies
        self.characterProfile = characterProfile
        self.persistSupply = persistSupply
        self.clock = clock
        readDefaultsKey = Self.readDefaultsScopeKey(dataRoot: dataRoot)
        let storedIDs = defaults.stringArray(forKey: readDefaultsKey) ?? []
        readPostcardIDs = storedIDs.compactMap(UUID.init(uuidString:))
        unreadPostcardIDs = []
        supplyErrorMessage = nil
        presentation = Self.basePresentation(snapshot.phase)
        refreshUnread()
    }

    public static func basePresentation(_ phase: TravelPhase) -> PetPresentation {
        switch phase {
        case .resting, .preparing:
            .pet
        case .transit, .exploring, .postcardReady, .returning:
            .awayTag
        }
    }

    public var basePresentation: PetPresentation {
        Self.basePresentation(snapshot.phase)
    }

    public var nextUnreadPostcardID: UUID? {
        unreadPostcardIDs.first
    }

    public func apply(next: TripSnapshot, events: [TripEvent], characterProfile: CharacterProfile? = nil) {
        guard next.stateVersion >= snapshot.stateVersion else { return }
        let wasBase = presentation == basePresentation
        if next.stateVersion > snapshot.stateVersion {
            snapshot = next
        } else if next.stateVersion == snapshot.stateVersion {
            var normalized = next
            normalized.carriedItemID = snapshot.carriedItemID
            if normalized == snapshot {
                snapshot.carriedItemID = next.carriedItemID
            }
        }
        self.events = events
        if let characterProfile { self.characterProfile = characterProfile }
        refreshUnread()
        let arrived = arrivedEvents()
        if wasBase {
            presentation = basePresentation
            return
        }
        switch presentation {
        case let .postcard(id):
            if !arrived.contains(where: { $0.id == id && isPostcard($0) }) {
                presentation = .status
                postcardReturnPresentation = .status
            }
        case let .album(tripID):
            if !arrived.contains(where: { $0.tripID == tripID && isAlbumEvent($0) }) {
                presentation = .status
            }
        case .supplies:
            if basePresentation == .awayTag { presentation = .awayTag }
        case .status, .pet, .awayTag:
            break
        }
    }

    public func replaceAfterHistoryClear(next: TripSnapshot, events: [TripEvent], characterProfile: CharacterProfile? = nil) {
        snapshot = next
        self.events = events
        if let characterProfile { self.characterProfile = characterProfile }
        refreshUnread()
        postcardReturnPresentation = .status
        presentation = basePresentation
    }

    /// Accepts route intents from views, but only when the current presentation permits them.
    public func handle(_ requested: PetPresentation) {
        switch requested {
        case .status:
            guard presentation == basePresentation else { return }
            presentation = .status
        case let .postcard(id):
            guard let event = arrivedEvents().first(where: { $0.id == id }),
                  isPostcard(event) else { return }
            let allowedFromStatus = presentation == .status && id == nextUnreadPostcardID
            let allowedFromAlbum: Bool
            if case .album = presentation {
                allowedFromAlbum = true
            } else {
                allowedFromAlbum = false
            }
            guard allowedFromStatus || allowedFromAlbum else { return }
            postcardReturnPresentation = allowedFromAlbum ? presentation : .status
            markRead(id)
            presentation = .postcard(id)
        case let .album(tripID):
            guard case let .postcard(eventID) = presentation,
                  events.first(where: { $0.id == eventID })?.tripID == tripID else { return }
            presentation = .album(tripID)
        case .supplies:
            guard presentation == basePresentation else { return }
            presentation = .supplies
        case .pet, .awayTag:
            break
        }
    }

    public func openNextPostcardOrBase() {
        guard presentation == .status else { return }
        guard let id = nextUnreadPostcardID else {
            presentation = basePresentation
            return
        }
        handle(.postcard(id))
    }

    public func openAlbumForCurrentPostcard() {
        guard case let .postcard(eventID) = presentation,
              let tripID = events.first(where: { $0.id == eventID })?.tripID else { return }
        handle(.album(tripID))
    }

    public func latestAvailableTripID() -> UUID? {
        latestAvailablePostcardID()?.tripID
    }

    private func latestAvailablePostcardID() -> TripEvent? {
        arrivedEvents().enumerated()
            .filter { isAlbumEvent($0.element) }
            .max {
                if $0.element.occurredAt != $1.element.occurredAt {
                    return $0.element.occurredAt < $1.element.occurredAt
                }
                return $0.offset < $1.offset
            }?
            .element
    }

    public func openLatestAlbumFromStatus() {
        guard presentation == .status, let tripID = latestAvailableTripID() else { return }
        presentation = .album(tripID)
    }

    public func openStatusFromMenu() {
        postcardReturnPresentation = .status
        presentation = .status
    }

    public func openLatestPostcardFromMenu() {
        openStatusFromMenu()
        guard let id = latestAvailablePostcardID()?.id else { return }
        markRead(id)
        presentation = .postcard(id)
    }

    public func openLatestAlbumFromMenu() {
        openStatusFromMenu()
        guard let tripID = latestAvailableTripID() else { return }
        presentation = .album(tripID)
    }

    @discardableResult
    public func openPostcardFromPrompt(
        eventID: UUID,
        tripID: UUID
    ) -> Bool {
        postcardReturnPresentation = .status
        presentation = .status
        let matchingEvents = arrivedEvents().filter { $0.id == eventID }
        guard matchingEvents.count == 1,
              let event = matchingEvents.first,
              event.tripID == tripID,
              event.postcardStatus == .ready else { return false }
        markRead(eventID)
        presentation = .postcard(eventID)
        return true
    }

    @discardableResult
    public func openAlbumFromPrompt(
        tripID: UUID
    ) -> Bool {
        postcardReturnPresentation = .status
        presentation = .status
        guard arrivedEvents().contains(where: {
            guard $0.tripID == tripID else { return false }
            return isPromptAlbumEvent($0)
        }) else { return false }
        presentation = .album(tripID)
        return true
    }

    public func close() {
        switch presentation {
        case .postcard:
            presentation = postcardReturnPresentation
            postcardReturnPresentation = .status
        case .album:
            presentation = .status
        case .status, .supplies:
            presentation = basePresentation
        case .pet, .awayTag:
            break
        }
    }

    public func selectSupply(_ id: String?) throws {
        guard snapshot.phase == .resting || snapshot.phase == .preparing else {
            throw AppModelError.catIsAway
        }
        if let id, !supplies.contains(where: { $0.id == id }) {
            throw AppModelError.unknownSupply(id)
        }
        if let persistSupply {
            do {
                snapshot = try persistSupply(id)
                supplyErrorMessage = nil
            } catch {
                supplyErrorMessage = String(describing: error)
                throw error
            }
        } else {
            snapshot.carriedItemID = id
            supplyErrorMessage = nil
        }
    }

    private func refreshUnread() {
        let read = Set(readPostcardIDs)
        unreadPostcardIDs = arrivedEvents().enumerated()
            .filter {
                isAlbumEvent($0.element) && !read.contains($0.element.id)
            }
            .sorted {
                if $0.element.occurredAt != $1.element.occurredAt {
                    return $0.element.occurredAt < $1.element.occurredAt
                }
                return $0.offset < $1.offset
            }
            .map(\.element.id)
    }

    private func isPostcard(_ event: TripEvent) -> Bool {
        switch event.postcardStatus {
        case .pendingImage, .ready, .imageUnavailable:
            true
        case .none, .rejected:
            false
        }
    }

    private func isAlbumEvent(_ event: TripEvent) -> Bool {
        isPostcard(event)
    }

    private func isPromptAlbumEvent(_ event: TripEvent) -> Bool {
        switch event.postcardStatus {
        case .ready, .imageUnavailable:
            true
        case .pendingImage, .none, .rejected:
            false
        }
    }

    private func arrivedEvents() -> [TripEvent] {
        let now = clock()
        return events.filter { $0.occurredAt <= now }
    }

    private func markRead(_ id: UUID) {
        guard !readPostcardIDs.contains(id) else { return }
        readPostcardIDs.append(id)
        defaults.set(readPostcardIDs.map(\.uuidString), forKey: readDefaultsKey)
        refreshUnread()
    }

    nonisolated public static func readDefaultsScopeKey(dataRoot: URL?) -> String {
        let scope = dataRoot?
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path ?? "preview"
        let encoded = Data(scope.utf8).base64EncodedString()
        return "travel-cat.read-postcard-ids.\(encoded)"
    }
}
