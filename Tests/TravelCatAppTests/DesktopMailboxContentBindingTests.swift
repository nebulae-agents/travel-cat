import Combine
import XCTest
import TravelCore
import TravelUI
@testable import TravelCatApp

@MainActor
final class DesktopMailboxContentBindingTests: XCTestCase {
    func testLazyWorkbenchBindingAndRemovalPreservePetSubscriptionAndRejectOldCallbacks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "MailboxBinding-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let pet = AppModel(snapshot: .empty(now: Date()), defaults: defaults)
        let first = AgentWorkbenchModel(root: root.appendingPathComponent("first"), credentials: AgentXTestCredentials(), client: MailboxBindingRuntime())
        let next = AgentWorkbenchModel(root: root.appendingPathComponent("next"), credentials: AgentXTestCredentials(), client: MailboxBindingRuntime())
        defer { first.shutdown(); next.shutdown() }
        let postcard = MailboxEntry.postcard(id: UUID(), date: Date())
        var inbox = MailboxInbox(entries: [])
        var updates = 0
        let binding = DesktopMailboxContentBinding(pet: pet, agents: nil) { agents in
            updates += 1
            inbox = MailboxInbox.project(tasks: agents?.state.tasks ?? [], pendingTaskIDs: [], postcards: [postcard])
        }
        XCTAssertEqual(inbox.entries, [postcard])
        binding.updateAgents(first)
        var completed = WorkbenchTask(instanceID: UUID(), title: "first result")
        completed.status = .completed; completed.unread = true
        first.state.tasks = [completed]
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(inbox.entries.contains { $0.title == "first result" })
        // Queue a final old-model notification, then detach before its async callback runs.
        first.objectWillChange.send()
        binding.updateAgents(nil)
        XCTAssertEqual(inbox.entries, [postcard])
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(inbox.entries, [postcard])
        let beforePetChange = updates
        pet.objectWillChange.send()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertGreaterThan(updates, beforePetChange)
        binding.updateAgents(next)
        completed.title = "fresh result"
        next.state.tasks = [completed]
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(inbox.entries.contains { $0.title == "fresh result" })
        let beforeOld = updates
        first.objectWillChange.send()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(updates, beforeOld)
        binding.shutdown()
    }
}

@MainActor private final class MailboxBindingRuntime: AgentRuntimeClient {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    func launch(python: String) throws {}
    func request(_ method: String, _ params: [String: Any], timeout: UInt64) async throws -> [String: Any] { [:] }
    func shutdown() {}
}
