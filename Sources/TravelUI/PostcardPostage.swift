import Foundation
import TravelCore
import TravelStorage

/// Decorative game postage, based on approximate city-centre straight-line distance.
/// Never a quotation of a postal operator's real-world tariff.
struct PostcardPostage: Equatable, Sendable {
    struct Design: Equatable, Sendable {
        let countryMark: String
        let palette: Int
        let symbol: String
    }

    let design: Design
    let distanceKilometers: Double?
    let fare: Int?
    var denominations: [Int] { fare.map(Self.denominations) ?? [] }

    var accessibilityDescription: String {
        guard let fare, let distanceKilometers else { return "地点距离待确认，纪念邮票" }
        let distance = fare == 1 ? "同城" : (distanceKilometers < 1 ? "距家乡不足 1 公里" : "距家乡约 \(Int(distanceKilometers.rounded())) 公里")
        return "\(distance)，虚拟邮资 \(fare) 猫邮币（城市中心直线距离）"
    }

    static func homeLocation(rootURL: URL?) -> HomeLocation? {
        guard let rootURL else { return nil }
        return try? HomeLocationStore(root: rootURL).load().location
    }

    static func resolve(location: Location?, home: HomeLocation?) -> Self {
        let origin = location.flatMap { PostageCities.shared.lookup(city: $0.city, country: $0.country) }
        let destination = home.flatMap { PostageCities.shared.lookup(city: $0.city, country: $0.country) }
        let design = stampDesign(location: location, countryCode: origin?.country)
        guard let origin, let destination else {
            return Self(design: design, distanceKilometers: nil, fare: nil)
        }
        let distance = origin.distance(to: destination)
        return Self(design: design, distanceKilometers: distance,
            fare: fare(distanceKilometers: distance, sameCity: origin.id == destination.id))
    }

    static func fare(distanceKilometers: Double, sameCity: Bool) -> Int {
        if sameCity { return 1 }
        if distanceKilometers <= 500 { return 2 }
        if distanceKilometers <= 2_000 { return 3 }
        return 5
    }

    static func denominations(for fare: Int) -> [Int] {
        switch fare {
        case 1: [1]
        case 2: [2]
        case 3: [1, 2]
        case 5: [1, 2, 2]
        default: []
        }
    }

    private static func stampDesign(location: Location?, countryCode: String?) -> Design {
        let country = countryCode ?? PostageCities.shared.countryCode(location?.country) ?? "CAT"
        let city = PostageCities.key(location?.city ?? "")
        let place = location?.place ?? ""
        // Stable across process launches; only postal location influences the artwork.
        func hash(_ text: String) -> UInt64 {
            text.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        }
        let symbols = ["mountain.2.fill", "leaf.fill", "water.waves", "building.columns.fill", "sun.max.fill", "bird.fill"]
        let symbol: String
        switch city {
        case "佛山", "foshan", "京都", "kyoto": symbol = "building.columns.fill"
        case "杭州", "hangzhou", "苏州": symbol = "leaf.fill"
        case "镰仓", "鎌倉", "kamakura": symbol = "water.waves"
        case "巴黎", "paris": symbol = "building.2.fill"
        case "雷克雅未克", "reykjavik": symbol = "mountain.2.fill"
        default: symbol = symbols[Int(hash(city + place) % UInt64(symbols.count))]
        }
        return Design(countryMark: country, palette: Int(hash(country + city) % 5), symbol: symbol)
    }
}

private struct PostageCities: Sendable {
    struct City: Sendable {
        let id: String
        let country: String
        let latitude: Double
        let longitude: Double

        func distance(to other: Self) -> Double {
            let radians = Double.pi / 180
            let deltaLatitude = (other.latitude - latitude) * radians
            let deltaLongitude = (other.longitude - longitude) * radians
            let a = pow(sin(deltaLatitude / 2), 2)
                + cos(latitude * radians) * cos(other.latitude * radians) * pow(sin(deltaLongitude / 2), 2)
            return 6_371 * 2 * atan2(sqrt(min(1, max(0, a))), sqrt(max(0, 1 - a)))
        }
    }

    static let shared = Self()
    private var cities: [String: [City]] = [:]
    private var countries: [String: Set<String>] = [:]

    static func key(_ name: String) -> String {
        var key = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        if key.hasSuffix("市") { key.removeLast() }
        return key
    }

    private init() {
        guard let url = TravelUIResources.bundle.url(forResource: "cities", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var codes: Set<String> = []
        for row in text.split(separator: "\n") {
            let fields = row.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 5, let latitude = Double(fields[2]), let longitude = Double(fields[3]),
                  latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else { continue }
            let city = City(id: String(fields[0]), country: String(fields[1]), latitude: latitude, longitude: longitude)
            codes.insert(city.country)
            for name in Set(fields[4].split(separator: "|").map { Self.key(String($0)) }) where !name.isEmpty {
                cities[name, default: []].append(city)
            }
        }
        for code in codes {
            countries[Self.key(code), default: []].insert(code)
            for locale in ["en", "zh_Hans", "zh_Hant", "ja"] {
                if let name = Locale(identifier: locale).localizedString(forRegionCode: code) {
                    countries[Self.key(name), default: []].insert(code)
                }
            }
        }
        for (code, names) in ["CN": ["中国", "中國", "China", "PRC"],
                              "GB": ["英国", "英國", "UK", "United Kingdom"],
                              "US": ["美国", "美國", "USA", "United States"]] {
            for name in names { countries[Self.key(name), default: []].insert(code) }
        }
    }

    func countryCode(_ name: String?) -> String? {
        guard let name, let codes = countries[Self.key(name)], codes.count == 1 else { return nil }
        return codes.first
    }

    func lookup(city: String, country: String?) -> City? {
        var candidates = cities[Self.key(city)] ?? []
        if let country, !country.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let code = countryCode(country) else { return nil }
            candidates = candidates.filter { $0.country == code }
        }
        // Do not choose the largest or best-known city when an alias is ambiguous.
        return candidates.count == 1 ? candidates.first : nil
    }
}
