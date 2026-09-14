import Foundation
import TravelCore

public struct TravelSettings: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var mode: TravelMode
    public var quietStart: Int
    public var quietEnd: Int
    public var followCodexPet: Bool

    public init(
        schemaVersion: Int = 1,
        mode: TravelMode = .daily,
        quietStart: Int = 22,
        quietEnd: Int = 8,
        followCodexPet: Bool = true
    ) {
        self.schemaVersion = schemaVersion
        self.mode = mode
        self.quietStart = Self.canonicalHour(quietStart)
        self.quietEnd = Self.canonicalHour(quietEnd)
        self.followCodexPet = followCodexPet
    }

    public static func canonicalHour(_ hour: Int) -> Int {
        ((hour % 24) + 24) % 24
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, mode, quietStart, quietEnd, followCodexPet
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "Unsupported settings schema version \(schemaVersion)"
            )
        }
        let followCodexPet = try values.decodeIfPresent(Bool.self, forKey: .followCodexPet) ?? true
        self.init(
            schemaVersion: schemaVersion,
            mode: try values.decode(TravelMode.self, forKey: .mode),
            quietStart: try values.decode(Int.self, forKey: .quietStart),
            quietEnd: try values.decode(Int.self, forKey: .quietEnd),
            followCodexPet: followCodexPet
        )
    }
}

public extension TravelSettings {
    var isFastTestEnabled: Bool { mode == .fast }
}

public struct TravelSettingsStore: Sendable {
    public let url: URL
    private let writer = AtomicFileWriter()

    public init(root: URL) {
        url = root.standardizedFileURL.appendingPathComponent("state/settings.json")
    }

    public func load() throws -> TravelSettings {
        if !FileManager.default.fileExists(atPath: url.path) {
            let initial = TravelSettings()
            try save(initial)
            return initial
        }
        return try JSONDecoder.travelCat.decode(TravelSettings.self, from: Data(contentsOf: url))
    }

    public func save(_ settings: TravelSettings) throws {
        try writer.write(JSONEncoder.travelCat.encode(settings), to: url)
    }
}
