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
