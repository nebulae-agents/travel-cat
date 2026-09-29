import Foundation

/// The user's home, independent of the cat's current trip and historical diary locations.
public struct HomeLocation: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case ip, manual }
    public let country: String?
    public let region: String?
    public let city: String
    public let source: Source
    public let provider: String?
    public let updatedAt: Date

    public init(country: String? = nil, region: String? = nil, city: String,
                source: Source, provider: String? = nil, updatedAt: Date) {
        self.country = country
        self.region = region
        self.city = city
        self.source = source
        self.provider = provider
        self.updatedAt = updatedAt
    }

    public var displayName: String {
        [country, region, city].compactMap { $0 }.reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }.joined(separator: " · ")
    }

    public var isValid: Bool {
        Self.validName(city) && [country, region].allSatisfy { $0.map(Self.validName) ?? true }
            && (source == .manual ? provider == nil : provider == "ipwho.is")
    }

    public static func validName(_ value: String) -> Bool {
        value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.isEmpty && value.unicodeScalars.count <= 80
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
