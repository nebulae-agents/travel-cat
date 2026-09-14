import Foundation

public struct TravelRuntimeMetadata: Codable, Equatable, Sendable {
    public let dataRoot: String
    public let bundledResourcesRoot: String?

    public init(dataRoot: String, bundledResourcesRoot: String? = nil) {
        self.dataRoot = dataRoot
        self.bundledResourcesRoot = bundledResourcesRoot
    }
}
