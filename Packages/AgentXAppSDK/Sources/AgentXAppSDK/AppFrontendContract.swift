import Foundation

/// Declarative frontends are data, never executable host code. Version 1 supports
/// local forms whose explicit submit action becomes a user message to an app instance.
public struct AppFrontendContract: Codable, Equatable, Sendable {
    public struct Field: Codable, Equatable, Sendable {
        public var id: String
        public var label: String
        public var multiline: Bool
        public init(id: String, label: String, multiline: Bool = false) { self.id = id; self.label = label; self.multiline = multiline }
    }
    public struct Submit: Codable, Equatable, Sendable {
        public var title: String
        public var prompt: String
        public init(title: String, prompt: String) { self.title = title; self.prompt = prompt }
    }
    public struct Module: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var kind: String
        public var fields: [Field]
        public var submit: Submit
        public init(id: String, title: String, fields: [Field], submit: Submit) {
            self.id = id; self.title = title; self.kind = "form"; self.fields = fields; self.submit = submit
        }
    }
    public var schemaVersion: Int
    public var title: String
    public var modules: [Module]
    public init(title: String, modules: [Module]) { schemaVersion = 1; self.title = title; self.modules = modules }
    private static let variable = try! NSRegularExpression(pattern: #"\{\{([a-z0-9_-]+)\}\}"#)
    public func validate() throws {
        guard schemaVersion == 1, !title.isEmpty, title.count <= 160,
              !modules.isEmpty, modules.count <= 16, Set(modules.map(\.id)).count == modules.count else { throw AppSDKError.invalidManifest }
        for module in modules {
            guard validID(module.id), module.id.count <= 64, !module.title.isEmpty,
                  module.kind == "form", module.fields.count <= 32,
                  Set(module.fields.map(\.id)).count == module.fields.count,
                  module.fields.allSatisfy({ validID($0.id) && !$0.label.isEmpty && $0.label.count <= 160 }),
                  !module.submit.title.isEmpty, !module.submit.prompt.isEmpty,
                  module.submit.prompt.utf8.count <= 100_000 else { throw AppSDKError.invalidManifest }
            let text = module.submit.prompt as NSString
            let matches = Self.variable.matches(in: module.submit.prompt, range: NSRange(location: 0, length: text.length))
            let keys = Set(module.fields.map(\.id))
            guard matches.allSatisfy({ keys.contains(text.substring(with: $0.range(at: 1))) }) else { throw AppSDKError.invalidManifest }
            let remainder = Self.variable.stringByReplacingMatches(in: module.submit.prompt, range: NSRange(location: 0, length: text.length), withTemplate: "")
            guard !remainder.contains("{{"), !remainder.contains("}}") else { throw AppSDKError.invalidManifest }
        }
    }
    public func prompt(moduleID: String, values: [String: String]) throws -> String {
        try validate()
        guard let module = modules.first(where: { $0.id == moduleID }) else { throw AppSDKError.invalidManifest }
        let template = module.submit.prompt as NSString
        let matches = Self.variable.matches(in: module.submit.prompt, range: NSRange(location: 0, length: template.length))
        let output = NSMutableString(string: module.submit.prompt)
        for match in matches.reversed() {
            let key = template.substring(with: match.range(at: 1))
            guard let value = values[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.utf8.count <= 100_000 else { throw AppSDKError.invalidManifest }
            output.replaceCharacters(in: match.range, with: value)
        }
        guard (output as String).utf8.count <= 100_000 else { throw AppSDKError.invalidManifest }
        return output as String
    }
}
