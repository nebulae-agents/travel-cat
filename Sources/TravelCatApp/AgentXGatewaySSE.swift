import Foundation
import CoreFoundation

/// Emit only text, a normal finish, and explicitly reported integer usage.
/// Upstream IDs, errors, reasoning, tool calls and diagnostic metadata never pass through.
struct AgentXGatewaySSE {
    private let secret: String
    private var frame = Data()
    private var total = 0
    private var visibleBytes = 0
    private var withheld = ""
    private var sawStop = false
    private(set) var finished = false
    struct Usage: Equatable { let input: Int; let output: Int }
    private(set) var reportedUsage: Usage?
    private(set) var usageIsFinal = false
    init(secret: String) { self.secret = secret }

    mutating func append(_ byte: UInt8) throws -> Data {
        total += 1
        guard total <= 2_097_152, !finished else { throw AgentXError.corrupt }
        frame.append(byte)
        guard frame.count <= 262_144 else { throw AgentXError.corrupt }
        guard frame.suffix(2) == Data([10, 10]) || frame.suffix(4) == Data([13, 10, 13, 10]) else { return Data() }
        guard let text = String(data: frame, encoding: .utf8) else { throw AgentXError.corrupt }
        frame.removeAll(keepingCapacity: true)
        let payload = text.components(separatedBy: .newlines).filter { $0.hasPrefix("data:") }
            .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        if payload.isEmpty { return Data() }
        if payload == "[DONE]" {
            guard sawStop else { throw AgentXError.corrupt }
            finished = true
            // A partial credential prefix is harmless, but a full credential is never emitted.
            let last = withheld; withheld = ""
            return try delta(last) + encode(["choices": [["index": 0, "delta": [:], "finish_reason": "stop"]]]) + Data("data: [DONE]\n\n".utf8)
        }
        guard let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              object["error"] == nil, let choices = object["choices"] as? [[String: Any]], choices.count <= 1 else { throw AgentXError.corrupt }
        var output = Data()
        if let choice = choices.first {
            guard !sawStop else { throw AgentXError.corrupt }
            guard choice["index"] as? Int == 0, let change = choice["delta"] as? [String: Any],
                  change["tool_calls"] == nil, change["function_call"] == nil else { throw AgentXError.corrupt }
            if let finish = choice["finish_reason"], !(finish is NSNull) {
                guard let reason = finish as? String, reason == "stop", !sawStop else { throw AgentXError.corrupt }
                sawStop = true
            }
            if let value = change["content"], !(value is NSNull) {
                guard let text = value as? String else { throw AgentXError.corrupt }
                visibleBytes += text.utf8.count
                guard visibleBytes <= 65_536 else { throw AgentXError.corrupt }
                var safe = withheld + text
                if !secret.isEmpty { safe = safe.replacingOccurrences(of: secret, with: "[redacted]") }
                var retain = 0
                if secret.count > 1, !safe.isEmpty {
                    for length in 1...min(max(0, secret.count - 1), safe.count) where safe.suffix(length) == secret.prefix(length) { retain = length }
                }
                withheld = String(safe.suffix(retain))
                output += try delta(String(safe.dropLast(retain)))
            }
        }
        if let rawUsage = object["usage"], !(rawUsage is NSNull) {
            guard let usage = rawUsage as? [String: Any], reportedUsage == nil else { throw AgentXError.corrupt }
            func count(_ key: String) -> Int? {
                guard let value = usage[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                      String(cString: value.objCType) != "d", let result = Int(value.stringValue), result >= 0 else { return nil }
                return result
            }
            guard let input = count("prompt_tokens"), let completion = count("completion_tokens") else { throw AgentXError.corrupt }
            reportedUsage = Usage(input: input, output: completion)
            usageIsFinal = sawStop
            output += try encode(["choices": [], "usage": ["prompt_tokens": input, "completion_tokens": completion]])
        }
        return output
    }
    private func delta(_ text: String) throws -> Data {
        text.isEmpty ? Data() : try encode(["choices": [["index": 0, "delta": ["content": text], "finish_reason": NSNull()]]])
    }
    private func encode(_ value: [String: Any]) throws -> Data {
        Data("data: ".utf8) + (try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) + Data("\n\n".utf8)
    }
}
