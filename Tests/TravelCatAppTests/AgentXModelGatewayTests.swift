import XCTest
@testable import TravelCatApp

@MainActor
final class AgentXModelGatewayTests: XCTestCase {
    private let secret = "fixture-upstream-private"
    private func gateway(now: @escaping () -> Date = { Date() }, credential: @escaping () throws -> String? = { "fixture-upstream-private" }) throws -> AgentXModelGateway {
        try AgentXModelGateway(appID: "alpha", runID: "run-1",
            provider: .init(id: "p", name: "P", baseURL: "http://127.0.0.1:12345/v1", models: ["m"]),
            binding: .init(providerID: "p", model: "m", maxOutputTokens: 23, maxRequestBytes: 1024, timeoutSeconds: 2),
            credential: credential, now: now)
    }
    private func body(model: String = "m", extra: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model": model, "messages": [["role": "user", "content": "hello"]],
            "stream": true, "max_tokens": 1024].merging(extra) { _, new in new })
    }
    func testCredentialIsResolvedOnlyForOneValidBoundSubmission() throws {
        var reads = 0
        let gateway = try gateway(credential: { reads += 1; return self.secret })
        defer { gateway.close() }
        XCTAssertThrowsError(try gateway.upstreamRequest(path: gateway.path, token: "wrong", body: body()))
        XCTAssertThrowsError(try gateway.upstreamRequest(path: "/v1/apps/beta/runs/run-1/chat/completions", token: gateway.token, body: body()))
        XCTAssertThrowsError(try gateway.upstreamRequest(path: gateway.path, token: gateway.token, body: body(model: "other")))
        XCTAssertEqual(reads, 0)
        let request = try gateway.upstreamRequest(path: gateway.path, token: gateway.token, body: body())
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:12345/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + secret)
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(output["max_tokens"] as? Int, 23)
        XCTAssertNil(output["tools"])
        XCTAssertThrowsError(try gateway.upstreamRequest(path: gateway.path, token: gateway.token, body: body()))
        XCTAssertEqual(reads, 1)
    }
    func testRevocationExpiryAndCredentialFailureCannotBeRetried() throws {
        var time = Date()
        let expired = try gateway(now: { time })
        defer { expired.close() }
        time += 3
        XCTAssertThrowsError(try expired.upstreamRequest(path: expired.path, token: expired.token, body: body()))
        let revoked = try gateway(); revoked.close()
        XCTAssertThrowsError(try revoked.upstreamRequest(path: revoked.path, token: revoked.token, body: body()))
        var reads = 0
        let failed = try gateway(credential: { reads += 1; throw AgentXError.unavailable })
        defer { failed.close() }
        XCTAssertThrowsError(try failed.upstreamRequest(path: failed.path, token: failed.token, body: body()))
        XCTAssertThrowsError(try failed.upstreamRequest(path: failed.path, token: failed.token, body: body()))
        XCTAssertEqual(reads, 1)
    }
    func testUnknownFieldsToolsAndOversizedRequestsDoNotReadCredentials() throws {
        var reads = 0
        let gateway = try gateway(credential: { reads += 1; return self.secret })
        defer { gateway.close() }
        for extra: [String: Any] in [["tools": []], ["url": "https://other.test"], ["headers": ["x": "y"]], ["stream": false], ["stream": 1]] {
            XCTAssertThrowsError(try gateway.upstreamRequest(path: gateway.path, token: gateway.token, body: body(extra: extra)))
        }
        XCTAssertThrowsError(try gateway.upstreamRequest(path: gateway.path, token: gateway.token, body: Data(repeating: 32, count: 1025)))
        XCTAssertEqual(reads, 0)
    }
    func testDoneDoesNotInventASuccessfulFinish() throws {
        for payload in ["data: [DONE]\n\n", "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":7}]}\n\ndata: [DONE]\n\n"] {
            var stream = AgentXGatewaySSE(secret: "")
            XCTAssertThrowsError(try Data(payload.utf8).forEach { _ = try stream.append($0) })
        }
    }

    func testAbnormalTailCannotKeepTrustedFinalUsage() throws {
        let prefix = "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: {\"choices\":[],\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":3}}\n\n"
        for tail in ["data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"more\"}}]}\n\n",
                     "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":\"unknown\"}}\n\n"] {
            var stream = AgentXGatewaySSE(secret: "")
            XCTAssertThrowsError(try Data((prefix + tail + "data: [DONE]\n\n").utf8).forEach { _ = try stream.append($0) })
        }
    }

    func testStreamFiltersMetadataAndRedactsSecretsSplitAcrossDeltas() throws {
        var stream = AgentXGatewaySSE(secret: secret)
        var output = Data()
        for text in ["猫🐾 ", "fixture-up", "stream-private", " done"] {
            let frame = try JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "delta": ["content": text]]]])
            for byte in Data("data: ".utf8) + frame + Data("\n\n".utf8) { output += try stream.append(byte) }
        }
        for byte in Data("data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: {\"choices\":[],\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":3}}\n\ndata: [DONE]\n\n".utf8) { output += try stream.append(byte) }
        XCTAssertTrue(stream.finished)
        let text = String(decoding: output, as: UTF8.self)
        XCTAssertFalse(text.contains(secret))
        XCTAssertTrue(text.contains("[redacted]"))
        XCTAssertTrue(text.contains("猫🐾"))
        XCTAssertTrue(text.contains("prompt_tokens"))
    }
}
