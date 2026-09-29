import Foundation

public enum PostcardSceneCategory: String, CaseIterable, Sendable {
    case waterside, heritage, market, mountain, garden, urban, everyday
}

/// Versioned only for new cards. All inputs are published, immutable event fields;
/// retry timing, process-randomized Hasher, current weather and UI state play no part.
public struct PostcardSceneStyle: Equatable, Sendable {
    public let category: PostcardSceneCategory
    public let compositionVariant: Int

    public static func resolve(event: TripEvent) -> PostcardSceneStyle? {
        guard event.postcardStyleVersion == 1 else { return nil }
        let category = classify(event.location?.place ?? "")
            ?? classify(event.summary)
            ?? .everyday
        let seed = [event.location?.country ?? "", event.location?.city ?? "",
                    event.location?.place ?? "", event.id.uuidString].joined(separator: "\u{0}")
        // FNV-1a is deliberately fixed across launches and Swift versions.
        let hash = seed.utf8.reduce(UInt64(14695981039346656037)) {
            ($0 ^ UInt64($1)) &* 1099511628211
        }
        return Self(category: category, compositionVariant: Int(hash % 3))
    }

    private static func classify(_ text: String) -> PostcardSceneCategory? {
        let normalized = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                      locale: Locale(identifier: "en_US_POSIX"))
        let words = Set(normalized.split { !$0.isLetter }.map(String.init))
        for (category, chinese, english) in sceneKeywords {
            if chinese.contains(where: normalized.contains) || english.contains(where: words.contains) {
                return category
            }
        }
        return nil
    }

    private static let sceneKeywords: [(PostcardSceneCategory, [String], [String])] = [
        (.waterside, ["湖", "海边", "海岸", "沙滩", "河", "江边", "溪", "码头", "瀑布"],
         ["lake", "lakeside", "sea", "seaside", "coast", "beach", "river", "harbour", "harbor", "waterfall"]),
        (.heritage, ["古城", "古镇", "寺", "庙", "宫", "城堡", "教堂", "遗址", "祠", "老宅"],
         ["temple", "shrine", "palace", "castle", "cathedral", "heritage", "ruins"]),
        (.market, ["集市", "市场", "夜市", "小吃", "摊位", "早市", "茶馆", "咖啡"],
         ["market", "bazaar", "cafe", "stall", "food"]),
        (.mountain, ["山", "峡谷", "雪原", "冰川", "高原", "草原", "徒步"],
         ["mountain", "mountains", "canyon", "glacier", "alpine", "plateau", "hike"]),
        (.garden, ["花园", "公园", "园林", "竹林", "森林", "树林", "花田"],
         ["garden", "park", "forest", "woods", "bamboo"]),
        (.urban, ["街", "巷", "广场", "车站", "大厦", "地铁", "路口"],
         ["street", "alley", "square", "station", "skyline", "avenue"]),
    ]
}
