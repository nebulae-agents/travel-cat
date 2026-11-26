/// An absent declaration uses the original provider-based text routing.
enum AgentXTextRuntime: String {
    case hostText = "host-text"
    case pi = "pi-agent-core"
    case nativeHTTP = "native-http"

    init?(declared: String?) {
        self.init(rawValue: declared ?? Self.hostText.rawValue)
    }
}

extension AgentXApplication {
    var declaredTextRuntime: AgentXTextRuntime? {
        guard let declaration = AgentXTextRuntime(declared: runtime),
              declaration == AgentXTextRuntime(declared: requiredRuntime) else { return nil }
        return declaration
    }
}
