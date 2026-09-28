import Foundation
import XCTest
@testable import TravelCatApp

private final class ProviderFixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor final class OpenAICompatibleTravelClientTests: XCTestCase {
    private func client() -> OpenAICompatibleTravelClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderFixtureProtocol.self]
        return OpenAICompatibleTravelClient(session: URLSession(configuration: configuration))
    }
    private func envelope(_ content: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
    }
    func testTextSendsCredentialOnlyToConfiguredEndpointAndUnwrapsJSON() async throws {
        let data = envelope("```json\n{\"ok\":true}\n```")
        ProviderFixtureProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://provider.example/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            return (200, data)
        }
        let result = try await client().text(baseURL: URL(string: "https://provider.example/v1")!, model: "m", apiKey: "secret", prompt: "test")
        XCTAssertEqual(String(decoding: result, as: UTF8.self), "{\"ok\":true}")
    }
    func testRejectsUnsafeBaseBeforeNetwork() async {
        ProviderFixtureProtocol.handler = { _ in XCTFail("Must not send"); return (200, Data()) }
        for value in ["http://example.com/v1", "https://user:secret@example.com/v1", "https://example.com/v1?token=secret", "https://example.com/#secret"] {
            do { _ = try await client().text(baseURL: URL(string: value)!, model: "m", apiKey: nil, prompt: "p"); XCTFail() } catch { XCTAssertFalse(error.localizedDescription.contains("secret")) }
        }
    }
    func testRejectsNonObjectAndMalformedAssistantContent() async {
        for content in ["[]", "not JSON", "{broken}"] {
            let data = envelope(content)
            ProviderFixtureProtocol.handler = { _ in (200, data) }
            do { _ = try await client().text(baseURL: URL(string: "http://localhost:1234/v1")!, model: "m", apiKey: nil, prompt: "p"); XCTFail() } catch {}
        }
    }
    func testRedactsProviderErrorsAndRejectsLargeResponses() async {
        for (status, data) in [(401, Data("secret-provider-body".utf8)), (200, Data(repeating: 32, count: 1_048_577))] {
            ProviderFixtureProtocol.handler = { _ in (status, data) }
            do { _ = try await client().text(baseURL: URL(string: "https://provider.example/v1")!, model: "m", apiKey: nil, prompt: "p"); XCTFail() } catch { XCTAssertFalse(error.localizedDescription.contains("secret")) }
        }
    }
    func testCancellationBeforeRequest() async {
        let client = client()
        let task = Task { try await client.text(baseURL: URL(string: "https://provider.example/v1")!, model: "m", apiKey: nil, prompt: "p") }
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testImageURLDownloadNeverReceivesAPIKey() async throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a6z8AAAAASUVORK5CYII=")!
        ProviderFixtureProtocol.handler = { request in
            if request.url?.host == "provider.example" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
                return (200, Data(#"{"data":[{"url":"https://cdn.example/image.png?signature=opaque"}]}"#.utf8))
            }
            XCTAssertEqual(request.url?.host, "cdn.example")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, png)
        }
        let output = try await client().image(baseURL: URL(string: "https://provider.example/v1")!, model: "gpt-image-1", apiKey: "secret", prompt: "cat", referenceImages: [], useEdits: false)
        XCTAssertEqual(output, png)
    }
    func testRejectsToolCallsAndRedirectStatus() async {
        for (status, data) in [(200, Data(#"{"choices":[{"message":{"content":"{}","tool_calls":[]}}]}"#.utf8)), (302, Data())] {
            ProviderFixtureProtocol.handler = { _ in (status, data) }
            do { _ = try await client().text(baseURL: URL(string: "https://provider.example/v1")!, model: "m", apiKey: nil, prompt: "p"); XCTFail() } catch {}
        }
    }
    func testRemoteProviderCannotDownloadHTTPImage() async {
        ProviderFixtureProtocol.handler = { _ in (200, Data(#"{"data":[{"url":"http://localhost/image.png"}]}"#.utf8)) }
        do { _ = try await client().image(baseURL: URL(string: "https://provider.example/v1")!, model: "m", apiKey: nil, prompt: "p", referenceImages: [], useEdits: false); XCTFail() } catch {}
    }

    func testNativeImageGenerationFieldsAndBase64() async throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a6z8AAAAASUVORK5CYII=")!
        ProviderFixtureProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/images/generations")
            var requestData = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    requestData.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try JSONSerialization.jsonObject(with: requestData) as! [String: Any]
            XCTAssertEqual(body["output_format"] as? String, "png")
            XCTAssertNil(body["response_format"])
            XCTAssertEqual(body["size"] as? String, "1536x1024")
            XCTAssertEqual(body["n"] as? Int, 1)
            return (200, try JSONSerialization.data(withJSONObject: ["data": [["b64_json": png.base64EncodedString()]]]))
        }
        let output = try await client().image(baseURL: URL(string: "https://provider.example/v1")!, model: "gpt-image-1", apiKey: nil, prompt: "cat", referenceImages: [], useEdits: false)
        XCTAssertEqual(output, png)
    }
    func testTransportErrorsAreRedactedAndCancellationPreserved() async {
        for code in [URLError.timedOut, .cannotConnectToHost, .cancelled] {
            ProviderFixtureProtocol.handler = { _ in throw URLError(code, userInfo: [NSLocalizedDescriptionKey: "secret"]) }
            do { _ = try await client().text(baseURL: URL(string: "https://provider.example/v1")!, model: "m", apiKey: nil, prompt: "p"); XCTFail() } catch {
                XCTAssertFalse(error.localizedDescription.contains("secret"))
                if code == .cancelled { XCTAssertTrue(error is CancellationError) }
            }
        }
    }

    func testEntireCanonicalLoopbackRangeIsAccepted() async throws {
        let data = envelope("{}")
        ProviderFixtureProtocol.handler = { _ in (200, data) }
        let output = try await client().text(baseURL: URL(string: "http://127.2.3.4:11434/v1")!, model: "m", apiKey: nil, prompt: "p")
        XCTAssertEqual(output, Data("{}".utf8))
    }

    func testRejectsOversizedPNGDimensionsBeforePixelDecode() async throws {
        // A valid PNG envelope with deliberately oversized IHDR; no large pixel allocation.
        for dimension: UInt32 in [8193, 4096, 0] {
            var png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a6z8AAAAASUVORK5CYII=")!
            let bytes = [UInt8(truncatingIfNeeded: dimension >> 24), UInt8(truncatingIfNeeded: dimension >> 16), UInt8(truncatingIfNeeded: dimension >> 8), UInt8(truncatingIfNeeded: dimension)]
            png.replaceSubrange(16..<24, with: bytes + bytes)
            // Recompute IHDR CRC after replacing width/height.
            var crc: UInt32 = 0xffff_ffff
            for byte in png[12..<29] {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb8_8320 : 0) }
            }
            crc ^= 0xffff_ffff
            png.replaceSubrange(29..<33, with: [UInt8(truncatingIfNeeded: crc >> 24), UInt8(truncatingIfNeeded: crc >> 16), UInt8(truncatingIfNeeded: crc >> 8), UInt8(truncatingIfNeeded: crc)])
            let response = try JSONSerialization.data(withJSONObject: ["data": [["b64_json": png.base64EncodedString()]]])
            ProviderFixtureProtocol.handler = { _ in (200, response) }
            do {
                _ = try await client().image(baseURL: URL(string: "https://provider.example/v1")!, model: "m", apiKey: nil, prompt: "p", referenceImages: [], useEdits: false)
                XCTFail("Oversized PNG must be rejected")
            } catch { XCTAssertTrue(error is OpenAICompatibleTravelError) }
        }
    }

}
