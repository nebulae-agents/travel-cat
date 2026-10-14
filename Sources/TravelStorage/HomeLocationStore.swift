import Foundation
import TravelCore

public struct HomeLocationState: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var location: HomeLocation?
    public var lastAttemptAt: Date?
    /// Off until the user explicitly enables the named third-party service.
    public var ipLookupEnabled = false

    public init(location: HomeLocation? = nil, lastAttemptAt: Date? = nil, ipLookupEnabled: Bool = false) {
        self.location = location
        self.lastAttemptAt = lastAttemptAt
        self.ipLookupEnabled = ipLookupEnabled
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, location, lastAttemptAt, ipLookupEnabled }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        location = try values.decodeIfPresent(HomeLocation.self, forKey: .location)
        lastAttemptAt = try values.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        ipLookupEnabled = try values.decodeIfPresent(Bool.self, forKey: .ipLookupEnabled) ?? false
    }
}

public struct HomeLocationStore: Sendable {
    public let url: URL
    public init(root: URL) { url = root.appendingPathComponent("state/home-location.json") }

    public func load() throws -> HomeLocationState {
        guard FileManager.default.fileExists(atPath: url.path) else { return HomeLocationState() }
        let state = try JSONDecoder.travelCat.decode(HomeLocationState.self, from: Data(contentsOf: url))
        try validate(state)
        return state
    }

    public func save(_ state: HomeLocationState) throws {
        try validate(state)
        try AtomicFileWriter().write(JSONEncoder.travelCat.encode(state), to: url)
    }

    private func validate(_ state: HomeLocationState) throws {
        guard state.schemaVersion == 1, state.location?.isValid != false else { throw CocoaError(.fileReadCorruptFile) }
    }
}
