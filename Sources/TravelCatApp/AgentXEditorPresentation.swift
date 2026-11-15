import Foundation

/// The sheet receives its entity snapshot with its identity in a single state update.
struct AgentXEditorPresentation: Identifiable {
    private enum Content {
        case create(AgentXEditor)
        case provider(AgentXProvider)
        case definition(AgentXDefinition)
        case instance(AgentXInstance)
    }

    let id = UUID()
    private(set) var contextGeneration: Int?
    private let content: Content

    init(create kind: AgentXEditor) { content = .create(kind) }
    init(provider: AgentXProvider) { content = .provider(provider) }
    init(definition: AgentXDefinition) { content = .definition(definition) }
    init(instance: AgentXInstance) { content = .instance(instance) }

    func scoped(to generation: Int) -> Self {
        var presentation = self
        presentation.contextGeneration = generation
        return presentation
    }

    /// A context notification may arrive after a new editor was opened in that context.
    /// Discard only older requests, preserving the newly scoped snapshot and sheet identity.
    func retained(in generation: Int) -> Self? {
        contextGeneration == generation ? self : nil
    }

    var kind: AgentXEditor {
        switch content {
        case .create(let kind): kind
        case .provider: .provider
        case .definition: .definition
        case .instance: .instance
        }
    }

    var existingProvider: AgentXProvider? {
        if case .provider(let provider) = content { provider } else { nil }
    }
    var existingDefinition: AgentXDefinition? {
        if case .definition(let definition) = content { definition } else { nil }
    }
    var existingInstance: AgentXInstance? {
        if case .instance(let instance) = content { instance } else { nil }
    }
}
