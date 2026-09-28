import Foundation
import ImageIO

/// Deliberately contains no provider body, URL, prompt, or credential in diagnostics.
enum OpenAICompatibleTravelError: LocalizedError {
    case invalidAddress, invalidRequest, transport, timedOut, http(Int), tooLarge, invalidJSON, invalidImage
    var errorDescription: String? {
        switch self {
        case .invalidAddress: "服务地址不安全或格式无效，请使用 HTTPS 或本机 HTTP 地址。"
        case .invalidRequest: "模型、密钥或参考图片配置无效。"
        case .transport: "无法连接模型服务，请检查网络和服务地址。"
        case .timedOut: "模型服务响应超时，请稍后重试。"
        case .http(let status): "模型服务返回错误（HTTP \(status)），请检查配置和服务状态。"
        case .tooLarge: "模型服务响应超过允许大小。"
        case .invalidJSON: "模型服务未返回有效的 JSON 对象。"
        case .invalidImage: "模型服务未返回有效的 PNG 图片。"
        }
    }
}

private final class ProviderNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor final class OpenAICompatibleTravelClient {
    private let session: URLSession
    private let redirectDelegate = ProviderNoRedirectDelegate()
    private let imageLimit = 15 * 1_024 * 1_024

    init(session: URLSession? = nil) {
        if let session { self.session = session } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 180
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration, delegate: ProviderNoRedirectDelegate(), delegateQueue: nil)
        }
    }

    func text(baseURL: URL, model: String, apiKey: String?, prompt: String, jsonMode: Bool = true) async throws -> Data {
        var request = try request(baseURL: baseURL, endpoint: "chat/completions", model: model, apiKey: apiKey)
        var body: [String: Any] = ["model": model, "messages": [["role": "user", "content": prompt]], "stream": false]
        if jsonMode { body["response_format"] = ["type": "json_object"] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await receive(request, limit: 1_024 * 1_024)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]], let choice = choices.first,
              let message = choice["message"] as? [String: Any], message["tool_calls"] == nil,
              message["function_call"] == nil, let content = message["content"] as? String else {
            throw OpenAICompatibleTravelError.invalidJSON
        }
        var value = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```json\n") && value.hasSuffix("```") { value = String(value.dropFirst(8).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines) }
        else if value.hasPrefix("```\n") && value.hasSuffix("```") { value = String(value.dropFirst(4).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines) }
        let result = Data(value.utf8)
        guard (try? JSONSerialization.jsonObject(with: result)) is [String: Any] else { throw OpenAICompatibleTravelError.invalidJSON }
        return result
    }

    func image(baseURL: URL, model: String, apiKey: String?, prompt: String, referenceImages: [URL], useEdits: Bool) async throws -> Data {
        var request = try request(baseURL: baseURL, endpoint: useEdits ? "images/edits" : "images/generations", model: model, apiKey: apiKey)
        var fields: [String: Any] = ["model": model, "prompt": prompt, "n": 1, "size": "1536x1024"]
        if model.lowercased().hasPrefix("gpt-image") { fields["output_format"] = "png" }
        else { fields["response_format"] = "b64_json" }
        if useEdits {
            guard !referenceImages.isEmpty, referenceImages.count <= 4 else { throw OpenAICompatibleTravelError.invalidRequest }
            let boundary = "TravelCat-\(UUID().uuidString)"
            var body = Data()
            for key in fields.keys.sorted() {
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(fields[key]!)\r\n".utf8))
            }
            for (index, url) in referenceImages.enumerated() {
                guard url.isFileURL else { throw OpenAICompatibleTravelError.invalidRequest }
                let bytes: Data
                do {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    bytes = try handle.read(upToCount: imageLimit + 1) ?? Data()
                } catch { throw OpenAICompatibleTravelError.invalidRequest }
                guard bytes.count <= imageLimit, let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                      let type = CGImageSourceGetType(source) as String?, ["public.png", "public.jpeg", "org.webmproject.webp"].contains(type) else { throw OpenAICompatibleTravelError.invalidRequest }
                let mime = type == "public.png" ? "image/png" : type == "public.jpeg" ? "image/jpeg" : "image/webp"
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image[]\"; filename=\"reference-\(index)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
                body.append(bytes); body.append(Data("\r\n".utf8))
            }
            body.append(Data("--\(boundary)--\r\n".utf8))
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        } else { request.httpBody = try JSONSerialization.data(withJSONObject: fields) }
        let data = try await receive(request, limit: 24 * 1_024 * 1_024)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]], let item = items.first else { throw OpenAICompatibleTravelError.invalidImage }
        let image: Data
        if let encoded = item["b64_json"] as? String {
            guard let decoded = Data(base64Encoded: encoded), decoded.count <= imageLimit else { throw OpenAICompatibleTravelError.invalidImage }
            image = decoded
        } else if let address = item["url"] as? String, let url = URL(string: address) {
            try validate(url, base: false, allowLoopback: isLoopback(baseURL))
            var download = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
            download.httpShouldHandleCookies = false
            image = try await receive(download, limit: imageLimit)
        } else { throw OpenAICompatibleTravelError.invalidImage }
        guard image.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(image as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8_192, height <= 8_192,
              Int64(width) * Int64(height) <= 16_000_000,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw OpenAICompatibleTravelError.invalidImage }
        return image
    }

    private func isLoopback(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        if ["localhost", "[::1]", "::1"].contains(host) { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets[0] == "127" && octets.allSatisfy {
            guard !$0.isEmpty, $0.allSatisfy({ $0.isASCII && $0.isNumber }),
                  $0.count == 1 || $0.first != "0", let value = UInt16($0) else { return false }
            return value <= 255
        }
    }
    private func validate(_ url: URL, base: Bool, allowLoopback: Bool = true) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.fragment == nil, (!base || components.query == nil),
              components.scheme == "https" || (components.scheme == "http" && allowLoopback && isLoopback(url)) else { throw OpenAICompatibleTravelError.invalidAddress }
    }
    private func request(baseURL: URL, endpoint: String, model: String, apiKey: String?) throws -> URLRequest {
        try Task.checkCancellation()
        try validate(baseURL, base: true)
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              apiKey?.contains(where: { $0.isNewline || $0 == "\0" }) != true else { throw OpenAICompatibleTravelError.invalidRequest }
        var request = URLRequest(url: baseURL.appendingPathComponent(endpoint), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return request
    }
    private nonisolated func receive(_ request: URLRequest, limit: Int) async throws -> Data {
        do {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request, delegate: redirectDelegate)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw OpenAICompatibleTravelError.transport }
            guard (200...299).contains(http.statusCode) else { throw OpenAICompatibleTravelError.http(http.statusCode) }
            guard response.expectedContentLength <= limit else { throw OpenAICompatibleTravelError.tooLarge }
            var result = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard result.count < limit else { throw OpenAICompatibleTravelError.tooLarge }
                result.append(byte)
            }
            return result
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if let error = error as? OpenAICompatibleTravelError { throw error }
            if (error as? URLError)?.code == .timedOut { throw OpenAICompatibleTravelError.timedOut }
            throw OpenAICompatibleTravelError.transport
        }
    }
}
