import Darwin
import Foundation
import TravelCore
import TravelStorage

public struct PostcardPreparationResponse: Encodable, Sendable {
    public enum Status: String, Encodable, Sendable { case generate, fallback, prepared, rejected }
    public let status: Status
    public var fallbackReference: PostcardPresentationReference? = nil
    public var presentationReference: PostcardPresentationReference? = nil
    public var generationPrompt: String? = nil
    public var rejection: PostcardHandwritingPolicy.Correction? = nil
    public var correctionPrompt: String? = nil
}

/// Creates immutable presentation artifacts. Never leases or publishes repository state.
public struct PostcardPreparation {
    private let repository: TravelRepository
    private let select: @Sendable (TripEvent, Data) throws -> PostcardHandwritingPolicy.Hint
    private let verify: @Sendable (TripEvent, Data, Data) throws -> PostcardPresentationRect
    private let read: @Sendable (String) throws -> Data

    public init(repository: TravelRepository) {
        self.init(repository: repository, select: { try PostcardHandwritingPolicy.select(event: $0, base: $1) })
    }
    init(repository: TravelRepository,
         select: @escaping @Sendable (TripEvent, Data) throws -> PostcardHandwritingPolicy.Hint,
         verify: @escaping @Sendable (TripEvent, Data, Data) throws -> PostcardPresentationRect = { try PostcardHandwritingPolicy.verify(event: $0, base: $1, ink: $2) },
         read: @escaping @Sendable (String) throws -> Data = { try GeneratedPostcardImageReader().read(path: $0) }) {
        self.repository = repository; self.select = select; self.verify = verify; self.read = read
    }

    public func execute(_ request: PostcardPreparationRequest) throws -> PostcardPreparationResponse {
        try Task.checkCancellation()
        let event = try pendingEvent(request.eventId)
        guard let physical = realpath(repository.root.path, nil) else { throw PostcardPresentationError.unsafePath }
        let root = URL(fileURLWithPath: String(cString: physical)); free(physical)
        let store = PostcardPresentationStore(root: root)
        let fallback: PostcardPresentationReference
        switch request.action {
        case .begin:
            fallback = try store.prepare(event: event, expectedSourceRelativePath: request.sourceRelativePath,
                handwriting: .localFallback(.generationFailed), placement: .init(x: 0, y: 0, width: 1, height: 1),
                styleVersion: PostcardHandwritingPolicy.styleVersion)
        case .finish:
            guard let captured = request.fallbackReference else { throw PostcardPresentationError.invalidBinding }
            fallback = captured
        }
        return try store.withValidatedPresentation(reference: fallback, event: event,
            expectedSourceRelativePath: request.sourceRelativePath) { captured, revalidate in
            guard case .localFallback = captured.manifest.handwriting else { throw PostcardPresentationError.invalidBinding }
            func checkCurrent() throws {
                try Task.checkCancellation()
                guard try pendingEvent(event.id) == event else { throw PostcardPresentationError.invalidBinding }
                try revalidate()
            }
            if request.action == .begin {
                let hint: PostcardHandwritingPolicy.Hint
                do { hint = try select(event, captured.landscapeData) }
                catch PostcardHandwritingVerifier.Rejection.unsafeLayout {
                    try checkCurrent()
                    return .init(status: .fallback, fallbackReference: fallback)
                }
                let prompt = try PostcardHandwritingPolicy.prompt(event: event, hint: hint)
                try checkCurrent()
                return .init(status: .generate, fallbackReference: fallback, generationPrompt: prompt)
            }
            guard let path = request.generatedImagePath else { throw PostcardPresentationError.invalidBinding }
            // Bad paths, captured references and source/setup failures are operational errors.
            // Only a verifier rejection of safely read ink permits a targeted correction.
            let hint = try select(event, captured.landscapeData)
            let ink = try read(path)
            let placement: PostcardPresentationRect
            do { placement = try verify(event, captured.landscapeData, ink) }
            catch let rejection as PostcardHandwritingVerifier.Rejection {
                let code = PostcardHandwritingPolicy.feedback(rejection)
                let prompt = try PostcardHandwritingPolicy.prompt(event: event, hint: hint, correction: code)
                try checkCurrent()
                return .init(status: .rejected, rejection: code, correctionPrompt: prompt)
            }
            try checkCurrent()
            let generated = try store.prepare(event: event, expectedSourceRelativePath: request.sourceRelativePath,
                handwriting: .generated(ink), placement: placement, styleVersion: PostcardHandwritingPolicy.styleVersion)
            let verified = try store.load(reference: generated, event: event, expectedSourceRelativePath: request.sourceRelativePath)
            guard verified.manifest.source.sha256 == captured.manifest.source.sha256,
                  verified.manifest.landscape.sha256 == captured.manifest.landscape.sha256 else {
                throw PostcardPresentationError.invalidBinding
            }
            try checkCurrent()
            return .init(status: .prepared, presentationReference: generated)
        }
    }

    private func pendingEvent(_ id: UUID) throws -> TripEvent {
        guard let event = try repository.loadContents().events.first(where: { $0.id == id }),
              event.postcardStatus == .pendingImage else { throw PostcardPresentationError.invalidBinding }
        return event
    }
}
