import Darwin
import Foundation
import ImageIO
import TravelCore
@testable import TravelStorage

/// Test-only JSONL contract for deterministic offline journeys.
///
/// Every non-empty line is exactly one action. The first action must be metadata;
/// later actions are immutable event publications or terminal image-state updates.
/// An image update never republishes a `TripEvent` and therefore never advances the
/// snapshot version. Delays are represented by a timestamp later than the fast
/// scheduler's deterministic two-minute `nextActionAt`.
enum FastTripAction: Equatable {
    case metadata(FastTripMetadata)
    case event(TripEvent, materializeFixtureImage: Bool)
    case imageUpdate(FastTripImageUpdate)
}

struct FastTripMetadata: Codable, Equatable {
    let type: String
    let name: String
    let seed: UInt64
    let expectedEventCount: Int
    let expectedPostcardCount: Int
    let expectedDelayCount: Int
    let carriedItemID: String?
}

struct FastTripImageUpdate: Codable, Equatable {
    let type: String
    let eventID: UUID
    let status: PostcardStatus
    let postcardRelativePath: String?
    let materializeFixtureImage: Bool?
}

struct FastTripFixture: Equatable {
    struct LocatedAction: Equatable {
        let line: Int
        let action: FastTripAction
    }

    let metadata: FastTripMetadata
    let actions: [LocatedAction]
    let sourceURL: URL
}

enum FastTripFixtureError: Error, Equatable, CustomStringConvertible {
    case diagnostic(String)

    var description: String {
        switch self {
        case let .diagnostic(message): message
        }
    }
}

enum FixtureLoader {
    private struct TypeProbe: Decodable { let type: String }
    private struct EventAction: Decodable {
        let type: String
        let event: TripEvent
        let materializeFixtureImage: Bool?
    }

    static func fastTrips() throws -> [FastTripFixture] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try (1...3).map { number in
            let url = root.appendingPathComponent("Fixtures/trips/fast-trip-\(number).jsonl")
            return try load(data: Data(contentsOf: url), named: "fast-trip-\(number)", sourceURL: url)
        }
    }

    static func load(data: Data, named name: String, sourceURL: URL? = nil) throws -> FastTripFixture {
        guard let text = String(data: data, encoding: .utf8) else {
            throw FastTripFixtureError.diagnostic("line 1: fixture is not UTF-8")
        }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n") { lines.removeLast() }
        guard !lines.isEmpty else {
            throw FastTripFixtureError.diagnostic("line 1: metadata action is required")
        }

        var located: [FastTripFixture.LocatedAction] = []
        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                throw FastTripFixtureError.diagnostic("line \(lineNumber): blank action")
            }
            let lineData = Data(line.utf8)
            let probe: TypeProbe
            do {
                probe = try JSONDecoder.travelCat.decode(TypeProbe.self, from: lineData)
            } catch {
                throw FastTripFixtureError.diagnostic("line \(lineNumber): malformed action: \(error)")
            }

            let action: FastTripAction
            do {
                switch probe.type {
                case "metadata":
                    let value = try JSONDecoder.travelCat.decode(FastTripMetadata.self, from: lineData)
                    action = .metadata(value)
                case "event":
                    let value = try JSONDecoder.travelCat.decode(EventAction.self, from: lineData)
                    action = .event(value.event, materializeFixtureImage: value.materializeFixtureImage ?? false)
                case "imageUpdate":
                    let value = try JSONDecoder.travelCat.decode(FastTripImageUpdate.self, from: lineData)
                    action = .imageUpdate(value)
                default:
                    throw FastTripFixtureError.diagnostic("line \(lineNumber): unknown action type '\(probe.type)'")
                }
            } catch let error as FastTripFixtureError {
                throw error
            } catch {
                throw FastTripFixtureError.diagnostic("line \(lineNumber): malformed action: \(error)")
            }
            located.append(.init(line: lineNumber, action: action))
        }

        guard case let .metadata(metadata) = located[0].action else {
            throw FastTripFixtureError.diagnostic("line 1: first action must be metadata")
        }
        guard metadata.type == "metadata", metadata.name == name else {
            throw FastTripFixtureError.diagnostic("line 1: metadata name must equal fixture name '\(name)'")
        }
        for action in located.dropFirst() {
            if case .metadata = action.action {
                throw FastTripFixtureError.diagnostic("line \(action.line): metadata action is only allowed first")
            }
        }

        return FastTripFixture(
            metadata: metadata,
            actions: located,
            sourceURL: sourceURL ?? URL(fileURLWithPath: "/inline/\(name).jsonl")
        )
    }
}

struct FastTripDelayGap: Equatable {
    let delayedEventID: UUID
    let lateBySeconds: Int
}

struct FastTripPostcardEvidence: Equatable {
    let eventID: UUID
    var statusHistory: [PostcardStatus]

    var terminalStatus: PostcardStatus? {
        statusHistory.last.flatMap { [.ready, .imageUnavailable, .rejected].contains($0) ? $0 : nil }
    }
}

struct FastTripImageUpdateEvidence: Equatable {
    let eventID: UUID
    let beforeStatus: PostcardStatus
    let afterStatus: PostcardStatus
    let relativePath: String?
    let stateVersionBefore: Int
    let stateVersionAfter: Int
    let eventCountBefore: Int
    let eventCountAfter: Int
    let completeImmutableEventUnchanged: Bool
}

struct FastTripReadyImageEvidence: Equatable {
    let eventID: UUID
    let relativePath: String
    let width: Int
    let height: Int
    let isRegularFile: Bool
}

struct FastTripAcceptanceResult: Equatable {
    let finalSnapshot: TripSnapshot
    let duplicateEventIDs: [UUID]
    let continuityViolations: [String]
    let postcards: [FastTripPostcardEvidence]
    let delayGaps: [FastTripDelayGap]
    let imageUpdates: [FastTripImageUpdateEvidence]
    let interestingPlaces: [String]
    let repositoryContents: RepositoryContents
    let idempotentRetryVerified: Bool
    let idempotentlyRetriedEventIDs: [UUID]
    let readyImages: [FastTripReadyImageEvidence]
    var temporaryRootRemoved: Bool
}

private final class FastTripClock: TravelClock, @unchecked Sendable {
    var now: Date
    init(now: Date) { self.now = now }
}

struct FastTripRunner {
    func run(_ fixture: FastTripFixture) throws -> FastTripAcceptanceResult {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("travel-cat-fast-trip-\(fixture.metadata.name)-\(UUID().uuidString)", isDirectory: true)
        do {
            var result = try execute(fixture, root: root)
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                throw diagnostic(action: fixture.actions.count, "temporary root cleanup failed: \(error)")
            }
            guard !FileManager.default.fileExists(atPath: root.path) else {
                throw diagnostic(action: fixture.actions.count, "temporary root still exists after cleanup")
            }
            result.temporaryRootRemoved = true
            return result
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func execute(_ fixture: FastTripFixture, root: URL) throws -> FastTripAcceptanceResult {
        let eventActions = fixture.actions.compactMap { located -> (Int, TripEvent)? in
            guard case let .event(event, _) = located.action else { return nil }
            return (located.line, event)
        }
        guard let firstEvent = eventActions.first?.1 else {
            throw diagnostic(action: 1, "fixture contains no events")
        }

        let clock = FastTripClock(now: firstEvent.occurredAt)
        let repository = try TravelRepository(root: root, clock: clock)
        if let carriedItemID = fixture.metadata.carriedItemID {
            _ = try repository.updateCarriedItem(carriedItemID)
        }

        var snapshot = TripSnapshot.empty(now: firstEvent.occurredAt)
        snapshot.carriedItemID = fixture.metadata.carriedItemID
        var seen = Set<UUID>()
        var duplicateIDs: [UUID] = []
        var continuityMessages: [String] = []
        var postcards: [FastTripPostcardEvidence] = []
        var delays: [FastTripDelayGap] = []
        var imageUpdates: [FastTripImageUpdateEvidence] = []
        var lastEvent: TripEvent?
        var stableTripID: UUID?
        var retriedEventIDs: [UUID] = []

        for (actionIndex, located) in fixture.actions.enumerated() {
            let displayIndex = actionIndex + 1
            switch located.action {
            case .metadata:
                continue
            case let .event(event, materializeFixtureImage):
                guard seen.insert(event.id).inserted else {
                    duplicateIDs.append(event.id)
                    throw diagnostic(action: displayIndex, "duplicate event ID \(event.id.uuidString)")
                }
                guard event.previousEventID == lastEvent?.id else {
                    throw diagnostic(action: displayIndex, "broken previousEventID; expected \(lastEvent?.id.uuidString ?? "null")")
                }
                if let lastEvent, event.occurredAt <= lastEvent.occurredAt {
                    throw diagnostic(action: displayIndex, "timestamp must be strictly monotonic")
                }
                do {
                    try TravelStateMachine().requireTransition(from: snapshot.phase, to: event.phase)
                } catch {
                    throw diagnostic(action: displayIndex, "illegal transition \(snapshot.phase.rawValue) -> \(event.phase.rawValue)")
                }
                if stableTripID == nil { stableTripID = event.tripID }
                guard stableTripID == event.tripID else {
                    throw diagnostic(action: displayIndex, "trip ID changed before resting end")
                }

                let violations = ContinuityValidator().violations(event: event, previous: snapshot)
                if let violation = violations.first {
                    let message = continuityDescription(violation)
                    continuityMessages.append(message)
                    throw diagnostic(action: displayIndex, "continuity violation \(message)")
                }
                if let previous = lastEvent {
                    let scheduled = TripScheduler(mode: .fast).nextDeparture(
                        after: previous.occurredAt,
                        seed: fixture.metadata.seed &+ UInt64(snapshot.stateVersion),
                        calendar: fixedCalendar()
                    )
                    if event.occurredAt > scheduled {
                        delays.append(.init(delayedEventID: event.id, lateBySeconds: Int(event.occurredAt.timeIntervalSince(scheduled))))
                    }
                }

                if event.postcardStatus == .ready {
                    guard isSafePostcardPath(event.postcardRelativePath, required: true) else {
                        throw diagnostic(action: displayIndex, "unsafe postcard path")
                    }
                    guard materializeFixtureImage, let path = event.postcardRelativePath else {
                        throw diagnostic(action: displayIndex, "ready postcard requires materializeFixtureImage")
                    }
                    let imageURL = root.appendingPathComponent("postcards/\(path)")
                    try writeMinimalPNG(at: imageURL)
                    _ = try Self.validateReadyImage(at: imageURL)
                }

                snapshot = try deriveSnapshot(
                    previous: snapshot,
                    event: event,
                    seed: fixture.metadata.seed &+ UInt64(snapshot.stateVersion)
                )
                clock.now = event.occurredAt
                try repository.publish(event: event, next: snapshot)
                let beforeRetry = try repository.loadContents()
                let acknowledged = try repository.publish(event: event, next: snapshot)
                let afterRetry = try repository.loadContents()
                guard acknowledged == beforeRetry.snapshot.stateVersion,
                      afterRetry == beforeRetry else {
                    throw diagnostic(action: displayIndex, "idempotent retry advanced or mutated repository state")
                }
                retriedEventIDs.append(event.id)
                if event.postcardStatus != .none {
                    postcards.append(.init(eventID: event.id, statusHistory: [event.postcardStatus]))
                }
                lastEvent = event

            case let .imageUpdate(update):
                guard let targetIndex = postcards.firstIndex(where: { $0.eventID == update.eventID }),
                      postcards[targetIndex].statusHistory.last == .pendingImage else {
                    throw diagnostic(action: displayIndex, "image update requires pendingImage event \(update.eventID.uuidString)")
                }
                guard [.ready, .imageUnavailable, .rejected].contains(update.status) else {
                    throw diagnostic(action: displayIndex, "image update status must be terminal")
                }
                guard isSafePostcardPath(update.postcardRelativePath, required: update.status == .ready) else {
                    throw diagnostic(action: displayIndex, "unsafe postcard path")
                }

                let before = try repository.loadContents()
                let beforeEvent = try requiredEvent(update.eventID, in: before.events, action: displayIndex)
                if update.status == .ready, let path = update.postcardRelativePath {
                    guard update.materializeFixtureImage == true else {
                        throw diagnostic(action: displayIndex, "ready postcard requires materializeFixtureImage")
                    }
                    let imageURL = root.appendingPathComponent(path)
                    try writeMinimalPNG(at: imageURL)
                    _ = try Self.validateReadyImage(at: imageURL)
                }
                let attemptedAt = beforeEvent.occurredAt.addingTimeInterval(1)
                clock.now = attemptedAt
                switch update.status {
                case .ready:
                    let work = try requiredPendingImage(repository, eventID: update.eventID, now: attemptedAt)
                    _ = try repository.markImage(.init(
                        eventId: update.eventID,
                        status: .ready,
                        attemptedAt: attemptedAt,
                        relativePath: update.postcardRelativePath,
                        reason: nil,
                        attemptToken: work.attemptToken,
                        attemptCount: work.imageAttemptCount,
                        publishedNarrativeHash: work.publishedNarrativeHash
                    ), mode: .fast)
                case .imageUnavailable, .rejected:
                    for offset in [0.0, 60.0, 180.0] {
                        let attemptTime = attemptedAt.addingTimeInterval(offset)
                        clock.now = attemptTime
                        let work = try requiredPendingImage(repository, eventID: update.eventID, now: attemptTime)
                        _ = try repository.markImage(.init(
                            eventId: update.eventID,
                            status: update.status == .rejected ? .rejectedIdentity : .failed,
                            attemptedAt: attemptTime,
                            relativePath: nil,
                            reason: "offline fixture",
                            attemptToken: work.attemptToken,
                            attemptCount: work.imageAttemptCount,
                            publishedNarrativeHash: work.publishedNarrativeHash
                        ), mode: .fast)
                    }
                case .none, .pendingImage:
                    throw diagnostic(action: displayIndex, "image update status must be terminal")
                }
                let after = try repository.loadContents()
                let afterEvent = try requiredEvent(update.eventID, in: after.events, action: displayIndex)
                guard before.snapshot == after.snapshot, before.events.count == after.events.count else {
                    throw diagnostic(action: displayIndex, "image update advanced event or snapshot state")
                }
                let immutable = Self.completeEventIsImmutable(before: beforeEvent, afterImageUpdate: afterEvent)
                guard immutable else {
                    throw diagnostic(action: displayIndex, "image update changed immutable event fields")
                }
                postcards[targetIndex].statusHistory.append(update.status)
                imageUpdates.append(.init(
                    eventID: update.eventID,
                    beforeStatus: beforeEvent.postcardStatus,
                    afterStatus: afterEvent.postcardStatus,
                    relativePath: afterEvent.postcardRelativePath,
                    stateVersionBefore: before.snapshot.stateVersion,
                    stateVersionAfter: after.snapshot.stateVersion,
                    eventCountBefore: before.events.count,
                    eventCountAfter: after.events.count,
                    completeImmutableEventUnchanged: immutable
                ))
            }
        }

        guard snapshot.phase == .resting else {
            throw diagnostic(action: fixture.actions.count, "journey must end resting")
        }
        guard snapshot.stateVersion == fixture.metadata.expectedEventCount else {
            throw diagnostic(action: 1, "expected \(fixture.metadata.expectedEventCount) events, found \(snapshot.stateVersion)")
        }
        guard postcards.count == fixture.metadata.expectedPostcardCount else {
            throw diagnostic(action: 1, "expected \(fixture.metadata.expectedPostcardCount) postcards, found \(postcards.count)")
        }
        guard delays.count == fixture.metadata.expectedDelayCount else {
            throw diagnostic(action: 1, "expected \(fixture.metadata.expectedDelayCount) delays, found \(delays.count)")
        }
        guard postcards.allSatisfy({ $0.terminalStatus != nil }) else {
            throw diagnostic(action: fixture.actions.count, "all postcards must reach a terminal status")
        }

        let contents = try TravelRepository(root: root).loadContents()
        guard contents.snapshot == snapshot else {
            throw diagnostic(action: fixture.actions.count, "reloaded snapshot does not match derived snapshot")
        }
        var places: [String] = []
        for (_, event) in eventActions where event.phase == .exploring || event.phase == .postcardReady {
            if let place = event.location?.place, !places.contains(place) {
                places.append(place)
            }
        }
        var readyImages: [FastTripReadyImageEvidence] = []
        for event in contents.events where event.postcardStatus == .ready {
            guard let path = event.postcardRelativePath,
                  isSafePostcardPath(path, required: true) else {
                throw diagnostic(action: fixture.actions.count, "ready postcard has unsafe or missing path")
            }
            let imageURL = path.hasPrefix("postcards/")
                ? root.appendingPathComponent(path)
                : root.appendingPathComponent("postcards/\(path)")
            let inspection = try Self.validateReadyImage(at: imageURL)
            readyImages.append(.init(
                eventID: event.id,
                relativePath: path,
                width: inspection.width,
                height: inspection.height,
                isRegularFile: inspection.isRegularFile
            ))
        }

        return FastTripAcceptanceResult(
            finalSnapshot: snapshot,
            duplicateEventIDs: duplicateIDs,
            continuityViolations: continuityMessages,
            postcards: postcards,
            delayGaps: delays,
            imageUpdates: imageUpdates,
            interestingPlaces: places,
            repositoryContents: contents,
            idempotentRetryVerified: retriedEventIDs.count == eventActions.count,
            idempotentlyRetriedEventIDs: retriedEventIDs,
            readyImages: readyImages,
            temporaryRootRemoved: false
        )
    }

    private func requiredPendingImage(_ repository: TravelRepository, eventID: UUID, now: Date) throws -> PendingImageWork {
        guard let work = try repository.pendingImages(now: now).first(where: { $0.event.id == eventID }) else {
            throw diagnostic(action: 0, "missing due image attempt for \(eventID.uuidString)")
        }
        return work
    }

    private func deriveSnapshot(previous: TripSnapshot, event: TripEvent, seed: UInt64) throws -> TripSnapshot {
        var usedItems = previous.usedItemIDs
        var carriedItemID = previous.carriedItemID
        if let itemID = event.consumedItemID {
            guard carriedItemID == itemID else {
                throw FastTripFixtureError.diagnostic("consumed item '\(itemID)' is not carried")
            }
            usedItems.insert(itemID)
            carriedItemID = nil
        }
        var visited = previous.visitedPlaces
        if let place = event.location?.place { visited.append(place) }
        let nextActionAt = TripScheduler(mode: .fast).nextDeparture(
            after: event.occurredAt,
            seed: seed,
            calendar: fixedCalendar()
        )
        return TripSnapshot(
            stateVersion: previous.stateVersion + 1,
            tripID: event.tripID,
            lastEventID: event.id,
            phase: event.phase,
            nextActionAt: nextActionAt,
            lastUpdatedAt: event.occurredAt,
            carriedItemID: carriedItemID,
            usedItemIDs: usedItems,
            visitedPlaces: visited,
            mood: event.mood,
            openHook: event.openHook
        )
    }

    private func continuityDescription(_ violation: ContinuityValidator.Violation) -> String {
        switch violation {
        case .moodJump: "moodJump"
        case let .itemAlreadyConsumed(id): "itemAlreadyConsumed(\(id))"
        case .missingAnchorReference: "missingAnchorReference"
        case .repeatedPlace: "repeatedPlace"
        }
    }

    private func diagnostic(action: Int, _ message: String) -> FastTripFixtureError {
        .diagnostic("action \(action): \(message)")
    }

    private func fixedCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func isSafePostcardPath(_ path: String?, required: Bool) -> Bool {
        if required, path == nil { return false }
        guard let path else { return true }
        return !path.isEmpty
            && !NSString(string: path).isAbsolutePath
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private func requiredEvent(_ id: UUID, in events: [TripEvent], action: Int) throws -> TripEvent {
        guard let event = events.first(where: { $0.id == id }) else {
            throw diagnostic(action: action, "image update event not found")
        }
        return event
    }

    static func completeEventIsImmutable(before: TripEvent, afterImageUpdate after: TripEvent) -> Bool {
        var normalized = after
        normalized.postcardStatus = before.postcardStatus
        normalized.postcardRelativePath = before.postcardRelativePath
        return normalized == before
    }

    struct ReadyImageInspection: Equatable {
        let width: Int
        let height: Int
        let isRegularFile: Bool
    }

    static func validateReadyImage(at url: URL) throws -> ReadyImageInspection {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw FastTripFixtureError.diagnostic("ready postcard image must be a real regular file")
        }
        let allowedExtensions = ["png", "webp"]
        guard allowedExtensions.contains(url.pathExtension.lowercased()),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sourceType = CGImageSourceGetType(source) as String?,
              sourceType.lowercased().contains("png") || sourceType.lowercased().contains("webp"),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw FastTripFixtureError.diagnostic("ready postcard image must be a decodable PNG/WebP")
        }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            throw FastTripFixtureError.diagnostic("ready postcard image dimensions must be nonzero")
        }
        return .init(width: width, height: height, isRegularFile: true)
    }

    private func writeMinimalPNG(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let context = CGContext(
            data: nil, width: 768, height: 768, bitsPerComponent: 8, bytesPerRow: 768 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw FastTripFixtureError.diagnostic("could not materialize fixture PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FastTripFixtureError.diagnostic("could not finalize fixture PNG")
        }
    }
}
