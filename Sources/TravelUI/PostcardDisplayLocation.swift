import Foundation
import TravelCore

public struct PostcardDisplayLocation: Sendable {
    public init() {}

    public func resolve(_ location: Location?) -> String {
        guard let location else { return "旅途中" }

        let country = trimmed(location.country)
        let city = trimmed(location.city)
        let place = trimmed(location.place)

        switch normalized((country, city, place)) {
        case ("JAPAN", "OTSU", "OTSU PORT OLD PIER"):
            return "大津港旧栈桥"
        case ("JAPAN", "HATSUKAICHI", "ITSUKUSHIMA SHRINE O-TORII"):
            return "宫岛大鸟居"
        case ("JAPAN", "MATSUMOTO", "KAPPA BRIDGE"):
            return "上高地河童桥"
        case ("CHINA", "SUZHOU", "MASTER OF THE NETS GARDEN"):
            return "苏州·网师园"
        default:
            if isSuzhouMasterOfTheNetsGarden(country: country, city: city, place: place) {
                return "苏州·网师园"
            }
        }

        if !place.isEmpty { return place }
        if !city.isEmpty { return city }

        return country.isEmpty ? "旅途中" : country
    }

    /// Returns the location label intended for a constrained visual title.
    /// Unknown places are shortened without changing the spoken/accessibility label.
    public func resolveCompact(_ location: Location?, maximumLength: Int = 24) -> String {
        let resolved = resolve(location)
        guard maximumLength > 0, resolved.count > maximumLength else { return resolved }
        guard maximumLength > 1 else { return "…" }
        return String(resolved.prefix(maximumLength - 1)) + "…"
    }

    public func resolveSpoken(_ location: Location?) -> String {
        guard let location else { return "旅途中" }

        let components = [location.country, location.city, location.place]
            .map(trimmed)
            .filter { !$0.isEmpty }
        return components.isEmpty ? "旅途中" : components.joined(separator: " · ")
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalized(_ values: (String, String, String)) -> (String, String, String) {
        func normalize(_ value: String) -> String {
            trimmed(value).folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            ).uppercased()
        }
        return (normalize(values.0), normalize(values.1), normalize(values.2))
    }

    private func isSuzhouMasterOfTheNetsGarden(country: String, city: String, place: String) -> Bool {
        let countryMatches = country == "中国" || country.caseInsensitiveCompare("China") == .orderedSame
        let cityMatches = city == "苏州" || city.caseInsensitiveCompare("Suzhou") == .orderedSame
        return countryMatches && cityMatches && place.caseInsensitiveCompare("Master of the Nets Garden") == .orderedSame
    }
}
