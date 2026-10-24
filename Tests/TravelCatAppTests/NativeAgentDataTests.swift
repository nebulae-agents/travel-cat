import Foundation
import XCTest
@testable import TravelCatApp

final class NativeAgentDataTests: XCTestCase {
    func testOldSnapshotDecodesAsACPWithoutNativeFields() throws {
        let json = """
        {"schemaVersion":1,"instances":[{"id":"00000000-0000-0000-0000-000000000001","name":"old","image":"image@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","command":["acp"],"host":"","dockerContext":"","role":"","symbol":"terminal","provider":{"baseURL":"https://api.example.com/v1","model":"test","api":"responses","credentialID":"key"}}],"tasks":[],"pythonPath":"/usr/bin/python3"}
        """
        let state = try JSONDecoder().decode(WorkbenchSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(state.instances.first?.runtimeKind, .acpDocker)
        XCTAssertNil(state.instances.first?.native)
    }

    func testNativeInstanceDoesNotRequireImageOrProviderKeyOrModel() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        var instance = WorkbenchInstance(name: "Native", image: "", command: [])
        instance.native = .init(executable: "/usr/bin/true", workspace: workspace.path, model: "available-model")
        XCTAssertEqual(instance.runtimeKind, .codexNative)
        XCTAssertNoThrow(try instance.validate())
        let roundTrip = try JSONDecoder().decode(WorkbenchInstance.self, from: JSONEncoder().encode(instance))
        XCTAssertEqual(roundTrip, instance)
        instance.native?.model = ""
        XCTAssertThrowsError(try instance.validate())
    }

    func testNativeConfigurationRejectsRelativePathsAndHomeWorkspace() throws {
        XCTAssertThrowsError(try NativeRuntimeConfiguration(executable: "codex", workspace: "/tmp", model: "m").validate())
        XCTAssertThrowsError(try NativeRuntimeConfiguration(executable: "/usr/bin/true", workspace: FileManager.default.homeDirectoryForCurrentUser.path, model: "m").validate())
    }

    func testNativeItemsMergeByRuntimeIdentityWithoutDuplicatingHistory() {
        var state = NativeTaskState()
        state.upsert(.init(id: "item-1", turnID: "turn-1", kind: "agentMessage", title: "Agent", detail: "part", status: "inProgress"))
        state.upsert(.init(id: "item-1", turnID: "turn-1", kind: "agentMessage", title: "Agent", detail: "whole", status: "completed"))
        XCTAssertEqual(state.items.count, 1)
        XCTAssertEqual(state.items.first?.detail, "whole")
        XCTAssertEqual(state.connection, .disconnected)
    }

    func testCancellationRequestIsDistinctFromConfirmedTerminalState() {
        var state = NativeTaskState()
        state.pendingOperation = .init(kind: .interrupt, targetID: "turn-1")
        XCTAssertEqual(state.pendingOperation?.status, .requested)
        XCTAssertEqual(state.connection, .disconnected)
    }
    func testCapabilitiesDecodeKeepsBooleansAlongsideMetadata() throws {
        let info = try NativeConnectionInfo.decode(["connected":true,"account":["authenticated":false],
            "capabilities":["resume":true,"interrupt":true,"cost":false,"observability":"native"]])
        XCTAssertEqual(info.capabilities["resume"],true)
        XCTAssertEqual(info.capabilities["cost"],false)
    }

}
