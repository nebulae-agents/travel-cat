import Foundation
import TravelCore
import TravelStorage

public enum CharacterSpriteResolution: Equatable, Sendable {
    case available(URL)
    case unavailable(displayName: String)
}

public enum CharacterSpriteResolver {
    public static func resolve(profile: CharacterProfile, dataRoot: URL?) -> CharacterSpriteResolution {
        if profile == .defaultBlackCat {
            guard let url = PetSpriteResources.spriteSheetURL else {
                return .unavailable(displayName: profile.displayName)
            }
            return .available(url)
        }

        guard let dataRoot,
              (try? CharacterProfileStore(dataRoot: dataRoot).validatedProfile(profile)) == profile,
              case let .dataRootRelative(path) = profile.sprite else {
            return .unavailable(displayName: profile.displayName)
        }
        let url = dataRoot.standardizedFileURL.appendingPathComponent(path).standardizedFileURL
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return .unavailable(displayName: profile.displayName)
        }
        return .available(url)
    }
}
