import Combine
import Foundation
import TravelCore
import TravelStorage

struct HomeLocationCandidate: Sendable {
    let country: String?
    let region: String?
    let city: String
}

protocol HomeLocationLookingUp: Sendable {
    func lookup() async throws -> HomeLocationCandidate
}

enum HomeLocationLookupError: Error { case invalidResponse }

private final class HomeLocationNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct IPHomeLocationLookup: HomeLocationLookingUp {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    static let endpoint = URL(string: "https://ipwho.is/")!
    private let transport: Transport

    init(transport: Transport? = nil) {
        self.transport = transport ?? Self.load
    }

    func lookup() async throws -> HomeLocationCandidate {
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport(request)
        guard response.statusCode == 200, response.url?.scheme == "https", response.url?.host == "ipwho.is",
              data.count <= 16_384 else { throw HomeLocationLookupError.invalidResponse }
        struct Response: Decodable {
            let success: Bool
            let country: String?
            let region: String?
            let city: String?
        }
        let result = try JSONDecoder().decode(Response.self, from: data)
        guard result.success, let city = result.city?.trimmingCharacters(in: .whitespacesAndNewlines), HomeLocation.validName(city) else {
            throw HomeLocationLookupError.invalidResponse
        }
        func optionalName(_ raw: String?) throws -> String? {
            guard let raw else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { return nil }
            guard HomeLocation.validName(value) else { throw HomeLocationLookupError.invalidResponse }
            return value
        }
        return HomeLocationCandidate(country: try optionalName(result.country), region: try optionalName(result.region), city: city)
    }

    private static func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: HomeLocationNoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw HomeLocationLookupError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 16_384 else { throw HomeLocationLookupError.invalidResponse }
            data.append(byte)
        }
        return (data, response)
    }
}

@MainActor
final class HomeLocationController: ObservableObject {
    @Published private(set) var state: HomeLocationState
    @Published private(set) var isLocating = false
    @Published private(set) var proposedLocation: HomeLocation?
    @Published private(set) var message: String?
    @Published private(set) var errorMessage: String?
    private let store: HomeLocationStore
    private let lookup: any HomeLocationLookingUp
    private let now: () -> Date
    private var revision = 0
    private var loadFailed = false

    init(store: HomeLocationStore, lookup: any HomeLocationLookingUp = IPHomeLocationLookup(), now: @escaping () -> Date = Date.init) {
        self.store = store
        self.lookup = lookup
        self.now = now
        do { state = try store.load() }
        catch {
            state = HomeLocationState()
            loadFailed = true
            errorMessage = "家的城市配置无法读取，原始文件已保留；暂不定位或覆盖。"
        }
    }

    func setIPLookupEnabled(_ enabled: Bool) {
        guard !loadFailed else { return }
        do {
            var next = state
            next.ipLookupEnabled = enabled
            try store.save(next)
            state = next
            revision += 1
            errorMessage = nil
        } catch { errorMessage = "无法保存定位设置，原设置已保留。" }
    }

    func setManualCity(_ city: String) {
        guard !loadFailed else { return }
        let city = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HomeLocation.validName(city) else { errorMessage = "请输入 1–80 字的城市名称，不要换行。"; return }
        do {
            var next = state
            next.location = HomeLocation(city: city, source: .manual, updatedAt: now())
            try store.save(next)
            state = next
            revision += 1
            proposedLocation = nil
            message = "已保存家的城市；不会自动被 IP 定位覆盖。"
            errorMessage = nil
        } catch { errorMessage = "无法保存家的城市，原值已保留。" }
    }

    func useProposedLocation() {
        guard !loadFailed, let location = proposedLocation else { return }
        do {
            var next = state
            next.location = location
            try store.save(next)
            state = next
            revision += 1
            proposedLocation = nil
            message = "已将家的城市改为选中的 IP 定位结果。"
            errorMessage = nil
        } catch { errorMessage = "无法保存定位城市，原值已保留。" }
    }

    func refresh(force: Bool = false) async {
        guard !loadFailed, !isLocating else { return }
        guard state.ipLookupEnabled else {
            if force { message = "请先允许通过 ipwho.is 定位，或直接手动填写城市。" }
            return
        }
        let startedAt = now()
        if !force {
            guard state.location?.source != .manual else { return }
            if let updated = state.location?.updatedAt, startedAt.timeIntervalSince(updated) < 7 * 24 * 3600 { return }
            if let attempted = state.lastAttemptAt, startedAt.timeIntervalSince(attempted) < 6 * 3600 { return }
        }
        do {
            var attempted = state
            attempted.lastAttemptAt = startedAt
            try store.save(attempted)
            state = attempted
        } catch { errorMessage = "无法保存定位请求，暂未联网。"; return }
        isLocating = true
        message = "正在通过 ipwho.is 定位城市…"
        errorMessage = nil
        let currentRevision = revision
        defer { isLocating = false }
        do {
            let candidate = try await lookup.lookup()
            try Task.checkCancellation()
            guard currentRevision == revision, state.ipLookupEnabled else { return }
            let location = HomeLocation(country: candidate.country, region: candidate.region, city: candidate.city,
                source: .ip, provider: "ipwho.is", updatedAt: now())
            if state.location?.source == .manual {
                proposedLocation = location
                message = "IP 定位结果仅作为候选；手动设置的家没有改变。"
            } else {
                var next = state
                next.location = location
                try store.save(next)
                state = next
                proposedLocation = nil
                message = "已更新 IP 定位城市。若与实际住址不符，请手动纠正。"
            }
        } catch is CancellationError {
            if currentRevision == revision { message = "定位已取消，保留原来的城市。" }
        } catch {
            guard currentRevision == revision else { return }
            message = nil
            errorMessage = (error as? URLError)?.code == .timedOut
                ? "IP 定位超时，保留已知城市；稍后可重新定位。"
                : "IP 定位未成功，保留已知城市；可以手动填写。"
        }
    }
}
