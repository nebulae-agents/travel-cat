import XCTest
@testable import TravelCatApp

@MainActor
final class AgentXPilotOwnershipTests: XCTestCase {
    private func fixture(appID: String = "pilot") throws -> (URL, AgentXRepository, AgentXState) {
        let directory = URL(fileURLWithPath: "/private/tmp/AgentXPilot-\(UUID())")
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

    private func twoAppFixture() throws -> (URL, AgentXRepository, AgentXState) {
        let (root, repo, original) = try fixture()
        let marker = root.appendingPathComponent(".agentxd-pilot.json")
        try FileManager.default.removeItem(at: marker)
        var stale = original
        stale.apps.append(.init(id: "second", name: "Second", kind: .chat))
        stale.providers = [.init(id: "provider", name: "Provider", baseURL: "https://openrouter.ai/api/v1", models: ["model"])]
        stale.definitions = [.init(id: "definition", name: "Definition", prompt: "system")]
        stale.instances = [.init(id: "member", name: "Member", appID: "second", definitionID: "definition", providerID: "provider", model: "model")]
        stale.runs.append(.init(id: "two", appID: "second", instanceID: "member", prompt: "fixture", status: .running))
        try repo.save(stale)
        let managed: [[String: Any]] = [
            ["appID": "pilot"],
            ["appID": "second", "pi": ["instanceID": "member", "providerID": "provider", "model": "model",
                                     "baseURL": "https://openrouter.ai/api/v1", "systemPrompt": "system"]]
        ]
        try JSONSerialization.data(withJSONObject: ["root": root.path, "version": 2, "apps": managed]).write(to: marker)
        return (root, repo, stale)
    }

    func testLegacyCutoverWaitsForTheOwnerAndRevokesReferenceAuditSessions() throws {
        let root = URL(fileURLWithPath: "/private/tmp/AgentXPilot-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(".agentxd-pilot.json")
        let original = try JSONEncoder().encode(["appID": "pilot", "root": root.path])
        try original.write(to: url)
        let credentials = AgentXTestCredentials()
        let helper = try AgentXAuditHelper(root: root.path, appID: "pilot", credentials: credentials)
        let request = Data(#"{"op":"verify"}"#.utf8)
        XCTAssertEqual(try helper.execute(request)["ok"] as? Bool, true)
        try withExtendedLifetime(AgentXWriterRootLease(root: root)) { _ in
            XCTAssertThrowsError(try AgentXPilot.takeDesktopLease(at: root))
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
        try withExtendedLifetime(AgentXPilot.takeDesktopLease(at: root)) { _ in
            XCTAssertTrue(try XCTUnwrap(AgentXPilot.configured(at: root)).usesDesktopWriter)
            XCTAssertThrowsError(try AgentXWriterRootLease(root: root))
            XCTAssertThrowsError(try helper.execute(request))
            XCTAssertThrowsError(try AgentXAuditHelper(root: root.path, appID: "pilot", credentials: credentials))
        }
    }

    func testWrongDeclaredRootCannotBePromoted() throws {
        let (root, _, _) = try fixture()
        let url = root.appendingPathComponent(".agentxd-pilot.json")
        let wrong = try JSONEncoder().encode(["appID": "pilot", "root": root.deletingLastPathComponent().path])
        try wrong.write(to: url)
        XCTAssertThrowsError(try AgentXPilot.takeDesktopLease(at: root))
        XCTAssertEqual(try Data(contentsOf: url), wrong)
        XCTAssertNoThrow(try AgentXWriterRootLease(root: root))
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

    func testTwoOwnedAppsPreserveRunFilesWhenDesktopSnapshotIsStaleAndServiceIsOffline() async throws {
        let (root, repo, stale) = try twoAppFixture()
        var authoritative = stale.runs
        let files = try authoritative.indices.map { index -> URL in
            authoritative[index].status = .completed
            authoritative[index].response = "from service"
            let run = authoritative[index]
            let file = root.appendingPathComponent("apps/\(run.appID)/runs/\(run.id).json")
            try JSONEncoder().encode(run).write(to: file)
            return file
        }
        let expected = try files.map { try Data(contentsOf: $0) }
        try repo.save(stale)
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, expected)
        let desktop = AgentXController(repository: repo, credentials: AgentXTestCredentials(), respond: { _, _, _, _ in
            XCTFail("agentxd-owned member used the desktop responder while offline")
            return ""
        }, autoRefreshCatalogs: false)
        XCTAssertTrue(desktop.isLoaded)
        XCTAssertTrue(desktop.selectApplication("second"))
        await desktop.refreshPilotRuns()
        XCTAssertNotNil(desktop.pilotConnectionIssue)
        XCTAssertTrue(desktop.currentRuns.isEmpty)
        desktop.drafts["member"] = "second app"
        desktop.send("second app", instanceID: "member")
        for _ in 0..<100 where desktop.errorMessage == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(desktop.errorMessage)
        XCTAssertEqual(desktop.drafts["member"], "second app")
        XCTAssertTrue(desktop.currentRuns.isEmpty)
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, expected)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("apps/second/runs").path), ["two.json"])
    }

    func testTwoOwnedAppsRefreshAndUpdateReadFlagsThroughAgentxd() async throws {
        let (root, repo, original) = try twoAppFixture()
        for var run in original.runs {
            run.status = .completed
            let file = root.appendingPathComponent("apps/\(run.appID)/runs/\(run.id).json")
            try JSONEncoder().encode(run).write(to: file)
        }

        let runtime = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Runtime")
        let daemon = Process()
        daemon.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        daemon.arguments = ["-B", runtime.deletingLastPathComponent().appendingPathComponent("Tests/AgentRuntimeTests/agentxd_reference.py").path, "--root", root.path]
        try daemon.run()
        defer { if daemon.isRunning { daemon.terminate(); daemon.waitUntilExit() } }
        let endpoint = root.appendingPathComponent(".agentxd-endpoint.json")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: endpoint.path) && daemon.isRunning {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard FileManager.default.fileExists(atPath: endpoint.path) else { return XCTFail("agentxd did not publish its endpoint") }

        let controller = AgentXController(repository: repo, credentials: AgentXTestCredentials(), autoRefreshCatalogs: false)
        XCTAssertTrue(controller.currentRuns.isEmpty)
        await controller.refreshPilotRuns()
        XCTAssertEqual(Set(controller.state.runs.map(\.appID)), ["pilot", "second"])

        XCTAssertTrue(controller.selectApplication("pilot"))
        try await controller.markAllRead()
        XCTAssertEqual(controller.currentRuns.map(\.isRead), [true])
        XCTAssertTrue(controller.selectApplication("second"))
        XCTAssertEqual(controller.currentRuns.map(\.isRead), [false])
        try await controller.undoLastChange()
        XCTAssertEqual(controller.state.runs.first { $0.appID == "pilot" }?.revision, 2)
        XCTAssertEqual(controller.currentRuns.map(\.revision), [0])

        let second = try XCTUnwrap(controller.pilot(for: "second"))
        let external = try await second.setRead(true, id: "two", expected: 0)
        XCTAssertEqual(external.run.revision, 1)
        do {
            try await controller.markRead("two")
            XCTFail("stale revision accepted")
        } catch {
            XCTAssertEqual(controller.currentRuns.map(\.revision), [1])
            XCTAssertEqual(controller.currentRuns.map(\.isRead), [true])
        }
        _ = try await second.setRead(false, id: "two", expected: 1)
        await controller.refreshPilotRuns()
        XCTAssertEqual(controller.currentRuns.map(\.revision), [2])
        XCTAssertEqual(controller.currentRuns.map(\.isRead), [false])

        daemon.terminate()
        daemon.waitUntilExit()
        let file = root.appendingPathComponent("apps/second/runs/two.json")
        let before = try Data(contentsOf: file)
        await controller.refreshPilotRuns()
        XCTAssertNotNil(controller.pilotConnectionIssue)
        do { try await controller.markRead("two"); XCTFail("offline read mutation fell back to desktop") }
        catch { XCTAssertEqual(controller.currentRuns.map(\.isRead), [false]) }
        XCTAssertTrue(controller.selectApplication("blackcat"))
        XCTAssertNil(controller.pilotConnectionIssue)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testVersionTwoMarkerRejectsInvalidMembership() throws {
        let (root, _, _) = try fixture()
        let marker = root.appendingPathComponent(".agentxd-pilot.json")
        let invalidFields = [
            #""version":2,"apps":[]"#,
            #""version":2,"apps":[{"appID":"pilot"},{"appID":"pilot"}]"#,
            #""version":2,"apps":[{"appID":"pilot"},{"appID":"Pilot"}]"#,
            #""version":2,"apps":[{"appID":"blackcat"}]"#,
            #""version":2,"apps":[{"appID":"workbench"}]"#,
            #""version":2,"apps":[{"appID":"a/b"}]"#,
            #""version":2,"apps":[{"appID":"pilot","pi":null}]"#,
            #""version":2,"apps":[{"appID":"pilot"}],"appID":null"#,
            #""version":2,"apps":[{"appID":"pilot"}],"pi":null"#,
            #""version":2.0,"apps":[{"appID":"pilot"}]"#,
            #""version":"2","apps":[{"appID":"pilot"}]"#
        ]
        let rootJSON = String(decoding: try JSONEncoder().encode(root.path), as: UTF8.self)
        for fields in invalidFields {
            try Data("{\"root\":\(rootJSON),\(fields)}".utf8).write(to: marker)
            XCTAssertThrowsError(try AgentXPilot.configured(at: root), fields)
        }
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
        second.arguments = ["-B", runtime.deletingLastPathComponent().appendingPathComponent("Tests/AgentRuntimeTests/agentxd_reference.py").path, "--root", root.path]
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
        let desktop = openDesktop(), client = try XCTUnwrap(desktop.pilot(for: appID))
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
        XCTAssertTrue(reopened.selectApplication(appID))
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
