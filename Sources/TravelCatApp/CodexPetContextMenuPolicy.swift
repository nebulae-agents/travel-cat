import CoreGraphics

enum CodexPetPointerEventType: Equatable {
    case leftMouseDown
    case rightMouseDown
    case other

    init(_ eventType: CGEventType) {
        switch eventType {
        case .leftMouseDown:
            self = .leftMouseDown
        case .rightMouseDown:
            self = .rightMouseDown
        default:
            self = .other
        }
    }
}

struct CodexPetContextMenuInput: Equatable {
    let eventType: CodexPetPointerEventType
    let point: CGPoint
    let petBounds: CGRect?
    let permissionsGranted: Bool
    let bypassNextRightClick: Bool
}

enum CodexPetContextMenuDecision: Equatable {
    case intercept
    case passThrough
    case ignore
}

enum CodexPetContextMenuPolicy {
    static func decision(_ input: CodexPetContextMenuInput) -> CodexPetContextMenuDecision {
        guard input.eventType == .rightMouseDown else { return .ignore }
        guard input.permissionsGranted else { return .passThrough }
        guard !input.bypassNextRightClick else { return .passThrough }
        guard let petBounds = input.petBounds else { return .passThrough }
        guard petBounds.contains(input.point) else { return .passThrough }
        return .intercept
    }
}

enum TravelCatPetMenuAction: Equatable {
    case currentJourney
    case latestPostcard
    case album
    case temporaryTest
    case closePet
}

enum TravelCatPetMenuItem: Equatable {
    case action(TravelCatPetMenuAction, enabled: Bool)
    case separator
}

struct TravelCatPetMenuState: Equatable {
    let hasLatestPostcard: Bool
    let hasLatestAlbum: Bool
    let isFastTestEnabled: Bool

    var items: [TravelCatPetMenuItem] {
        var entries: [TravelCatPetMenuItem] = [
            .action(.currentJourney, enabled: true),
            .action(.latestPostcard, enabled: hasLatestPostcard),
            .action(.album, enabled: hasLatestAlbum),
        ]

        if isFastTestEnabled {
            entries.append(.action(.temporaryTest, enabled: true))
        }

        entries.append(.separator)
        entries.append(.action(.closePet, enabled: true))
        return entries
    }
}
