import Foundation

struct AppBuildInformation: Sendable {
    static let current = AppBuildInformation(infoDictionary: Bundle.main.infoDictionary ?? [:])

    private let version: String?
    private let build: String?
    private let buildDate: Date?
    private let sourceRevision: String?

    init(infoDictionary: [String: Any]) {
        version = Self.metadataString(infoDictionary["CFBundleShortVersionString"])
        build = Self.metadataString(infoDictionary["CFBundleVersion"])
        if let revision = infoDictionary["TravelCatSourceRevision"] as? String,
           [40, 64].contains(revision.utf8.count),
           revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
            sourceRevision = revision
        } else { sourceRevision = nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        if let timestamp = infoDictionary["TravelCatBuildTimestamp"] as? String,
           let date = formatter.date(from: timestamp),
           formatter.string(from: date) == timestamp {
            buildDate = date
        } else {
            buildDate = nil
        }
    }

    var sourceDescription: String { sourceRevision.map { String($0.prefix(12)) } ?? "未记录" }

    var versionDescription: String {
        let description = version ?? "未知版本"
        guard let build else { return description }
        return "\(description)（构建\(build)）"
    }

    func buildDateDescription(timeZone: TimeZone = .current) -> String {
        guard let buildDate else { return "未记录" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: buildDate)
    }

    private static func metadataString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
