import Foundation

enum AgentXBudgetFailure: Error, LocalizedError {
    case invalid, exceeded, duplicate, unavailable, boundaryExceeded
    var errorDescription: String? {
        switch self {
        case .exceeded: "日预算不足，未提交模型请求。"
        case .duplicate: "此运行已有预算记录，禁止再次提交。"
        case .boundaryExceeded: "上游用量超出配置边界，预算已停止新调用。"
        case .invalid: "预算、价格或模型上下文配置无效，未提交模型请求。"
        case .unavailable: "预算账本不可用，已停止新调用。"
        }
    }
}

/// Exact 10^-12 currency units; JSON stores integer units as strings, never IEEE doubles.
struct AgentXBudgetMoney: Codable, Equatable, Comparable, CustomStringConvertible {
    let units: Int64
    static let scale: Int64 = 1_000_000_000_000
    static let zero = Self(units: 0)
    init(units: Int64) { self.units = units }
    init(_ text: String) throws {
        guard text.wholeMatch(of: /(?:0|[1-9][0-9]{0,5})(?:\.[0-9]{1,12})?/) != nil else { throw AgentXBudgetFailure.invalid }
        let parts = text.split(separator: ".")
        let whole = Int64(parts[0])!
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        self.units = whole * Self.scale + (Int64(fraction + String(repeating: "0", count: 12 - fraction.count)) ?? 0)
    }
    func adding(_ other: Self) throws -> Self {
        let result = units.addingReportingOverflow(other.units)
        guard !result.overflow, result.partialValue >= 0 else { throw AgentXBudgetFailure.invalid }
        return Self(units: result.partialValue)
    }
    func multiplied(by count: Int) throws -> Self {
        guard count >= 0, let count = Int64(exactly: count) else { throw AgentXBudgetFailure.invalid }
        let result = units.multipliedReportingOverflow(by: count)
        guard !result.overflow, result.partialValue >= 0 else { throw AgentXBudgetFailure.invalid }
        return Self(units: result.partialValue)
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.units < rhs.units }
    var description: String {
        let whole = units / Self.scale, fraction = units % Self.scale
        guard fraction != 0 else { return String(whole) }
        var tail = String(format: "%012lld", fraction)
        while tail.last == "0" { tail.removeLast() }
        return "\(whole).\(tail)"
    }
    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard text.wholeMatch(of: /(?:0|[1-9][0-9]{0,18})/) != nil, let value = Int64(text) else { throw AgentXBudgetFailure.invalid }
        units = value
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(String(units))
    }
}

struct AgentXBudgetConfiguration {
    struct Price: Codable, Equatable {
        let input: AgentXBudgetMoney
        let output: AgentXBudgetMoney
        let source: String
        let revision: String
        func cost(input count: Int, output completion: Int) throws -> AgentXBudgetMoney {
            try input.multiplied(by: count).adding(output.multiplied(by: completion))
        }
    }
    let currency: String
    let timeZone: String
    let limit: AgentXBudgetMoney
    let prices: [String: [String: Price]]

    static func parse(_ data: Data) throws -> Self {
        let fields = try AgentXGatewayConfiguration.object(data)
        guard Set(fields.keys) == ["version", "currency", "time_zone", "daily_limit", "prices"],
              let version = fields["version"], type(of: version) == Int.self, version as? Int == 1,
              let currency = fields["currency"] as? String, currency.wholeMatch(of: /[A-Z]{3}/) != nil,
              let zone = fields["time_zone"] as? String, TimeZone(identifier: zone) != nil,
              let limit = fields["daily_limit"] as? String,
              let rates = fields["prices"] as? [String: [String: [String: Any]]] else { throw AgentXBudgetFailure.invalid }
        var prices: [String: [String: Price]] = [:]
        for (provider, models) in rates {
            try AgentXPackageFiles.validateID(provider)
            for (model, row) in models {
                guard !model.isEmpty, model.utf8.count <= 512,
                      Set(row.keys) == ["input_per_token", "output_per_token", "source", "revision"],
                      let input = row["input_per_token"] as? String, let output = row["output_per_token"] as? String,
                      let source = row["source"] as? String, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, source.utf8.count <= 512,
                      let revision = row["revision"] as? String, !revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, revision.utf8.count <= 128 else { throw AgentXBudgetFailure.invalid }
                prices[provider, default: [:]][model] = try Price(input: AgentXBudgetMoney(input), output: AgentXBudgetMoney(output), source: source, revision: revision)
            }
        }
        let amount = try AgentXBudgetMoney(limit)
        guard amount > .zero else { throw AgentXBudgetFailure.invalid }
        return Self(currency: currency, timeZone: zone, limit: amount, prices: prices)
    }
}
