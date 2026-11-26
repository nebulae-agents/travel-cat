import XCTest
@testable import TravelCatApp

final class AgentXGatewayConfigurationTests: XCTestCase {
    private let yaml = """
    version: 1
    applications:
      alpha:
        provider: local
        model: fixture
        max_output_tokens: 1024
        max_request_bytes: 1048576
        timeout_seconds: 65
    """

    private func parse(_ text: String) throws -> AgentXGatewayConfiguration {
        try AgentXGatewayConfiguration.parse(Data(text.utf8))
    }

    func testValidConfiguration() throws {
        let binding = try XCTUnwrap(parse(yaml).applications["alpha"])
        XCTAssertEqual(binding.providerID, "local")
        XCTAssertEqual(binding.model, "fixture")
        XCTAssertEqual(binding.maxOutputTokens, 1024)
        XCTAssertEqual(binding.maxRequestBytes, 1048576)
        XCTAssertEqual(binding.timeoutSeconds, 65)
    }

    func testRejectsAmbiguousAndOutOfRangeConfiguration() {
        let invalid = [
            yaml.replacingOccurrences(of: "version: 1", with: "version: 2"),
            yaml.replacingOccurrences(of: "version: 1", with: "version: true"),
            yaml + "\nversion: 1", yaml + "\nunknown: value",
            yaml + "\n---\nversion: 1",
            yaml.replacingOccurrences(of: "provider: local", with: "provider: local\n    provider: other"),
            yaml.replacingOccurrences(of: "provider: local", with: "provider: local\n    secret: hidden"),
            yaml.replacingOccurrences(of: "alpha:", with: "alpha: &binding"),
            yaml + "\n  beta: *binding",
            yaml.replacingOccurrences(of: "provider: local", with: "provider: &p local"),
            yaml.replacingOccurrences(of: "provider: local", with: "&p provider: local"),
            yaml.replacingOccurrences(of: "local", with: "true"),
            yaml.replacingOccurrences(of: "fixture", with: "''"),
            yaml.replacingOccurrences(of: "1048576", with: "1048577"),
            yaml.replacingOccurrences(of: "65", with: "301")
        ] + ["true", "1.0", "'12'", "0", "-1", "65537", "99999999999999999999999999"].map {
            yaml.replacingOccurrences(of: "1024", with: $0)
        }
        for input in invalid { XCTAssertThrowsError(try parse(input), input) }
    }

    func testResolvesEnabledBindingAndRejectsInvalidReferences() throws {
        let config = try parse(yaml)
        var state = AgentXState()
        state.apps = [.init(id: "alpha", name: "Alpha", kind: .chat)]
        state.providers = [.init(id: "local", name: "Local", baseURL: "http://127.0.0.1:1234/v1", models: ["fixture"])]
        state.instances = [.init(id: "member", name: "Member", appID: "alpha", definitionID: "role", providerID: "local", model: "fixture")]
        XCTAssertEqual(try config.binding(appID: "alpha", state: state).maxOutputTokens, 1024)
        XCTAssertThrowsError(try config.binding(appID: "other", state: state))
        var invalid = state; invalid.apps[0].enabled = false
        XCTAssertThrowsError(try config.binding(appID: "alpha", state: invalid))
        invalid = state; invalid.providers[0].enabled = false
        XCTAssertThrowsError(try config.binding(appID: "alpha", state: invalid))
        invalid = state; invalid.instances[0].model = "other"
        XCTAssertThrowsError(try config.binding(appID: "alpha", state: invalid))
        invalid = state; invalid.providers[0].models = []
        XCTAssertThrowsError(try config.binding(appID: "alpha", state: invalid))
        invalid = state; invalid.instances = []
        XCTAssertThrowsError(try config.binding(appID: "alpha", state: invalid))
        invalid = state; invalid.providers.append(state.providers[0])
        XCTAssertThrowsError(try config.binding(appID: "alpha", state: invalid))
        invalid = state; invalid.instances[0].conversationModel = .init(providerID: "local", model: "other")
        XCTAssertThrowsError(try config.binding(appID: "alpha", state: invalid))
        state.providers[0].modelSelection = .init(models: [.init(id: "fixture", enabled: true, contextLength: 512)])
        XCTAssertEqual(try config.binding(appID: "alpha", state: state).maxOutputTokens, 512)
        state.providers[0].modelSelection?.models[0].available = false
        XCTAssertThrowsError(try config.binding(appID: "alpha", state: state))
    }

    func testFileLoadingFailsClosedAndRejectsSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("manager"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try AgentXGatewayConfiguration.load(root: root))
        let target = root.appendingPathComponent("manager/gateway.yaml")
        try Data(yaml.utf8).write(to: target)
        XCTAssertEqual(try AgentXGatewayConfiguration.load(root: root).applications.count, 1)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: root.appendingPathComponent("elsewhere").path)
        XCTAssertThrowsError(try AgentXGatewayConfiguration.load(root: root))
        try FileManager.default.removeItem(at: target)
        try Data(repeating: 32, count: 1_048_577).write(to: target)
        XCTAssertThrowsError(try AgentXGatewayConfiguration.load(root: root))
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        XCTAssertThrowsError(try AgentXGatewayConfiguration.load(root: root))
        try FileManager.default.removeItem(at: root.appendingPathComponent("manager"))
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try Data(yaml.utf8).write(to: other.appendingPathComponent("gateway.yaml"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("manager"), withDestinationURL: other)
        XCTAssertThrowsError(try AgentXGatewayConfiguration.load(root: root))
    }
}
