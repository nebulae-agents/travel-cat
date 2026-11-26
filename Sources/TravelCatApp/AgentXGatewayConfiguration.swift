import Foundation
import Darwin
import Yams

/// Configuration only: no credential lookup, listener, or upstream request occurs here.
struct AgentXGatewayConfiguration {
    struct Binding: Equatable {
        let providerID: String
        let model: String
        var maxOutputTokens: Int
        let maxRequestBytes: Int
        let timeoutSeconds: Int
    }
    let applications: [String: Binding]
    enum Failure: Error { case unavailable, invalid, invalidBinding }

    static func load(root: URL) throws -> Self {
        try parse(read(root: root, fileName: "gateway.yaml"))
    }

    static func read(root: URL, fileName: String) throws -> Data {
        guard !fileName.contains("/"), !fileName.contains("\0"), root.isFileURL else { throw Failure.invalid }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootFD >= 0 else { throw Failure.unavailable }
        defer { close(rootFD) }
        let managerFD = openat(rootFD, "manager", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard managerFD >= 0 else { throw Failure.unavailable }
        defer { close(managerFD) }
        let fd = openat(managerFD, fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_size <= 1_048_576 else { throw Failure.invalid }
        // Bound the read even if the file grows after fstat.
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        return data
    }

    static func parse(_ data: Data) throws -> Self {
        do {
            let document = try object(data)
            guard Set(document.keys) == ["version", "applications"],
                  try integer(document["version"], maximum: 1) == 1,
                  let entries = document["applications"] as? [String: Any] else { throw Failure.invalid }
            var applications: [String: Binding] = [:]
            for (appID, raw) in entries {
                try AgentXPackageFiles.validateID(appID)
                guard let fields = raw as? [String: Any],
                      Set(fields.keys) == ["provider", "model", "max_output_tokens", "max_request_bytes", "timeout_seconds"],
                      let provider = fields["provider"] as? String,
                      let model = fields["model"] as? String,
                      !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      model.utf8.count <= 512 else { throw Failure.invalid }
                try AgentXPackageFiles.validateID(provider)
                applications[appID] = try Binding(providerID: provider, model: model,
                    maxOutputTokens: integer(fields["max_output_tokens"], maximum: 65_536),
                    maxRequestBytes: integer(fields["max_request_bytes"], maximum: 1_048_576),
                    timeoutSeconds: integer(fields["timeout_seconds"], maximum: 300))
            }
            return Self(applications: applications)
        } catch { throw Failure.invalid }
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else { throw Failure.invalid }
        // Node anchors are weak references into Parser. Keep it alive through validation.
        let parser = try Parser(yaml: text)
        defer { withExtendedLifetime(parser) {} }
        guard let root = try parser.singleRoot() else { throw Failure.invalid }
        var pending: [(Node, Int)] = [(root, 0)], count = 0
        while let (node, depth) = pending.popLast() {
            count += 1
            guard count <= 8192, depth <= 32, node.anchor == nil else { throw Failure.invalid }
            switch node {
            case .scalar: break
            case .alias: throw Failure.invalid
            case .sequence(let items): pending += items.map { ($0, depth + 1) }
            case .mapping(let pairs):
                var keys = Set<String>()
                for (key, value) in pairs {
                    guard case .scalar(let scalar) = key, key.anchor == nil,
                          keys.insert(scalar.string).inserted else { throw Failure.invalid }
                    pending.append((value, depth + 1))
                }
            }
        }
        guard let document = root.any as? [String: Any] else { throw Failure.invalid }
        return document
    }

    private static func integer(_ value: Any?, maximum: Int) throws -> Int {
        // Do not bridge Bool or floating-point NSNumber values to integers.
        guard let value, type(of: value) == Int.self, let number = value as? Int,
              (1...maximum).contains(number) else { throw Failure.invalid }
        return number
    }

    func binding(appID: String, state: AgentXState) throws -> Binding {
        let apps = state.apps.filter { $0.id == appID }
        guard var binding = applications[appID], apps.count == 1, apps[0].enabled else { throw Failure.invalidBinding }
        let providers = state.providers.filter { $0.id == binding.providerID }
        guard providers.count == 1, let provider = providers.first, provider.enabled,
              provider.serviceProtocol == .openAICompatible,
              provider.enabledModels.contains(binding.model) else { throw Failure.invalidBinding }
        let members = state.instances.filter { $0.appID == appID }
        guard !members.isEmpty, Set(members.map(\.id)).count == members.count,
              members.allSatisfy({ member in
                  member.providerID == binding.providerID && member.model == binding.model &&
                  (member.conversationModel == nil || member.conversationModel == .init(providerID: binding.providerID, model: binding.model))
              }) else { throw Failure.invalidBinding }
        if let catalog = provider.modelSelection {
            let models = catalog.models.filter { $0.id == binding.model }
            guard models.count == 1 else { throw Failure.invalidBinding }
            if let context = models[0].contextLength {
                guard context > 0 else { throw Failure.invalidBinding }
                binding.maxOutputTokens = min(binding.maxOutputTokens, context)
            }
        }
        return binding
    }
}
