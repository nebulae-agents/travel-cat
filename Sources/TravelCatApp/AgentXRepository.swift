import Foundation
import Yams

/// Host-owned layered configuration. App state stays under each app directory.
struct AgentXRepository {
    let root: URL
    private let fm = FileManager.default

    func load(includePilotRuns: Bool = true) throws -> AgentXState {
        let pilot = try AgentXPilot.configured(at: root)
        try AgentXLocalAppTransaction.recover(root: root)
        try recoverTransaction()
        let file = try safeURL("agentx.yaml")
        guard fm.fileExists(atPath: file.path) else {
            var initial = AgentXState()
            if fm.fileExists(atPath: try safeURL("apps").path) { initial.apps = []; initial.currentAppID = nil; initial.singleAppID = nil }
            return initial
        }
        let bytes = try Data(contentsOf: file)
        if let legacy = try? JSONDecoder().decode(AgentXState.self, from: bytes) {
            guard pilot == nil else { throw AgentXError.invalid("试点需要已分层的数据副本。") }
            try validate(legacy)
            return legacy
        }
        let settings = try dictionary("agentx.yaml")
        var state = AgentXState()
        guard let version = settings["version"] as? Int else { throw AgentXError.corrupt }
        state.version = version
        state.blackCatEnabled = (settings["blackcat"] as? [String: Any])?["enabled"] as? Bool ?? true
        if let raw = (settings["ui"] as? [String: Any])?["front_skin"] as? String {
            guard let skin = AgentXFrontSkin(rawValue: raw) else { throw AgentXError.corrupt }
            state.frontSkin = skin
        }
        state.currentAppID = settings["current_app"] as? String
        state.singleAppID = settings["mode"] as? String == "single" ? settings["single_app"] as? String : nil
        for path in try children("manager/providers", extension: "yaml") {
            let item = try dictionary(path)
            guard let id = item["name"] as? String, let base = item["base_url"] as? String else { throw AgentXError.corrupt }
            guard id == URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent else { throw AgentXError.unsafePath }
            let entries = item["models"] as? [[String: Any]] ?? []
            let models = entries.compactMap { $0["id"] as? String }
            let hasPreferences = entries.contains { entry in ["enabled", "favorite", "available", "name", "context_length", "input_modalities", "output_modalities", "supported_parameters", "pricing", "has_tiered_pricing"].contains { entry[$0] != nil } } || item["defaults"] != nil
            let selection: AgentXModelSelection? = hasPreferences ? .init(models: entries.compactMap { entry in
                guard let id = entry["id"] as? String else { return nil }
                return .init(id: id, enabled: entry["enabled"] as? Bool ?? true, favorite: entry["favorite"] as? Bool ?? false,
                    available: entry["available"] as? Bool ?? true, name: entry["name"] as? String,
                    contextLength: entry["context_length"] as? Int, inputModalities: entry["input_modalities"] as? [String],
                    outputModalities: entry["output_modalities"] as? [String], supportedParameters: entry["supported_parameters"] as? [String],
                    pricing: (entry["pricing"] as? [String: Any])?.compactMapValues { $0 as? String }, hasTieredPricing: entry["has_tiered_pricing"] as? Bool ?? false)
            }, defaults: item["defaults"] as? [String: String] ?? [:]) : nil
            state.providers.append(.init(id: id, name: item["display"] as? String ?? id, baseURL: base, models: models,
                enabled: item["enabled"] as? Bool ?? true, serviceProtocol: try .parse(item["api_mode"] as? String ?? "openai-compatible"),
                credentialProfile: item["secrets_profile"] as? String, modelSelection: selection,
                catalogRefreshedAt: try catalogDate(item["catalog_refreshed_at"])))
        }
        let profiles: [AgentXCredentialProfile] = try children("manager/secrets", extension: "yaml").map { path in
            let profile: AgentXCredentialProfile = try decodeYAML(path)
            guard profile.name == URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent else { throw AgentXError.unsafePath }
            return profile
        }
        if !profiles.isEmpty { state.credentialProfiles = profiles }
        for directory in try children("manager/templates/assistant", extension: nil) {
            let metadata = try dictionary(directory + "/definition.yaml")
            guard let id = metadata["id"] as? String, let name = metadata["name"] as? String else { throw AgentXError.corrupt }
            guard directory == "manager/templates/assistant/" + id else { throw AgentXError.unsafePath }
            let document = try AgentXDefinitionDocument.importDirectory(try safeURL(directory), excluding: ["definition.yaml", "versions"])
            if metadata["revisions"] != nil || metadata["draft"] != nil {
                var definition: AgentXDefinition = try decodeYAML(directory + "/definition.yaml")
                definition.draft = document
                state.definitions.append(definition)
            } else {
                state.definitions.append(.init(id: id, name: name, prompt: document.source,
                    draft: document.files.isEmpty && document.directories.isEmpty ? nil : document))
            }
        }
        let apps = try children("apps", extension: nil)
        state.apps = []
        if apps.isEmpty { state.currentAppID = nil; state.singleAppID = nil }
        for directory in apps {
            var app: AgentXApplication = try decodeYAML(directory + "/app.yaml")
            let manifest = try dictionary(directory + "/app.yaml")
            if manifest["enabled"] == nil {
                if let projection = settings["apps_enabled"] as? [String] { app.enabled = projection.contains(app.id) }
            }
            guard directory == "apps/" + app.id else { throw AgentXError.unsafePath }
            state.apps.append(app)
            for instance in try children(directory + "/instances", extension: nil) {
                let value: AgentXInstance = try decodeYAML(instance + "/config/agent.yaml")
                guard value.appID == app.id, instance == directory + "/instances/" + value.id else { throw AgentXError.unsafePath }
                state.instances.append(value)
            }
            if !includePilotRuns && pilot?.appIDs.contains(app.id) == true { continue }
            for run in try children(directory + "/runs", extension: "json") {
                let bytes = try Data(contentsOf: safeURL(run))
                let value: AgentXRun
                if pilot?.appIDs.contains(app.id) == true {
                    guard let fields = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw AgentXError.corrupt }
                    value = try AgentXRun.serviceProjection(fields)
                } else {
                    value = try JSONDecoder().decode(AgentXRun.self, from: bytes)
                }
                guard value.appID == app.id, run == directory + "/runs/" + value.id + ".json" else { throw AgentXError.unsafePath }
                state.runs.append(value)
            }
        }
        let appOrder = try state.apps.map { try dictionary("apps/\($0.id)/app.yaml")["_order"] as? Int ?? Int.max }
        state.apps = zip(state.apps, appOrder).sorted { $0.1 < $1.1 }.map(\.0)
        let providerOrder = try state.providers.map { try dictionary("manager/providers/\($0.id).yaml")["_order"] as? Int ?? Int.max }
        state.providers = zip(state.providers, providerOrder).sorted { $0.1 < $1.1 }.map(\.0)
        let definitionOrder = try state.definitions.map { try dictionary("manager/templates/assistant/\($0.id)/definition.yaml")["_order"] as? Int ?? Int.max }
        state.definitions = zip(state.definitions, definitionOrder).sorted { $0.1 < $1.1 }.map(\.0)
        let instanceOrder = try state.instances.map { try dictionary("apps/\($0.appID)/instances/\($0.id)/config/agent.yaml")["_order"] as? Int ?? Int.max }
        state.instances = zip(state.instances, instanceOrder).sorted { $0.1 < $1.1 }.map(\.0)
        state.runs.sort { $0.startedAt < $1.startedAt }
        try validate(state)
        return state
    }

    func save(_ state: AgentXState, preservingRunsFor appIDs: Set<String> = []) throws {
        let owned = try AgentXPilot.configured(at: root)?.appIDs ?? []
        let protected = owned.union(appIDs)
        try recoverTransaction(preservingRunsFor: protected)
        try validate(state)
        var directories = ["manager/providers", "manager/secrets", "manager/templates/assistant", "apps", "shared/inbox", "shared/published", "shared/references", "audit", "backups"]
            + state.instances.flatMap { instance in
                ["config", "memory", "workspace", "logs"].map { "apps/\(instance.appID)/instances/\(instance.id)/\($0)" }
            } + state.apps.flatMap { app in
                let directories = protected.contains(app.id) ? ["state", "artifacts", "shared", "memory"] : ["state", "artifacts", "shared", "runs", "memory"]
                return directories.map { "apps/\(app.id)/\($0)" }
            }
        var writes: [String: Data] = [:]
        var settings = try existingDictionary("agentx.yaml")
        let manifest = try safeURL("agentx.yaml")
        if fm.fileExists(atPath: manifest.path), let legacy = try? JSONDecoder().decode(AgentXState.self, from: Data(contentsOf: manifest)) {
            try validate(legacy)
            let backup = "backups/legacy-v1/agentx.json"
            if !fm.fileExists(atPath: try safeURL(backup).path) { writes[backup] = try Data(contentsOf: manifest) }
            settings = [:]
        }
        settings["version"] = state.version
        settings["mode"] = state.singleAppID == nil ? "full" : "single"
        settings["single_app"] = state.singleAppID
        settings["current_app"] = state.currentAppID
        settings["apps_enabled"] = state.apps.filter(\.enabled).map(\.id)
        var blackcat = settings["blackcat"] as? [String: Any] ?? [:]
        blackcat["enabled"] = state.blackCatEnabled; settings["blackcat"] = blackcat
        if let skin = state.frontSkin {
            var ui = settings["ui"] as? [String: Any] ?? [:]
            ui["front_skin"] = skin.rawValue
            settings["ui"] = ui
        }
        writes["agentx.yaml"] = try yaml(settings)
        for (order, provider) in state.providers.enumerated() {
            let path = "manager/providers/\(provider.id).yaml"
            var item = try existingDictionary(path)
            let existing = item["models"] as? [[String: Any]] ?? []
            item["_order"] = order
            item["name"] = provider.id; item["display"] = provider.name
            item["base_url"] = provider.baseURL; item["enabled"] = provider.enabled
            item["api_mode"] = provider.serviceProtocol.rawValue
            item["secrets_profile"] = provider.credentialProfile
            item["defaults"] = provider.modelSelection?.defaults
            if let date = provider.catalogRefreshedAt {
                // Retain a human-authored timestamp verbatim when it represents the same instant.
                if (try? catalogDate(item["catalog_refreshed_at"])) != date {
                    // Yams rounds Double scalars; a decimal string preserves timestamp precision.
                    item["catalog_refreshed_at"] = String(date.timeIntervalSince1970)
                }
            } else { item["catalog_refreshed_at"] = nil }
            item["models"] = provider.models.map { id -> [String: Any] in
                var model = existing.first { $0["id"] as? String == id } ?? [:]
                model["id"] = id
                if let choice = provider.modelSelection?.models.first(where: { $0.id == id }) {
                    model["enabled"] = choice.enabled; model["favorite"] = choice.favorite
                    model["available"] = choice.available; model["name"] = choice.name
                    model["context_length"] = choice.contextLength
                    model["input_modalities"] = choice.inputModalities; model["output_modalities"] = choice.outputModalities
                    model["supported_parameters"] = choice.supportedParameters
                    model["has_tiered_pricing"] = choice.hasTieredPricing
                    // Refreshed provider prices are authoritative; unknown user YAML extensions survive.
                    var savedPrices = (model["pricing"] as? [String: Any] ?? [:]).filter { !Self.providerPriceKeys.contains($0.key) }
                    for (key, value) in choice.pricing ?? [:] { savedPrices[key] = value }
                    model["pricing"] = savedPrices.isEmpty ? nil : savedPrices
                }
                return model
            }
            writes[path] = try yaml(item)
        }
        for profile in state.credentialProfiles ?? [] {
            writes["manager/secrets/\(profile.name).yaml"] = Data(try YAMLEncoder().encode(profile).utf8)
        }
        for (order, definition) in state.definitions.enumerated() {
            let directory = "manager/templates/assistant/\(definition.id)"
            writes[directory + "/definition.yaml"] = try mergedYAML(definition, path: directory + "/definition.yaml", order: order)
            let draft = definition.draft ?? AgentXDefinitionDocument(source: definition.prompt)
            writes[directory + "/agent.md"] = Data(draft.source.utf8)
            for (path, text) in draft.files { writes[directory + "/" + (try AgentXDefinitionDocument.path(path))] = Data(text.utf8) }
            directories += try draft.directories.map { directory + "/" + (try AgentXDefinitionDocument.path($0)) }
            for revision in definition.revisions ?? [] {
                let versionDirectory = directory + "/versions/\(revision.number)"
                var files = revision.document.files
                files["agent.md"] = revision.document.source
                directories += try revision.document.directories.map { versionDirectory + "/" + (try AgentXDefinitionDocument.path($0)) }
                for (path, text) in files {
                    let target = versionDirectory + "/" + (try AgentXDefinitionDocument.path(path))
                    let bytes = Data(text.utf8)
                    if fm.fileExists(atPath: try safeURL(target).path), try Data(contentsOf: safeURL(target)) != bytes { throw AgentXDefinitionError.immutableRevision }
                    writes[target] = bytes
                }
            }
        }
        for (order, app) in state.apps.enumerated() {
            let path = "apps/\(app.id)/app.yaml"
            let previous: AgentXApplication? = fm.fileExists(atPath: try safeURL(path).path) ? try decodeYAML(path) : nil
            let appBytes = try mergedYAML(app, path: path, order: order)
            // Compare the persisted representation: YAML timestamps have lower precision than Date.
            let persisted = try YAMLDecoder().decode(AgentXApplication.self, from: String(decoding: appBytes, as: UTF8.self))
            if let old = previous?.experience {
                guard old.revisions.allSatisfy({ persisted.experience?.revisions.contains($0) == true }) else { throw AgentXDefinitionError.immutableRevision }
            }
            if let published = persisted.experience?.published, published != previous?.experience?.published {
                let memoryPath = "apps/\(app.id)/memory/agentx-shared.md"
                let url = try safeURL(memoryPath)
                if fm.fileExists(atPath: url.path) {
                    let existing = try String(contentsOf: url, encoding: .utf8)
                    guard existing == previous?.experience?.published?.configuration.sharedMemory || existing == published.configuration.sharedMemory else {
                        throw AgentXError.invalid("共享记忆文件已有手写修改，发布已停止；请先审阅并合并，原文件未覆盖。")
                    }
                }
                writes[memoryPath] = Data(published.configuration.sharedMemory.utf8)
            }
            writes[path] = appBytes
        }
        for (order, instance) in state.instances.enumerated() {
            let path = "apps/\(instance.appID)/instances/\(instance.id)/config/agent.yaml"
            var item = try existingDictionary(path)
            for key in ["definitionRevision", "variables", "credentialProfile", "conversationModel"] { item[key] = nil }
            let encoded = try Yams.load(yaml: YAMLEncoder().encode(instance)) as! [String: Any]
            item.merge(encoded) { _, new in new }
            item["_order"] = order
            writes[path] = try yaml(item)
        }
        for run in state.runs where !protected.contains(run.appID) {
            let path = "apps/\(run.appID)/runs/\(run.id).json"
            let url = try safeURL(path)
            if fm.fileExists(atPath: url.path) {
                // Navigation/configuration saves must not rewrite unrelated history.
                // Compare decoded values so key order, formatting and unknown fields survive.
                // A corrupt existing record is an error, never permission to replace it.
                let persisted = try JSONDecoder().decode(AgentXRun.self, from: Data(contentsOf: url))
                if persisted == run { continue }
            }
            writes[path] = try JSONEncoder().encode(run)
        }
        // Validate every target before the first write. A recovery journal makes interrupted
        // multi-file saves roll back as one unit when the host opens this root again.
        let allDirectories = directories + writes.keys.map { ($0 as NSString).deletingLastPathComponent }.filter { !$0.isEmpty }
        var missingDirectories = Set<String>()
        for directory in allDirectories {
            var relative = ""
            for component in directory.split(separator: "/") {
                relative += relative.isEmpty ? String(component) : "/" + component
                if !fm.fileExists(atPath: try safeURL(relative).path) { missingDirectories.insert(relative) }
            }
        }
        for path in writes.keys { _ = try safeURL(path) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var before: [PreviousFile] = []
        for path in writes.keys.sorted() {
            let url = try safeURL(path)
            before.append(.init(path: path, bytes: fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil))
        }
        let journal = try safeURL(".agentx-transaction.json")
        try JSONEncoder().encode(Transaction(files: before, directories: missingDirectories.sorted())).write(to: journal, options: .atomic)
        do {
            for directory in missingDirectories.sorted(by: { $0.count < $1.count }) {
                try fm.createDirectory(at: safeURL(directory), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            for path in writes.keys.sorted() {
                let url = try safeURL(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try writes[path]!.write(to: url, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            try fm.removeItem(at: journal)
        } catch {
            try recoverTransaction(preservingRunsFor: protected)
            throw error
        }
    }

    private struct Transaction: Codable { let files: [PreviousFile]; let directories: [String] }
    private struct PreviousFile: Codable { let path: String; let bytes: Data? }
    private func recoverTransaction(preservingRunsFor appIDs: Set<String> = []) throws {
        let journal = try safeURL(".agentx-transaction.json")
        guard fm.fileExists(atPath: journal.path) else { return }
        let transaction = try JSONDecoder().decode(Transaction.self, from: Data(contentsOf: journal))
        let previous = transaction.files
        let owned = try AgentXPilot.configured(at: root)?.appIDs ?? []
        let protected = try owned.union(appIDs).map { try safeURL("apps/\($0)/runs").path.lowercased() }
        for target in previous.map(\.path) + transaction.directories {
            let path = try safeURL(target).path.lowercased()
            guard !protected.contains(where: { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }) else {
                throw AgentXError.invalid("待恢复事务涉及试点运行目录，请先离线处理副本。")
            }
        }
        for directory in transaction.directories { _ = try safeURL(directory) }
        for entry in previous { _ = try safeURL(entry.path) }
        for entry in previous {
            let url = try safeURL(entry.path)
            if let bytes = entry.bytes { try bytes.write(to: url, options: .atomic) }
            else if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
        for directory in transaction.directories.sorted(by: { $0.count > $1.count }) {
            let url = try safeURL(directory)
            if fm.fileExists(atPath: url.path), try fm.contentsOfDirectory(atPath: url.path).isEmpty { try fm.removeItem(at: url) }
        }
        try fm.removeItem(at: journal)
    }
    private func children(_ relative: String, extension suffix: String?) throws -> [String] {
        let url = try safeURL(relative)
        guard fm.fileExists(atPath: url.path) else { return [] }
        return try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { child in
            guard !child.lastPathComponent.hasPrefix(".") else { return nil }
            let path = relative + "/" + child.lastPathComponent
            let checked = try safeURL(path)
            let values = try checked.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if let suffix { return child.pathExtension == suffix && values.isRegularFile == true ? path : nil }
            return values.isDirectory == true ? path : nil
        }
    }
    // Yams' default Any constructor only handles signed platform integers. Keep
    // large unsigned manifest values numeric when merging preserved YAML fields.
    var yamlConstructor: Constructor {
        var scalars = Constructor.defaultScalarMap
        scalars[.int] = { scalar in
            if let value = Int.construct(from: scalar) { return value }
            return UInt64.construct(from: scalar)
        }
        return Constructor(scalars)
    }
    private func yaml(_ value: [String: Any]) throws -> Data { Data(try Yams.dump(object: value, sortKeys: true).utf8) }
    private func dictionary(_ path: String) throws -> [String: Any] {
        guard let value = try Yams.load(yaml: String(contentsOf: safeURL(path), encoding: .utf8), .default, yamlConstructor) as? [String: Any] else { throw AgentXError.corrupt }
        return value
    }
    private func existingDictionary(_ path: String) throws -> [String: Any] {
        fm.fileExists(atPath: try safeURL(path).path) ? try dictionary(path) : [:]
    }
    private func decodeYAML<T: Decodable>(_ path: String) throws -> T {
        try YAMLDecoder().decode(T.self, from: String(contentsOf: safeURL(path), encoding: .utf8))
    }
    private func mergedYAML<T: Encodable>(_ value: T, path: String, order: Int) throws -> Data {
        var result = try existingDictionary(path)
        let encoded = try Yams.load(yaml: YAMLEncoder().encode(value), .default, yamlConstructor) as! [String: Any]
        result["_order"] = order
        result.merge(encoded) { _, new in new }
        return try yaml(result)
    }

    private func safeURL(_ relative: String) throws -> URL {
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { throw AgentXError.unsafePath }
        let base = root.standardizedFileURL
        let result = base.appendingPathComponent(relative).standardizedFileURL
        guard result.path.hasPrefix(base.path + "/") else { throw AgentXError.unsafePath }
        // /tmp and /var may be system aliases. Check the configured root and descendants.
        var cursor = base
        for part in [""] + relative.split(separator: "/").map(String.init) {
            if !part.isEmpty { cursor.appendPathComponent(part) }
            if let values = try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                throw AgentXError.unsafePath
            }
        }
        return result
    }

    // OpenRouter's published base-rate fields and conditional pricing metadata.
    private static let providerPriceKeys: Set<String> = [
        "prompt", "completion", "request", "image", "image_token", "image_output", "audio", "audio_output",
        "input_audio_cache", "web_search", "internal_reasoning", "input_cache_read", "input_cache_write",
        "input_cache_write_1h", "discount", "overrides"
    ]

    private func catalogDate(_ value: Any?) throws -> Date? {
        guard let value else { return nil }
        if let timestamp = value as? Double, timestamp.isFinite { return Date(timeIntervalSince1970: timestamp) }
        if let date = value as? Date { return date }
        if let string = value as? String {
            if let timestamp = Double(string), timestamp.isFinite { return Date(timeIntervalSince1970: timestamp) }
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions.insert(.withFractionalSeconds)
            if let date = formatter.date(from: string) { return date }
        }
        throw AgentXError.corrupt
    }

    func validate(_ state: AgentXState) throws {
        guard state.version == 1 else { throw AgentXError.invalid("不支持的配置版本。") }
        func validIDs(_ ids: [String]) -> Bool {
            Set(ids.map { $0.lowercased() }).count == ids.count && ids.allSatisfy { !$0.isEmpty && $0.utf8.count <= 100 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } }
        }
        guard validIDs(state.apps.map(\.id)), validIDs(state.providers.map(\.id)), validIDs(state.definitions.map(\.id)), validIDs(state.instances.map(\.id)),
              state.apps.allSatisfy({ $0.id == $0.id.lowercased() }),
              state.apps.allSatisfy({ ($0.id == "blackcat") == ($0.kind == .blackcat) }),
              state.apps.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              state.definitions.allSatisfy({ !$0.name.isEmpty && (!$0.prompt.isEmpty || $0.draft != nil) }) else { throw AgentXError.invalid("名称、标识或内建 BlackCat 配置无效。") }
        if !validIDs(state.runs.map(\.id)) {
            let owned = try AgentXPilot.configured(at: root)?.appIDs ?? []
            let groups = Dictionary(grouping: state.runs) { $0.id.lowercased() }
            for runs in groups.values {
                guard validIDs([runs[0].id]), runs.count == 1 ||
                        (runs.allSatisfy { owned.contains($0.appID) } && Set(runs.map(\.appID)).count == runs.count) else {
                    throw AgentXError.invalid("同一应用内的运行标识必须唯一。")
                }
            }
        }
        for app in state.apps { try app.validateManifest() }
        for provider in state.providers {
            guard !provider.name.isEmpty, (!provider.models.isEmpty || provider.isOpenRouter), provider.models.allSatisfy({ !$0.isEmpty }) else { throw AgentXError.invalid("请填写服务名称及模型 ID。") }
            _ = try AgentXProviderCatalog.modelsRequest(baseURL: provider.baseURL, protocol: provider.serviceProtocol, secret: nil)
            if let selection = provider.modelSelection {
                guard Set(selection.models.map(\.id)) == Set(provider.models), selection.models.count == provider.models.count else { throw AgentXCatalogError.invalidSelection }
            }
            if let profile = provider.credentialProfile, !(state.credentialProfiles ?? []).contains(where: { $0.name == profile }) { throw AgentXCredentialProfileError.invalidProfile }
        }
        guard validIDs((state.credentialProfiles ?? []).map(\.name)) else { throw AgentXCredentialProfileError.invalidProfile }
        for profile in state.credentialProfiles ?? [] {
            guard !profile.keyReferences.isEmpty, Set(profile.keyReferences).count == profile.keyReferences.count,
                  profile.keyReferences.allSatisfy({ !$0.isEmpty && !$0.contains(where: { $0.isNewline || $0 == "\0" }) }) else { throw AgentXCredentialProfileError.invalidProfile }
        }
        for definition in state.definitions {
            try definition.draft?.validate()
            let revisions = definition.revisions ?? []
            guard Set(revisions.map(\.number)).count == revisions.count, revisions.allSatisfy({ $0.number > 0 }) else { throw AgentXDefinitionError.invalidDocument }
            for revision in revisions { try revision.document.validate() }
            if definition.publishedRevision != nil { _ = try definition.publishedDocument() }
        }
        for instance in state.instances {
            if let revision = instance.definitionRevision {
                guard let definition = state.definitions.first(where: { $0.id == instance.definitionID }) else { throw AgentXDefinitionError.unpublished }
                _ = try definition.publishedDocument(revision: revision)
            }
            if let choice = instance.conversationModel {
                guard state.providers.contains(where: { $0.id == choice.providerID && $0.models.contains(choice.model) }) else { throw AgentXCatalogError.invalidSelection }
            }
            if let profile = instance.credentialProfile, !(state.credentialProfiles ?? []).contains(where: { $0.name == profile }) { throw AgentXCredentialProfileError.invalidProfile }
            guard !instance.name.isEmpty, state.apps.contains(where: { $0.id == instance.appID }),
                  state.definitions.contains(where: { $0.id == instance.definitionID }),
                  state.providers.contains(where: { $0.id == instance.providerID && $0.models.contains(instance.model) }) else {
                throw AgentXError.invalid("实例必须引用已有应用、定义和已选择的模型。")
            }
        }
        for app in state.apps {
            if let experience = app.experience {
                try experience.draft?.validateStructure()
                guard Set(experience.revisions.map(\.number)).count == experience.revisions.count,
                      experience.revisions.allSatisfy({ $0.number > 0 }),
                      experience.publishedRevision == nil || experience.published != nil else { throw AgentXError.corrupt }
                for revision in experience.revisions { try revision.configuration.validateStructure() }
            }
            if let workflow = app.workflow {
                try workflow.draft?.validate(appID: app.id, instances: state.instances, requireRunnable: false)
                guard Set(workflow.revisions.map(\.number)).count == workflow.revisions.count,
                      workflow.revisions.allSatisfy({ $0.number > 0 }),
                      workflow.publishedRevision == nil || workflow.published != nil else { throw AgentXError.corrupt }
                for revision in workflow.revisions { try revision.definition.validate(appID: app.id, instances: state.instances) }
            }
        }
        for run in state.runs {
            guard state.apps.contains(where: { $0.id == run.appID }),
                  !state.instances.contains(where: { $0.id == run.instanceID && $0.appID != run.appID }) else { throw AgentXError.unsafePath }
        }
        if let single = state.singleAppID, !state.apps.contains(where: { $0.id == single }) { throw AgentXError.invalid("单应用入口不存在。") }
    }
}
