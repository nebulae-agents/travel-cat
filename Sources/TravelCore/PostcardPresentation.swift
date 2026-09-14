import Foundation

public struct PostcardPresentationReference: Codable, Equatable, Sendable {
    public let relativePath: String
    public let sha256: String
    public init(relativePath: String, sha256: String) { self.relativePath = relativePath; self.sha256 = sha256 }
}

public struct PostcardPresentationAsset: Codable, Equatable, Sendable {
    public let relativePath: String
    public let sha256: String
    public init(relativePath: String, sha256: String) { self.relativePath = relativePath; self.sha256 = sha256 }
}

public struct PostcardPresentationRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1 && y + height <= 1
    }
}

public enum PostcardHandwritingFallbackReason: String, Codable, Equatable, Sendable {
    case generationFailed, unavailable, invalidGeneratedImage
}

/// An enum prevents ambiguous combinations of generated and local fallback handwriting.
public enum PostcardPresentationHandwriting: Codable, Equatable, Sendable {
    case generated(PostcardPresentationAsset)
    case localFallback(PostcardHandwritingFallbackReason)
}

public struct PostcardPresentationManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let eventID: UUID
    public let tripID: UUID
    public let source: PostcardPresentationAsset
    public let landscape: PostcardPresentationAsset
    public let quote: String
    public let quoteSHA256: String
    public let styleVersion: String
    public let placement: PostcardPresentationRect
    public let handwriting: PostcardPresentationHandwriting
    /// Top-left normalized source pixel viewport; absence means the entire original PNG.
    public let handwritingViewport: PostcardPresentationRect?

    public init(schemaVersion: Int = 1, eventID: UUID, tripID: UUID, source: PostcardPresentationAsset, landscape: PostcardPresentationAsset, quote: String, quoteSHA256: String, styleVersion: String, placement: PostcardPresentationRect, handwriting: PostcardPresentationHandwriting, handwritingViewport: PostcardPresentationRect? = nil) {
        self.schemaVersion = schemaVersion; self.eventID = eventID; self.tripID = tripID
        self.source = source; self.landscape = landscape; self.quote = quote; self.quoteSHA256 = quoteSHA256
        self.styleVersion = styleVersion; self.placement = placement; self.handwriting = handwriting
        self.handwritingViewport = handwritingViewport
    }
}
