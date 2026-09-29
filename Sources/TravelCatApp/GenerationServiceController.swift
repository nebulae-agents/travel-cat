import Combine
import Darwin
import Foundation

/// Coordinates keychain writes with the atomic configuration commit. Existing keychain
/// entries remain untouched, so a failed save cannot invalidate the active configuration.
@MainActor
final class GenerationServiceController: ObservableObject {
    @Published private(set) var configuration: TravelGenerationConfiguration
    private let store: TravelGenerationConfigurationStore
    private let credentials: any TravelServiceCredentialStoring
    private let didSave: () -> Void

    init(store: TravelGenerationConfigurationStore,
         credentials: any TravelServiceCredentialStoring,
         hasExistingHistory: Bool,
         didSave: @escaping () -> Void = {}) throws {
        self.store = store
        self.credentials = credentials
        self.didSave = didSave
        configuration = try store.load(hasExistingHistory: hasExistingHistory)
    }

    var isReady: Bool { configuration.onboardingCompleted }

    func save(_ candidate: TravelGenerationConfiguration,
              narrativeSecret: String?, imageSecret: String?,
              narrativeNoKey: Bool = false, imageNoKey: Bool = false) throws {
        var next = candidate
        next.onboardingCompleted = true
        guard next.schemaVersion == 1 else { throw TravelServiceConfigurationError.unsupportedVersion }
        try next.narrative.validate()
        try next.image.validate()

        // Plan both choices before performing any keychain mutation.
        let narrative = try prepare(next.narrative, previous: configuration.narrative,
                                    secret: narrativeSecret, noKey: narrativeNoKey)
        let image = try prepare(next.image, previous: configuration.image,
                                secret: imageSecret, noKey: imageNoKey)
        next.narrative = narrative.service
        next.image = image.service
        var createdIDs: [String] = []
        var attemptedConfigurationWrite = false
        do {
            for update in [narrative, image] {
                if let secret = update.secret {
                    // Include the ID before the write so even partially failing stores
                    // receive a best-effort rollback, without touching old credentials.
                    createdIDs.append(update.service.credentialID)
                    try credentials.save(secret, id: update.service.credentialID)
                }
            }
            attemptedConfigurationWrite = true
            try store.save(next)
        } catch {
            if attemptedConfigurationWrite {
                let persisted = try? store.load(hasExistingHistory: configuration.onboardingCompleted)
                if persisted == next {
                    // Rename committed, but a later durability check failed. The
                    // persisted configuration already references the new key slots.
                    configuration = next
                    didSave()
                    return
                }
                var fileStatus = stat()
                let noPublishedFile = store.configurationURL.path.withCString { path in
                    // lstat checks the directory entry itself, so a dangling symlink
                    // is not mistaken for an absent configuration. Permission and
                    // other inspection errors also remain conservatively unknown.
                    lstat(path, &fileStatus) == -1 && errno == ENOENT
                }
                guard persisted == configuration || noPublishedFile else {
                    // Unknown disk state: retain keys rather than risk invalidating
                    // a configuration that may have become visible to another reader.
                    throw GenerationServicePersistenceError.unconfirmedCommit
                }
            }
            for id in createdIDs { try? credentials.save(nil, id: id) }
            throw error
        }
        configuration = next
        didSave()
    }

    private func prepare(_ candidate: TravelServiceConfiguration,
                         previous: TravelServiceConfiguration,
                         secret: String?, noKey: Bool) throws -> CredentialUpdate {
        var service = candidate
        let endpointUnchanged = service.kind == previous.kind && service.baseURL == previous.baseURL
        guard service.kind == .openAICompatible else {
            service.credentialID = endpointUnchanged ? previous.credentialID : UUID().uuidString
            return CredentialUpdate(service: service, secret: nil)
        }
        if noKey {
            // A fresh unpopulated slot represents explicit unauthenticated access;
            // leave the old slot intact in case another configuration references it.
            service.credentialID = UUID().uuidString
            return CredentialUpdate(service: service, secret: nil)
        }
        if let secret, !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            service.credentialID = UUID().uuidString
            return CredentialUpdate(service: service, secret: secret)
        }
        guard endpointUnchanged else { throw GenerationSetupError.newEndpointNeedsCredentialChoice }
        service.credentialID = previous.credentialID
        return CredentialUpdate(service: service, secret: nil)
    }

    private struct CredentialUpdate {
        let service: TravelServiceConfiguration
        let secret: String?
    }
}

enum GenerationServicePersistenceError: LocalizedError {
    case unconfirmedCommit

    var errorDescription: String? {
        "无法确认服务配置是否保存成功，已保留密钥以保护现有配置。请重新打开设置核对后再试。"
    }
}
