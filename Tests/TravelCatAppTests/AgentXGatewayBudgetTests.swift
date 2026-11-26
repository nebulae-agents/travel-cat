import XCTest
@testable import TravelCatApp

@MainActor
final class AgentXGatewayBudgetTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("manager"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try policy(root)
        return root
    }
    private func policy(_ root: URL, limit: String = "0.200", currency: String = "USD", zone: String = "Asia/Shanghai") throws {
        let json: [String: Any] = ["version": 1, "currency": currency, "time_zone": zone, "daily_limit": limit,
            "prices": ["p": ["m": ["input_per_token": "0.001", "output_per_token": "0.002", "source": "fixture", "revision": "v1"]]]]
        try JSONSerialization.data(withJSONObject: json).write(to: root.appendingPathComponent("manager/gateway-budget.yaml"))
    }
    private var provider: AgentXProvider {
        .init(id: "p", name: "P", baseURL: "http://127.0.0.1:1/v1", models: ["m"],
              modelSelection: .init(models: [.init(id: "m", enabled: true, contextLength: 100)]))
    }
    private func reserve(_ budget: AgentXGatewayBudget, app: String = "alpha", run: String = "run-1") throws {
        try budget.reserve(appID: app, runID: run, provider: provider, model: "m", maxOutputTokens: 23)
    }
    func testPresentationRefreshUsesConfiguredDay() throws {
        let root = try fixture()
        var now = Date(timeIntervalSince1970: 0)
        let budget = AgentXGatewayBudget(root: root, now: { now })
        XCTAssertEqual(try budget.presentation().day, "1970-01-01")
        now = Date(timeIntervalSince1970: 86_400)
        XCTAssertEqual(try budget.presentation().day, "1970-01-02")
    }

    func testPresentationDoesNotRepairMissingSealOrReleaseHeldMoney() throws {
        let root = try fixture(), budget = AgentXGatewayBudget(root: root)
        try reserve(budget)
        let before = try Data(contentsOf: root.appendingPathComponent("manager/gateway-budget-v1/ledger.json"))
        let snapshot = try budget.presentation()
        XCTAssertEqual(snapshot.held, "0.146")
        XCTAssertEqual(snapshot.available, "0.054")
        try budget.saveLimit("0.1", expectedSource: XCTUnwrap(snapshot.source))
        XCTAssertEqual(try budget.presentation().available, "0")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("manager/gateway-budget-v1/ledger.json")), before)
        let seal = root.appendingPathComponent("manager/.gateway-budget-v1")
        try FileManager.default.removeItem(at: seal)
        XCTAssertThrowsError(try budget.presentation())
        XCTAssertFalse(FileManager.default.fileExists(atPath: seal.path))
    }
    func testDisabledPresentationAndInvalidLimitCannotCreatePolicy() throws {
        let root = try fixture()
        let path = root.appendingPathComponent("manager/gateway-budget.yaml")
        try FileManager.default.removeItem(at: path)
        let budget = AgentXGatewayBudget(root: root)
        XCTAssertEqual(try budget.presentation().status, "disabled")
        XCTAssertThrowsError(try budget.saveLimit("1", expectedSource: Data()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testPresentationIsReadOnlyAndLimitSavePreservesPolicy() throws {
        let root = try fixture(), budget = AgentXGatewayBudget(root: root)
        let first = try budget.presentation()
        XCTAssertEqual(first.available, "0.2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("manager/gateway-budget-v1").path))
        let source = try XCTUnwrap(first.source)
        try budget.saveLimit("0.300", expectedSource: source)
        let next = try budget.presentation()
        XCTAssertEqual(next.limit, "0.3")
        XCTAssertThrowsError(try budget.saveLimit("0.4", expectedSource: source))
        XCTAssertThrowsError(try budget.saveLimit("0", expectedSource: XCTUnwrap(next.source)))
        let before = try AgentXBudgetConfiguration.parse(source)
        let after = try AgentXBudgetConfiguration.parse(XCTUnwrap(next.source))
        XCTAssertEqual(before.prices, after.prices)
        XCTAssertEqual(before.currency, after.currency)
        XCTAssertEqual(before.timeZone, after.timeZone)
    }

    func testExactDecimalAmountsAndInvalidValues() throws {
        XCTAssertEqual(try AgentXBudgetMoney("0.000000000001").units, 1)
        XCTAssertEqual(try AgentXBudgetMoney("0.146").description, "0.146")
        for value in ["1e-3", "-1", "+1", "01", "NaN", "1.0000000000001", "1000000", ""] {
            XCTAssertThrowsError(try AgentXBudgetMoney(value))
        }
    }
    func testBudgetPolicyRequiresExplicitPricesCurrencyAndTimezone() throws {
        let root = try fixture()
        let source = try Data(contentsOf: root.appendingPathComponent("manager/gateway-budget.yaml"))
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: source) as? [String: Any])
        for (key, value): (String, Any) in [("daily_limit", 0.2), ("currency", "usd"), ("time_zone", "not/a/zone"), ("version", true), ("extra", "ignored")] {
            var input = valid; input[key] = value
            XCTAssertThrowsError(try AgentXBudgetConfiguration.parse(JSONSerialization.data(withJSONObject: input)))
        }
        XCTAssertThrowsError(try AgentXBudgetMoney("999999").multiplied(by: Int.max))
        var tiered = provider; tiered.modelSelection?.models[0].hasTieredPricing = true
        XCTAssertThrowsError(try AgentXGatewayBudget(root: root).reserve(appID: "alpha", runID: "tiered", provider: tiered, model: "m", maxOutputTokens: 23))
    }

    func testSharedReservationSurvivesRestartAndOnlySettlementReleasesDifference() throws {
        let root = try fixture()
        var budget = AgentXGatewayBudget(root: root)
        try reserve(budget)
        XCTAssertThrowsError(try reserve(budget, app: "beta"))
        budget = AgentXGatewayBudget(root: root)
        XCTAssertThrowsError(try reserve(budget, app: "beta"))
        try budget.observe(appID: "alpha", runID: "run-1", input: 11, output: 3)
        try budget.complete(appID: "alpha", runID: "run-1")
        try budget.complete(appID: "alpha", runID: "run-1")
        XCTAssertEqual(try budget.receipt(appID: "alpha", runID: "run-1")?["actual"] as? String, "0.017")
        try reserve(budget, app: "beta")
        XCTAssertThrowsError(try reserve(budget, app: "alpha"))
        XCTAssertEqual(try budget.summary()["held"] as? String, "0.146")
    }
    func testCancellationAndMissingUsageKeepReservation() throws {
        let root = try fixture(), budget = AgentXGatewayBudget(root: root)
        try reserve(budget)
        try budget.abandon(appID: "alpha", runID: "run-1")
        try budget.abandon(appID: "alpha", runID: "run-1")
        XCTAssertEqual(try budget.receipt(appID: "alpha", runID: "run-1")?["status"] as? String, "pending")
        XCTAssertThrowsError(try reserve(budget, app: "beta"))
        try budget.complete(appID: "alpha", runID: "run-1")
        XCTAssertEqual(try budget.summary()["held"] as? String, "0.146")
    }
    func testCrossDaySettlementStaysOnReservationDayAndPolicyIdentityCannotChange() throws {
        let root = try fixture()
        var now = ISO8601DateFormatter().date(from: "2026-11-25T15:59:00Z")!
        let budget = AgentXGatewayBudget(root: root, now: { now })
        try reserve(budget)
        now += 120
        try reserve(budget, app: "beta")
        try budget.observe(appID: "alpha", runID: "run-1", input: 11, output: 3)
        try budget.complete(appID: "alpha", runID: "run-1")
        XCTAssertEqual(try budget.receipt(appID: "alpha", runID: "run-1")?["day"] as? String, "2026-11-25")
        XCTAssertEqual(try budget.summary()["held"] as? String, "0.146")
        XCTAssertEqual(try budget.summary()["spent"] as? String, "0")
        try policy(root, currency: "EUR")
        XCTAssertThrowsError(try reserve(budget, run: "new"))
        try policy(root, zone: "UTC")
        XCTAssertThrowsError(try reserve(budget, run: "new"))
    }
    func testMissingOrCorruptLedgerAndRemovedPolicyNeverResetBudget() throws {
        let root = try fixture(), budget = AgentXGatewayBudget(root: root)
        try reserve(budget)
        try FileManager.default.removeItem(at: root.appendingPathComponent("manager/gateway-budget.yaml"))
        XCTAssertThrowsError(try reserve(AgentXGatewayBudget(root: root), app: "beta"))
        try policy(root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("manager/gateway-budget-v1/ledger.json"))
        XCTAssertThrowsError(try reserve(AgentXGatewayBudget(root: root), app: "beta"))
    }
    func testUnknownBoundPriceAndOverrunFailClosed() throws {
        let root = try fixture(), budget = AgentXGatewayBudget(root: root)
        var unknown = provider; unknown.modelSelection = nil
        XCTAssertThrowsError(try budget.reserve(appID: "alpha", runID: "unknown", provider: unknown, model: "m", maxOutputTokens: 23))
        XCTAssertThrowsError(try budget.reserve(appID: "alpha", runID: "missing", provider: provider, model: "other", maxOutputTokens: 23))
        try reserve(budget)
        XCTAssertThrowsError(try budget.observe(appID: "alpha", runID: "run-1", input: 101, output: 23))
        XCTAssertThrowsError(try reserve(AgentXGatewayBudget(root: root), app: "beta"))
    }
    func testOverflowAndLossOfBothManagerMarkersCannotRestoreCredit() throws {
        let root = try fixture(); try policy(root, limit: "10")
        let budget = AgentXGatewayBudget(root: root)
        try reserve(budget)
        XCTAssertThrowsError(try budget.observe(appID: "alpha", runID: "run-1", input: Int.max, output: 23))
        XCTAssertThrowsError(try reserve(AgentXGatewayBudget(root: root), app: "beta"))
        let other = try fixture(), live = AgentXGatewayBudget(root: other)
        try policy(other, limit: "10")
        try reserve(live)
        try FileManager.default.removeItem(at: other.appendingPathComponent("manager/gateway-budget-v1"))
        try FileManager.default.removeItem(at: other.appendingPathComponent("manager/.gateway-budget-v1"))
        XCTAssertThrowsError(try reserve(live, app: "beta"))
        XCTAssertThrowsError(try reserve(AgentXGatewayBudget(root: other), app: "gamma"))
    }

    func testReadOnlyLedgerDirectoryPoisonsWriterWithoutLosingReservation() throws {
        let root = try fixture(); try policy(root, limit: "1")
        let budget = AgentXGatewayBudget(root: root)
        try reserve(budget)
        let directory = root.appendingPathComponent("manager/gateway-budget-v1")
        let ledger = directory.appendingPathComponent("ledger.json")
        let before = try Data(contentsOf: ledger)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        XCTAssertThrowsError(try reserve(budget, app: "beta"))
        XCTAssertEqual(try Data(contentsOf: ledger), before)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try reserve(budget, app: "beta"))
        XCTAssertEqual(try AgentXGatewayBudget(root: root).summary()["held"] as? String, "0.146")
    }

}
