import Foundation

public enum DataLocationError: Error, Equatable, Sendable {
    case selectionRequired
    case bookmarkStale
}

public struct SharedDataLocator: Sendable {
    public init() {}

    public func resolve(environment: [String: String], bookmarkData: Data?) throws -> URL {
        if let path = environment["TRAVEL_CAT_DATA"], !path.isEmpty {
            return URL(fileURLWithPath: path).standardizedFileURL
        }

        guard let bookmarkData else {
            throw DataLocationError.selectionRequired
        }

        var isStale = false
        let resolved = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard !isStale else {
            throw DataLocationError.bookmarkStale
        }
        return resolved.standardizedFileURL
    }
}
