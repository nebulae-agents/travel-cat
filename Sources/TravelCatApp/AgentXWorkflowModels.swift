import Foundation

struct AgentXWorkflowStep: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString.lowercased()
    var name: String
    var instanceID: String
    var instruction: String
}

struct AgentXWorkflowDefinition: Codable, Equatable {
    var name: String
    var steps: [AgentXWorkflowStep]
    static let maximumSteps = 12

    func validate(appID: String, instances: [AgentXInstance], requireRunnable: Bool = true) throws {
        func filled(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard steps.count <= Self.maximumSteps else { throw AgentXError.invalid("工作流最多包含 12 个步骤。") }
        guard Set(steps.map(\.id)).count == steps.count, steps.allSatisfy({ filled($0.id) }) else {
            throw AgentXError.invalid("工作流步骤标识为空或重复。")
        }
        if requireRunnable && (!filled(name) || steps.isEmpty) { throw AgentXError.invalid("请填写工作流名称并添加至少一个步骤。") }
        for step in steps {
            if !step.instanceID.isEmpty {
                guard instances.contains(where: { $0.id == step.instanceID && $0.appID == appID }) else {
                    throw AgentXError.invalid("步骤「\(step.name)」必须选择当前应用的成员。")
                }
            }
            if requireRunnable && (!filled(step.name) || !filled(step.instruction) || !filled(step.instanceID)) {
                throw AgentXError.invalid("请补全每个步骤的名称、成员与指令。")
            }
        }
    }
}

struct AgentXWorkflowRevision: Codable, Equatable, Identifiable {
    var number: Int
    var definition: AgentXWorkflowDefinition
    var publishedAt: Date
    var id: Int { number }
}

struct AgentXWorkflowConfiguration: Codable, Equatable {
    var draft: AgentXWorkflowDefinition? = nil
    var revisions: [AgentXWorkflowRevision] = []
    var publishedRevision: Int? = nil
    var published: AgentXWorkflowRevision? { revisions.first { $0.number == publishedRevision } }
}

struct AgentXWorkflowStepResult: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var instanceID: String
    var status: AgentXRunStatus
    var output: String = ""
    var failure: String? = nil
    var runID: String? = nil
    var startedAt: Date? = nil
    var endedAt: Date? = nil
    var actualProviderID: String? = nil
    var actualModel: String? = nil
    var runtimeCore: String? = nil
    var effectiveConfiguration: AgentXEffectiveConfiguration? = nil
}
