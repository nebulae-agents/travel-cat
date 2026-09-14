import CoreGraphics
import CoreFoundation
import Foundation

struct CodexPetOverlayAnchor: Equatable {
    let inputBounds: CGRect
    let displayBounds: CGRect
    let displayID: UInt32
}

enum CodexPetOverlayReadResult: Equatable {
    case unavailable
    case hidden
    case visible(CodexPetOverlayAnchor)
}

enum CodexPetStateReader {
    private static let stateFileName = ".codex-global-state.json"
    private static let configFileName = "config.toml"

    static func read(
        codexDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    ) -> CodexPetOverlayReadResult {
        let state = try? Data(contentsOf: codexDirectory.appendingPathComponent(stateFileName))
        let config = try? String(contentsOf: codexDirectory.appendingPathComponent(configFileName), encoding: .utf8)
        return parse(stateData: state, configuration: config)
    }

    static func parse(
        stateData: Data?,
        configuration: String?
    ) -> CodexPetOverlayReadResult {
        let settings = parseConfiguration(configuration)
        guard settings.petVisible else { return .hidden }
        guard let data = stateData,
              let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any],
              let open = strictBool(object["electron-avatar-overlay-open"]) else { return .unavailable }
        guard open else { return .hidden }
        guard let bounds = object["electron-avatar-overlay-bounds"] as? [String: Any],
              let x = finiteNumber(bounds["x"], absoluteLimit: 100_000),
              let y = finiteNumber(bounds["y"], absoluteLimit: 100_000),
              let display = bounds["displayBounds"] as? [String: Any],
              let dx = finiteNumber(display["x"], absoluteLimit: 100_000),
              let dy = finiteNumber(display["y"], absoluteLimit: 100_000),
              let dw = finiteNumber(display["width"], positiveLimit: 100_000),
              let dh = finiteNumber(display["height"], positiveLimit: 100_000),
              let displayID = strictPositiveUInt32(bounds["displayId"]) else { return .unavailable }

        let width = CGFloat(settings.width)
        let height = ceil(width * 208 / 192)
        let input = CGRect(x: x, y: y, width: width, height: height)
        let displayRect = CGRect(x: dx, y: dy, width: dw, height: dh)
        guard displayRect.contains(input) else { return .unavailable }
        return .visible(CodexPetOverlayAnchor(inputBounds: input, displayBounds: displayRect, displayID: displayID))
    }

    private static func strictBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func finiteNumber(_ value: Any?, absoluteLimit: Double? = nil, positiveLimit: Double? = nil) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        guard result.isFinite else { return nil }
        if let limit = absoluteLimit, abs(result) > limit { return nil }
        if let limit = positiveLimit, result <= 0 || result > limit { return nil }
        return result
    }

    private static func strictPositiveUInt32(_ value: Any?) -> UInt32? {
        guard let number = finiteNumber(value), number > 0, number.rounded() == number, number <= Double(UInt32.max) else { return nil }
        return UInt32(number)
    }

    private static func parseConfiguration(_ configuration: String?) -> (width: Int, petVisible: Bool) {
        guard let configuration else { return (112, true) }
        var section = ""
        var width = 112
        var petVisible = true
        for rawLine in configuration.split(whereSeparator: \ .isNewline) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let name = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                section = name == "desktop" || name == "\"desktop\"" || name == "'desktop'" ? "desktop" : "other"
                continue
            }
            guard section == "desktop", let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if key == "avatar-overlay-pet-visible" {
                if value == "false" { petVisible = false }
                if value == "true" { petVisible = true }
            } else if key == "avatar-overlay-mascot-width-px", let parsed = Int(value), (80...224).contains(parsed) {
                width = parsed
            }
        }
        return (width, petVisible)
    }
}
