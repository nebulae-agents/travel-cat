import Foundation

struct AppBuildInformation {
    static let current = AppBuildInformation(infoDictionary: Bundle.main.infoDictionary ?? [:])

    private let version: String?
    private let build: String?
    private let buildDate: Date?

    init(infoDictionary: [String: Any]) {
        version = Self.metadataString(infoDictionary["CFBundleShortVersionString"])
        build = Self.metadataString(infoDictionary["CFBundleVersion"])

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
