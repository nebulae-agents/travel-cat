import Foundation

/// Installation metadata only: this never creates, moves, or modifies travel history.
public enum InstalledDataRootPreference {
    public enum ValidationError: Error { case unsafeLocation, invalidPreference }

    private struct Preference: Decodable {
        let schemaVersion: Int
        let path: String
    }

    public static func load(applicationSupportDirectory: URL) throws -> URL? {
        let directory = applicationSupportDirectory.appendingPathComponent("TravelCat", isDirectory: true)
        let file = directory.appendingPathComponent("data-location.json")
        let manager = FileManager.default
        // Check each existing component, including dangling links, before reading metadata.
        for location in [applicationSupportDirectory.deletingLastPathComponent(), applicationSupportDirectory, directory, file] {
            if let attributes = try? manager.attributesOfItem(atPath: location.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw ValidationError.unsafeLocation
            }
        }
        guard manager.fileExists(atPath: file.path) else { return nil }
        let attributes = try manager.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ValidationError.unsafeLocation
        }
        let preference = try JSONDecoder().decode(Preference.self, from: Data(contentsOf: file))
        guard preference.schemaVersion == 1, preference.path.hasPrefix("/"),
              !preference.path.contains("\0"), preference.path != "/" else {
            throw ValidationError.invalidPreference
        }
        return URL(fileURLWithPath: preference.path, isDirectory: true)
    }
}
