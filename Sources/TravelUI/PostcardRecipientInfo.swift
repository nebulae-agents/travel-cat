import Foundation

/// Local display preferences. These details are not part of a travel event.
public struct PostcardRecipientInfo: Codable, Equatable, Sendable {
    public var name: String
    public var address: String
    public var postalCode: String

    public init(name: String = "亲爱的你", address: String = "", postalCode: String = "") {
        self.name = name
        self.address = address
        self.postalCode = postalCode
    }

    public static let empty = PostcardRecipientInfo()

    public var normalized: Self {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(
            name: cleanName.isEmpty ? Self.empty.name : cleanName,
            address: address.trimmingCharacters(in: .whitespacesAndNewlines),
            postalCode: postalCode.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
