import Foundation

/// Persist references only. Secrets remain in the existing credential store.
struct AgentXCredentialProfile: Codable, Equatable, Sendable, Identifiable {
    var name: String
    var keyReferences: [String]
    var id: String { name }
}

enum AgentXCredentialProfileError: LocalizedError {
    case invalidProfile, missingCredential
    var errorDescription: String? {
        switch self {
        case .invalidProfile: "凭据配置不存在、重复或没有有效密钥引用。"
        case .missingCredential: "当前轮到的密钥不存在，请更新凭据配置。"
        }
    }
}

/// Strict round-robin, serialized on MainActor with no suspension between selecting
/// and reading a key. Failed reads consume their turn; no automatic API retry.
@MainActor
final class AgentXCredentialProfiles {
    private(set) var profiles: [AgentXCredentialProfile]
    private let store: any TravelServiceCredentialStoring
    private var cursors: [String: Int] = [:]

    init(profiles: [AgentXCredentialProfile], store: any TravelServiceCredentialStoring) {
        self.profiles = profiles
        self.store = store
    }

    func nextSecret(profile name: String) throws -> String {
        let profile = try resolved(name)
        let index = (cursors[name] ?? 0) % profile.keyReferences.count
        cursors[name] = (index + 1) % profile.keyReferences.count
        guard let secret = try store.read(id: profile.keyReferences[index]), !secret.isEmpty,
              !secret.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw AgentXCredentialProfileError.missingCredential
        }
        return secret
    }

    func saveSecret(_ secret: String?, profile name: String, keyReference: String) throws {
        let profile = try resolved(name)
        guard profile.keyReferences.contains(keyReference),
              secret?.contains(where: { $0.isNewline || $0 == "\0" }) != true else {
            throw AgentXCredentialProfileError.invalidProfile
        }
        try store.save(secret, id: keyReference)
    }

    private func resolved(_ name: String) throws -> AgentXCredentialProfile {
        let matches = profiles.filter { $0.name == name }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              matches.count == 1, let profile = matches.first,
              !profile.keyReferences.isEmpty,
              Set(profile.keyReferences).count == profile.keyReferences.count,
              profile.keyReferences.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.contains(where: { $0.isNewline || $0 == "\0" }) }) else {
            throw AgentXCredentialProfileError.invalidProfile
        }
        return profile
    }
}
