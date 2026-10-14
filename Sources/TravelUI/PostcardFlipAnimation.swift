import Foundation
import Observation
import TravelCore

@MainActor @Observable
final class PostcardFlipAnimation {
    private enum Phase {
        case idle
        case outward(UUID, PostcardFace, PostcardFace)
        case inward(UUID, PostcardFace)
    }

    private var phase = Phase.idle
    var angle = 0.0

    var isTurning: Bool {
        if case .idle = phase { return false }
        return true
    }

    var isUnfolding: Bool {
        if case .inward = phase { return true }
        return false
    }

    func visibilityHandler(face: @escaping () -> PostcardFace,
                           onVisible: @escaping (String) -> Void) -> (String) -> Void {
        { [weak self] path in
            guard let self, !self.isTurning, face() == .scenic else { return }
            onVisible(path)
        }
    }

    var expectedFace: PostcardFace? {
        switch phase {
        case .idle: nil
        case let .outward(_, source, _): source
        case let .inward(_, target): target
        }
    }

    func immediateFace(from face: PostcardFace, event: TripEvent) -> PostcardFace? {
        guard !isTurning, face == .scenic || PostcardFace.hasScenery(for: event) else { return nil }
        return face == .message ? .scenic : .message
    }

    func begin(from face: PostcardFace, event: TripEvent) -> UUID? {
        guard let target = immediateFace(from: face, event: event) else { return nil }
        let turn = UUID()
        phase = .outward(turn, face, target)
        return turn
    }

    func reveal(_ turn: UUID) -> PostcardFace? {
        guard case let .outward(active, _, target) = phase, active == turn else { return nil }
        phase = .inward(turn, target)
        return target
    }

    func finish(_ turn: UUID) {
        guard case let .inward(active, _) = phase, active == turn else { return }
        cancel()
    }

    func cancel() {
        phase = .idle
        angle = 0
    }
}
