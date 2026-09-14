import Foundation
import TravelCore

public enum TravelCLIUsageError: Error, Sendable {
    case invalidArguments
}

public enum TravelCLICommand: String, Equatable, Sendable {
    case status
    case claim
    case publish
    case pendingImages = "pending-images"
    case journal
    case markImage = "mark-image"
    case preparePostcard = "prepare-postcard"
    case validateCandidate = "validate-candidate"
    case character
    case configureCharacter = "configure-character"
    case installDefaultPet = "install-default-pet"

    public static func parse(arguments: [String]) throws -> TravelCLICommand {
        guard arguments.count == 1,
              let value = arguments.first,
              let command = TravelCLICommand(rawValue: value) else {
            throw TravelCLIUsageError.invalidArguments
        }
        return command
    }
}

public struct PostcardPreparationRequest: Decodable, Sendable {
    public enum Action: String, Decodable, Sendable { case begin, finish }
    public let action: Action
    public let eventId: UUID
    public let sourceRelativePath: String
    public let fallbackReference: PostcardPresentationReference?
    public let generatedImagePath: String?

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 65_536 else { throw CharacterConfigurationRequestError.tooLarge }
        do {
            try StrictJSONPreflight.validate(data)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CharacterConfigurationRequestError.invalidRequest
            }
            let value = try JSONDecoder().decode(Self.self, from: data)
            let keys: Set<String> = value.action == .begin
                ? ["action", "eventId", "sourceRelativePath"]
                : ["action", "eventId", "sourceRelativePath", "fallbackReference", "generatedImagePath"]
            guard Set(object.keys) == keys, canonical(value.sourceRelativePath, extensions: ["png", "webp"]) else {
                throw CharacterConfigurationRequestError.invalidRequest
            }
            if value.action == .finish {
                guard let ref = value.fallbackReference,
                      let raw = object["fallbackReference"] as? [String: Any], Set(raw.keys) == ["relativePath", "sha256"],
                      canonical(ref.relativePath, extensions: ["json"]), ref.sha256.utf8.count == 64,
                      ref.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                      let path = value.generatedImagePath, path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096 else {
                    throw CharacterConfigurationRequestError.invalidRequest
                }
            }
            return value
        } catch { throw CharacterConfigurationRequestError.invalidRequest }
    }

    private static func canonical(_ path: String, extensions: Set<String>) -> Bool {
        let parts = path.components(separatedBy: "/")
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._-".utf8)
        guard parts.count == 3, parts[0] == "postcards", let trip = UUID(uuidString: parts[1]),
              trip.uuidString.lowercased() == parts[1], let first = parts[2].utf8.first,
              (48...57).contains(first) || (97...122).contains(first),
              parts[2].utf8.allSatisfy(allowed.contains), extensions.contains((parts[2] as NSString).pathExtension) else { return false }
        return true
    }
}

public enum CharacterConfigurationRequestError: Error, Equatable, Sendable {
    case invalidRequest
    case tooLarge
}

public enum CharacterConfigurationRequest: Equatable, Sendable {
    case `default`
    case `import`(directory: URL)

    public static func decode(_ data: Data, maximumBytes: Int = 64 * 1_024) throws -> Self {
        guard data.count <= maximumBytes else { throw CharacterConfigurationRequestError.tooLarge }
        let object: [String: String]
        do {
            try StrictJSONPreflight.validate(data)
            object = try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            throw CharacterConfigurationRequestError.invalidRequest
        }
        guard let action = object["action"] else { throw CharacterConfigurationRequestError.invalidRequest }
        switch action {
        case "default":
            guard Set(object.keys) == ["action"] else { throw CharacterConfigurationRequestError.invalidRequest }
            return .default
        case "import":
            guard Set(object.keys) == ["action", "directory"],
                  let path = object["directory"], path.hasPrefix("/") else {
                throw CharacterConfigurationRequestError.invalidRequest
            }
            return .import(directory: URL(fileURLWithPath: path).standardizedFileURL)
        default:
            throw CharacterConfigurationRequestError.invalidRequest
        }
    }
}

public struct CharacterConfigurationResponse: Codable, Equatable, Sendable {
    public let selectedProfile: CharacterProfile
    public let effectiveProfile: CharacterProfile
    public let dataRoot: String

    public init(selectedProfile: CharacterProfile, effectiveProfile: CharacterProfile, dataRoot: URL) {
        self.selectedProfile = selectedProfile
        self.effectiveProfile = effectiveProfile
        self.dataRoot = dataRoot.standardizedFileURL.path
    }
}

public enum TravelCLIErrorPolicy: Sendable {
    public static func isSilentSuccess(_ error: any Error) -> Bool {
        guard let repositoryError = error as? RepositoryError else { return false }
        if case .lockUnavailable = repositoryError {
            return true
        }
        return false
    }
}

public enum CLIConfigurationError: Error, Equatable, Sendable {
    case invalidMode(String)
    case invalidNow(String)
    case invalidBundledResourcesRoot(String)
}

extension CLIConfigurationError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .invalidMode(value):
            "invalid TRAVEL_CAT_MODE: \(value)"
        case let .invalidNow(value):
            "invalid TRAVEL_CAT_NOW: \(value)"
        case let .invalidBundledResourcesRoot(value):
            "invalid TRAVEL_CAT_BUNDLED_RESOURCES_ROOT: \(value)"
        }
    }
}

public struct TravelCLIConfiguration: Sendable {
    public let root: URL
    public let mode: TravelMode
    private let hasModeOverride: Bool
    public let now: Date
    public let runtime: TravelRuntimeMetadata

    public init(
        environment: [String: String],
        currentDirectory: URL,
        currentDate: Date = Date()
    ) throws {
        if let path = environment["TRAVEL_CAT_DATA"], !path.isEmpty {
            root = URL(fileURLWithPath: path).standardizedFileURL
        } else {
            root = currentDirectory
                .appendingPathComponent("TravelPetData", isDirectory: true)
                .standardizedFileURL
        }

        let modeOverride = environment["TRAVEL_CAT_MODE"].flatMap { $0.isEmpty ? nil : $0 }
        hasModeOverride = modeOverride != nil
        let modeValue = modeOverride ?? TravelMode.daily.rawValue
        guard let mode = TravelMode(rawValue: modeValue) else {
            throw CLIConfigurationError.invalidMode(modeValue)
        }
        self.mode = mode

        if let nowValue = environment["TRAVEL_CAT_NOW"], !nowValue.isEmpty {
            do {
                let stringData = try JSONEncoder().encode(nowValue)
                now = try JSONDecoder.travelCat.decode(Date.self, from: stringData)
            } catch {
                throw CLIConfigurationError.invalidNow(nowValue)
            }
        } else {
            now = currentDate
        }

        let bundledResourcesRoot: String?
        if let value = environment["TRAVEL_CAT_BUNDLED_RESOURCES_ROOT"], !value.isEmpty {
            guard value.hasPrefix("/") else { throw CLIConfigurationError.invalidBundledResourcesRoot(value) }
            bundledResourcesRoot = URL(fileURLWithPath: value).standardizedFileURL.path
        } else {
            bundledResourcesRoot = nil
        }
        runtime = TravelRuntimeMetadata(
            dataRoot: root.standardizedFileURL.path,
            bundledResourcesRoot: bundledResourcesRoot
        )
    }

    public func resolvedMode() throws -> TravelMode {
        if hasModeOverride { return mode }
        return try TravelSettingsStore(root: root).load().mode
    }
}
