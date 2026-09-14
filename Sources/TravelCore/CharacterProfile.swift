import Foundation

public enum CharacterAssetLocator: Codable, Equatable, Sendable {
    case bundled(String)
    case dataRootRelative(String)
}

public enum CharacterProfileSource: Codable, Equatable, Sendable {
    case bundledDefault
    case importedManifest(String)
}

public struct CharacterProfile: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let description: String
    public let spriteVersionNumber: Int
    public let sprite: CharacterAssetLocator
    public let referenceImages: [CharacterAssetLocator]
    public let source: CharacterProfileSource

    public init(
        id: String,
        displayName: String,
        description: String,
        spriteVersionNumber: Int,
        sprite: CharacterAssetLocator,
        referenceImages: [CharacterAssetLocator],
        source: CharacterProfileSource
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.spriteVersionNumber = spriteVersionNumber
        self.sprite = sprite
        self.referenceImages = referenceImages
        self.source = source
    }

    public static let defaultBlackCat = CharacterProfile(
        id: "cute-black-cat",
        displayName: "Cute Black Cat",
        description: "A calm golden-eyed black cat with a subtle violet glow.",
        spriteVersionNumber: 2,
        sprite: .bundled("cute-black-cat-spritesheet.webp"),
        referenceImages: [],
        source: .bundledDefault
    )
}
