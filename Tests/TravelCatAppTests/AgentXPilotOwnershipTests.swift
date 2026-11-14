import XCTest
@testable import TravelCatApp

@MainActor
final class AgentXPilotOwnershipTests: XCTestCase {
    private func fixture(appID: String = "pilot") throws -> (URL, AgentXRepository, AgentXState) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentXPilot-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let repository = AgentXRepository(root: directory)
        var state = AgentXState()
        state.apps.append(.init(id: appID, name: "Pilot", kind: .chat))
        state.runs = [.init(id: "one", appID: appID, instanceID: "pi", prompt: "fixture", status: .running, runtimeCore: "pi-agent-core")]
        try repository.save(state)
        let marker = ["appID": appID, "root": directory.resolvingSymlinksInPath().path]
        try JSONEncoder().encode(marker).write(to: directory.appendingPathComponent(".agentxd-pilot.json"))
        return (directory, repository, state)
    }

    func testNavigationFromStaleSnapshotPreservesServiceResult() throws {
        let (root, repo, original) = try fixture()
        var stale = original
        var result = original.runs[0]
        result.status = .completed
        result.response = "newer"
        let bytes = try JSONEncoder().encode(result)
        let file = root.appendingPathComponent("apps/pilot/runs/one.json")
        try bytes.write(to: file)
        stale.currentAppID = "pilot"
        try repo.save(stale)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testTwoProcessesAndDesktopShareMonotonicRun() async throws {
        // An opt-in read-only source supplies one historical Pi file for a real-data rehearsal.
        let source = ProcessInfo.processInfo.environment["AGENTX_PILOT_HISTORY_FIXTURE"].map(URL.init(fileURLWithPath:))
        let appID = source?.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent ?? "pilot"
        let (root, repo, _) = try fixture(appID: appID)
        let runs = root.appendingPathComponent("apps/" + appID + "/runs")
        let history = runs.appendingPathComponent(source?.lastPathComponent ?? "history.json")
        if let source {
            try FileManager.default.copyItem(at: source, to: history)
        } else {
            let run = AgentXRun(id: "history", appID: appID, instanceID: "pi", prompt: "", status: .completed)
            try JSONEncoder().encode(run).write(to: history)
        }
        let original = try Data(contentsOf: history)
        let stamp = try history.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let runtime = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Runtime")
        // Only this test fixture can advance the simulated executor. Production HTTP accepts read flags.
        let script = """
        import sys, time, threading
        from pathlib import Path
        sys.path.insert(0, sys.argv[1])
        from agentxd import serve
        def ready(store):
            def finish():
                if sys.stdin.readline().strip() == "finish":
                    store.update("one", 0, {"status": "completed", "response": "fixture answer", "endedAt": time.time()-978307200})
            threading.Thread(target=finish, daemon=True).start()
        serve(Path(sys.argv[2]), ready)
        """
        let service = Process(), commands = Pipe()
        service.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        service.arguments = ["-B", "-c", script, runtime.path, root.path]
        service.standardInput = commands
        try service.run()
        defer { if service.isRunning { service.terminate(); service.waitUntilExit() } }
        let endpoint = root.appendingPathComponent(".agentxd-endpoint.json")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: endpoint.path) && service.isRunning {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(service.isRunning)
        let originalEndpoint = try Data(contentsOf: endpoint)
        let second = Process(), diagnostic = Pipe()
        second.executableURL = service.executableURL
        second.arguments = ["-B", runtime.appendingPathComponent("agentxd.py").path, "--root", root.path]
        second.standardError = diagnostic
        try second.run()
        for _ in 0..<100 where second.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        if second.isRunning { second.terminate(); second.waitUntilExit(); XCTFail("second writer was admitted"); return }
        XCTAssertNotEqual(second.terminationStatus, 0)
        XCTAssertTrue(String(decoding: diagnostic.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("already in use"))
        XCTAssertEqual(try Data(contentsOf: endpoint), originalEndpoint)

        func openDesktop() -> AgentXController {
            AgentXController(repository: repo, credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        }
        let desktop = openDesktop(), client = try XCTUnwrap(desktop.pilot)
        await desktop.refreshPilotRuns()
        XCTAssertNil(desktop.pilotConnectionIssue)
        XCTAssertEqual(desktop.state.runs.first { $0.id == "one" }?.status, .running)
        let reopenedWhileActive = openDesktop()
        await reopenedWhileActive.refreshPilotRuns()
        XCTAssertEqual(reopenedWhileActive.state.runs.first { $0.id == "one" }?.status, .running)
        try commands.fileHandleForWriting.write(contentsOf: Data("finish\n".utf8))
        for _ in 0..<80 {
            if try await client.runs().first(where: { $0.id == "one" })?.status == .completed { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let runFile = runs.appendingPathComponent("one.json")
        let finished = try Data(contentsOf: runFile)
        XCTAssertTrue(desktop.selectApplication("blackcat"))
        XCTAssertTrue(desktop.selectApplication(appID))
        XCTAssertEqual(try Data(contentsOf: runFile), finished)
        await desktop.refreshPilotRuns()
        XCTAssertEqual(desktop.state.runs.first { $0.id == "one" }?.revision, 1)
        let external = try await client.setRead(true, id: "one", expected: 1)
        XCTAssertEqual(external.run.revision, 2)
        do { try await desktop.markRead("one"); XCTFail("stale write accepted") }
        catch { XCTAssertEqual(desktop.state.runs.first { $0.id == "one" }?.revision, 2) }
        _ = try await client.setRead(false, id: "one", expected: 2)
        await desktop.refreshPilotRuns()
        try await desktop.markRead("one")
        let reopened = openDesktop()
        await reopened.refreshPilotRuns()
        let run = try XCTUnwrap(reopened.state.runs.first { $0.id == "one" })
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.response, "fixture answer")
        XCTAssertEqual(run.revision, 4)
        XCTAssertTrue(run.isRead)

        service.terminate()
        service.waitUntilExit()
        await reopened.refreshPilotRuns()
        XCTAssertNotNil(reopened.pilotConnectionIssue)
        let beforeOfflineNavigation = try Data(contentsOf: runFile)
        XCTAssertTrue(reopened.selectApplication("blackcat"))
        XCTAssertEqual(try Data(contentsOf: runFile), beforeOfflineNavigation)
        let restart = Process()
        restart.executableURL = second.executableURL
        restart.arguments = second.arguments
        try restart.run()
        defer { if restart.isRunning { restart.terminate(); restart.waitUntilExit() } }
        for _ in 0..<100 where (try? Data(contentsOf: endpoint)) == originalEndpoint && restart.isRunning {
            try await Task.sleep(for: .milliseconds(50))
        }
        await reopened.refreshPilotRuns()
        XCTAssertNil(reopened.pilotConnectionIssue)
        let restored = try await client.runs()
        XCTAssertEqual(restored.first { $0.id == run.id }, run)
        XCTAssertEqual(try Data(contentsOf: history), original)
        XCTAssertEqual(try history.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, stamp)
        if let source { XCTAssertEqual(try Data(contentsOf: source), original) }
    }

    func testReopeningOfflineDoesNotInterruptServiceRun() throws {
        let (root, repo, _) = try fixture()
        let file = root.appendingPathComponent("apps/pilot/runs/one.json")
        let bytes = try Data(contentsOf: file)
        let controller = AgentXController(repository: repo, credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        XCTAssertTrue(controller.isLoaded)
        XCTAssertTrue(controller.selectApplication("pilot"))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertFalse(controller.state.runs.contains { $0.appID == "pilot" && $0.status == .failed })
    }
}
