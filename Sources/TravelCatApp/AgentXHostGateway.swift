import Foundation
import Darwin

enum AgentXGatewayExecutionContext {
    @TaskLocal static var requestID: String?
}

/// Gateway ownership for Controller conversations and individual workflow steps.
@MainActor
final class AgentXHostGateway {
    struct Plan: Equatable {
        let appID: String
        let instanceID: String
        let provider: AgentXProvider
        let binding: AgentXGatewayConfiguration.Binding
        let credentialProfile: String?
    }
    private let root: URL
    let budget: AgentXGatewayBudget
    private var lease: AgentXWriterRootLease?
    private let pi: AgentXPiRuntime

    init(root: URL, pi: AgentXPiRuntime, budget: AgentXGatewayBudget, lease: AgentXWriterRootLease?) {
        self.root = root; self.pi = pi; self.budget = budget; self.lease = lease
    }

    func ensureLease() throws {
        if lease == nil { lease = try AgentXWriterRootLease(root: root) }
    }

    func plan(appID: String, instanceID: String, provider: AgentXProvider, model: String, state: AgentXState) throws -> Plan? {
        let required = try budget.requiresGateway()
        var info = stat()
        if lstat(root.appendingPathComponent("manager/gateway.yaml").path, &info) == -1 {
            guard errno == ENOENT, !required else { throw AgentXBudgetFailure.unavailable }
            return nil
        }
        let binding = try AgentXGatewayConfiguration.load(root: root).binding(appID: appID, state: state)
        guard provider.id == binding.providerID, model == binding.model,
              state.providers.first(where: { $0.id == provider.id }) == provider,
              let member = state.instances.first(where: { $0.id == instanceID && $0.appID == appID }) else {
            throw AgentXError.invalid("会话或工作流模型与应用网关绑定不一致。")
        }
        // Retained for the Controller lifetime, or shared with the desktop writer.
        try ensureLease()
        return Plan(appID: appID, instanceID: instanceID, provider: provider, binding: binding,
                    credentialProfile: member.credentialProfile ?? provider.credentialProfile)
    }

    func respond(plan: Plan, runtime: AgentXTextRuntime, messages: [AgentXMessage],
                 credential: @escaping () throws -> String?) async throws -> String {
        guard let ownerRunID = AgentXPiExecutionContext.runID else { throw AgentXError.unavailable }
        let requestID = AgentXGatewayExecutionContext.requestID ?? ownerRunID
        let appID = plan.appID, budget = budget
        let proxy = try AgentXModelGateway(appID: appID, runID: requestID, provider: plan.provider, binding: plan.binding,
            credential: credential,
            beforeSubmit: { try budget.reserve(appID: appID, runID: requestID, provider: plan.provider,
                                               model: plan.binding.model, maxOutputTokens: plan.binding.maxOutputTokens) },
            onUsage: { try budget.observe(appID: appID, runID: requestID, input: $0, output: $1) },
            onComplete: { trusted in
                if trusted { try budget.complete(appID: appID, runID: requestID) }
                else { try budget.abandon(appID: appID, runID: requestID) }
            }, onClose: { try budget.abandon(appID: appID, runID: requestID) })
        defer { proxy.close() }
        do {
            let baseURL = try await proxy.start()
            return try await withTaskCancellationHandler {
                if runtime == .pi {
                    var local = plan.provider
                    local.baseURL = baseURL
                    let prepared = try pi.prepare(provider: local, model: plan.binding.model, secret: nil, messages: messages)
                    guard var payload = try JSONSerialization.jsonObject(with: prepared) as? [String: Any] else { throw AgentXError.corrupt }
                    payload["gatewayToken"] = proxy.token
                    payload["maxOutputTokens"] = plan.binding.maxOutputTokens
                    payload["timeoutSeconds"] = plan.binding.timeoutSeconds
                    // Keep the outer workflow run ID for process-stop evidence; billing uses the step ID.
                    return try await pi.execute(runID: ownerRunID, payload: JSONSerialization.data(withJSONObject: payload), progress: { _ in })
                }
                return try await Self.nativeResponse(baseURL: baseURL, token: proxy.token, model: plan.binding.model,
                                                     messages: messages, timeout: plan.binding.timeoutSeconds)
            } onCancel: { Task { @MainActor in proxy.close() } }
        } catch {
            proxy.close()
            if Task.isCancelled { throw CancellationError() }
            if let reason = proxy.budgetFailure { throw AgentXError.invalid(reason) }
            throw AgentXError.invalid("模型网关请求未完成，请检查配置、连接或请求限额。")
        }
    }

    private static func nativeResponse(baseURL: String, token: String, model: String, messages: [AgentXMessage], timeout: Int) async throws -> String {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Double(timeout)
        configuration.timeoutIntervalForResource = Double(timeout)
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: baseURL + "/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true,
            "messages": messages.map { ["role": $0.role, "content": $0.content] }])
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AgentXError.unavailable }
        var stream = AgentXGatewaySSE(secret: "")
        var answer = ""
        for try await byte in bytes {
            try Task.checkCancellation()
            let output = try stream.append(byte)
            // Only the bounded, normalized gateway frames are consumed here.
            for frame in String(decoding: output, as: UTF8.self).components(separatedBy: "\n\n") where frame.hasPrefix("data: {") {
                let fields = try JSONSerialization.jsonObject(with: Data(frame.dropFirst(6).utf8)) as? [String: Any]
                if let choices = fields?["choices"] as? [[String: Any]], let delta = choices.first?["delta"] as? [String: Any],
                   let text = delta["content"] as? String { answer += text }
            }
            if stream.finished { break }
        }
        guard stream.finished, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentXError.corrupt }
        return answer
    }
}
