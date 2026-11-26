import Foundation

enum AgentXRunProgress: Sendable {
    case text(String)
    case usage(input: Int, output: Int)
}

typealias AgentXRunProgressHandler = @MainActor @Sendable (AgentXRunProgress) throws -> Void

/// The caller owns the executing task. Cancelling it requests a stop. Only a
/// receipt for this run and process owner can confirm that the child exited.
@MainActor
protocol AgentXRunAdapter {
    var runtimeCore: String { get }
    /// Presence of required local runtime files, independent of provider availability.
    var localHealth: String { get }
    /// Capabilities of the adapter for the caller's configured streaming mode.
    func capabilities(streaming: Bool) -> [String: Bool]
    func prepare(provider: AgentXProvider, model: String, secret: String?, messages: [AgentXMessage]) throws -> Data
    func execute(runID: String, payload: Data, progress: AgentXRunProgressHandler?) async throws -> String
    func confirmedExit(runID: String) -> Bool
}
