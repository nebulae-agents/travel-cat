import Foundation

public struct AppDataRootResolver: Sendable {
    public init() {}

    public func resolve(
        environment: [String: String],
        bundledDataRoot: URL? = nil,
        developmentProjectRoot: URL?,
        applicationSupportDirectory: URL
    ) -> URL {
        if let configured = environment["TRAVEL_CAT_DATA"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
        }
        if let bundledDataRoot {
            return bundledDataRoot.standardizedFileURL
        }
        if let developmentProjectRoot {
            return developmentProjectRoot
                .appendingPathComponent("TravelPetData", isDirectory: true)
                .standardizedFileURL
        }
        return applicationSupportDirectory
            .appendingPathComponent("TravelCat", isDirectory: true)
            .appendingPathComponent("TravelPetData", isDirectory: true)
            .standardizedFileURL
    }
}
