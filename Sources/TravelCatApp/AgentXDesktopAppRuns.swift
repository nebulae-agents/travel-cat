import CryptoKit
import Foundation
import TravelStorage

/// All mutable execution and recovery state belongs to one registered application.
@MainActor
final class AgentXDesktopAppRuns {
    private let root: URL
    private let appID: String
    private let configuredApp: () -> AgentXApplication?
    private let binding: AgentXPilot.PiBinding?
    private let journal: AgentXRunEventJournal?
    private let runtime: any AgentXRunAdapter
    private let audit: AgentXRunAudit
    private let budget: AgentXGatewayBudget?
    private let gatewayState: () -> AgentXState?
    private let credentials: any TravelServiceCredentialStoring
    private var gatewayProfiles: AgentXCredentialProfiles?
    private var gatewayProfileDefinitions: [AgentXCredentialProfile] = []
    private struct GatewayPlan: Equatable {
        let binding: AgentXGatewayConfiguration.Binding
        let provider: AgentXProvider
        let permission: AgentXExecutionPolicy
        let credentialProfile: String?
    }
    private let canCreate: (String, AgentXPilot.PiBinding) -> Bool
    private let reportFailure: () -> Void
    // Preserve service fields that the desktop model does not consume, including old Pi receipts.
    private struct Snapshot {
        let run: AgentXRun
        let fields: [String: Any]
    }
    private var history: [String: Snapshot] = [:]
    var didSave: ((String) -> Void)?
    private var activeRunID: String?
    private var worker: Task<Void, Never>?
    private var writesBlocked = false

    init(root: URL, application: AgentXPilot.Configuration.Application, runtime: any AgentXRunAdapter,
         configuredApp: @escaping () -> AgentXApplication?, credentials: any TravelServiceCredentialStoring, canCreate: @escaping (String, AgentXPilot.PiBinding) -> Bool,
         reportFailure: @escaping () -> Void, gatewayState: @escaping () -> AgentXState? = { nil }, budget: AgentXGatewayBudget? = nil) throws {
        self.budget = budget
        self.gatewayState = gatewayState
        self.credentials = credentials
        self.root = root
        self.appID = application.appID
        self.binding = application.pi
        self.runtime = runtime
        self.configuredApp = configuredApp
        self.canCreate = canCreate
        self.reportFailure = reportFailure
        audit = AgentXRunAudit(root: root, credentials: credentials)
        let directory = try AgentXPackageFiles.safeURL("apps/\(appID)/runs", root: root)
        if application.usesEventJournal {
            journal = try AgentXRunEventJournal(root: root, appID: appID)
        } else {
            // A configuration edit must not let a stale cache take ownership again.
            for name in ["events/run-journal", ".run-journal-v1"] {
                let stored = try AgentXPackageFiles.safeURL("apps/\(appID)/\(name)", root: root)
                var info = stat()
                guard lstat(stored.path, &info) == -1, errno == ENOENT else {
                    throw AgentXError.invalid("此应用已有事件日志，请恢复 events-v1 配置。")
                }
            }
            journal = nil
        }
        let loadLegacy = {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return try Self.readLegacy(directory, appID: application.appID)
        }
        let records = try journal?.load(legacy: loadLegacy) ?? loadLegacy()
        for (id, fields) in records {
            history[id] = try Self.snapshot(fields, id: id, appID: appID)
        }
        if journal != nil {
            for snapshot in history.values {
                try repairProjection(snapshot, directory: directory)
            }
        }
        // Validate all snapshots before modifying any. The root lease excludes the old writer.
        do { try audit.prepare(appID: appID) } catch { reportFailure() }
        for snapshot in Array(history.values) {
            if snapshot.fields["auditContext"] != nil {
                if !snapshot.run.status.terminal, snapshot.run.pilotCreateKey != nil {
                    var run = snapshot.run
                    run.status = .failed
                    run.endedAt = Date()
                    run.stopEvidence = "unverified"
                    run.requiresProcessReview = true
                    run.failure = "桌面意外退出，之前的 Pi 运行已中断。"
                    try record(&run, phase: "failed", previous: snapshot.fields,
                               changes: ["desktopInterruptionAuditPending": true])
                }
                if let latest = history[snapshot.run.id] {
                    _ = try deliverPending(latest)
                }
            } else if snapshot.fields["auditStatus"] as? String != "pending" {
                try recoverInterruption(snapshot)
            }
        }
    }

    private static func snapshot(_ fields: [String: Any], id: String, appID: String) throws -> Snapshot {
        var fields = fields
        var run = try AgentXRun.serviceProjection(fields)
        guard id.wholeMatch(of: /[A-Za-z0-9_-]{1,100}/) != nil, run.id == id,
              run.appID == appID, (run.revision ?? 0) >= 0 else { throw AgentXError.corrupt }
        run.revision = run.revision ?? 0
        fields["revision"] = run.revision
        return Snapshot(run: run, fields: fields)
    }

    private static func readProjection(_ file: URL) throws -> Data? {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw AgentXError.unsafePath
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else { throw AgentXError.unsafePath }
        return try handle.readToEnd() ?? Data()
    }

    private static func readLegacy(_ directory: URL, appID: String) throws -> [String: [String: Any]] {
        var records: [String: [String: Any]] = [:]
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "json" {
            let id = file.deletingPathExtension().lastPathComponent
            guard let data = try readProjection(file),
                  let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AgentXError.corrupt }
            records[id] = try snapshot(fields, id: id, appID: appID).fields
        }
        return records
    }

    private func repairProjection(_ snapshot: Snapshot, directory: URL) throws {
        let file = directory.appendingPathComponent(snapshot.run.id + ".json")
        let bytes = try Self.readProjection(file)
        if let bytes, var cached = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] {
            if cached["revision"] == nil { cached["revision"] = 0 }
            // Keep the original encoding of a semantically identical historical record.
            if try Self.projectionBytes(cached) == Self.projectionBytes(snapshot.fields) { return }
        }
        let data = try Self.projectionBytes(snapshot.fields)
        do { try AtomicFileWriter().write(data, to: file) } catch { reportFailure() }
    }

    private static func projectionBytes(_ fields: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }

    // Commit the run and its audit intent together. A retry reuses the exact
    // original metadata, including the timestamp and event ID, after any crash.
    private func record(_ run: inout AgentXRun, phase: String, previous: [String: Any],
                        changes: [String: Any] = [:]) throws {
        var changes = changes
        do {
            if run.status.terminal { try budget?.abandon(appID: appID, runID: run.id) }
            if let receipt = try budget?.receipt(appID: appID, runID: run.id) { changes["budget"] = receipt }
        } catch { changes["budget"] = ["status": "unavailable"] }
        let source = previous.merging(changes) { _, new in new }
        guard var event = source["auditContext"] as? [String: Any] else { throw AgentXError.corrupt }
        event["taskId"] = run.id
        event["appId"] = run.appID
        event["instanceId"] = run.instanceID
        event["eventId"] = UUID().uuidString.lowercased()
        event["timestamp"] = ISO8601DateFormatter().string(from: Date())
        event["kind"] = "model.request." + phase
        if run.status.terminal {
            event["status"] = phase
            event["responseBytes"] = run.response.utf8.count
        }
        let outbox = (source["auditOutbox"] as? [[String: Any]] ?? []) + [event]
        run.auditFailure = "审计尚未确认，服务将在恢复时重试。"
        let fields = try updatedFields(for: &run, previous: source, kind: phase == "started" ? "created" : "updated",
                                       changes: ["auditStatus": "pending", "auditOutbox": outbox])
        try persist(run, retaining: fields)
    }

    private func deliverPending(_ snapshot: Snapshot) throws -> Bool {
        guard snapshot.fields["auditStatus"] as? String == "pending" else { return true }
        var run = snapshot.run
        var fields = snapshot.fields
        guard let records = fields["auditOutbox"] as? [[String: Any]], !records.isEmpty else { return false }
        let delivered = fields["auditDelivered"] as? Int ?? 0
        guard (0...records.count).contains(delivered) else { throw AgentXError.corrupt }
        do { try audit.deliver(records.dropFirst(delivered), run: run) }
        catch { reportFailure(); return false }
        fields = try updatedFields(for: &run, previous: fields, kind: "auditConfirmed", changes: [:])
        fields["auditDelivered"] = records.count
        fields["auditStatus"] = "confirmed"
        fields.removeValue(forKey: "desktopInterruptionAuditPending")
        fields.removeValue(forKey: "auditFailure")
        run.auditFailure = nil
        try persist(run, retaining: fields)
        return true
    }

    private func recoverInterruption(_ snapshot: Snapshot) throws {
        var run = snapshot.run
        var fields = snapshot.fields
        if !run.status.terminal, run.pilotCreateKey != nil {
            run.status = .failed
            run.endedAt = Date()
            run.failure = "桌面意外退出，之前的 Pi 运行已中断。"
            run.stopEvidence = "unverified"
            run.requiresProcessReview = true
            run.auditFailure = "中断记录的审计待确认。"
            fields = try updatedFields(for: &run, previous: fields, kind: "updated",
                                       changes: ["desktopInterruptionAuditPending": true])
            try persist(run, retaining: fields)
        }
        guard fields["desktopInterruptionAuditPending"] as? Bool == true else { return }
        guard run.status == .failed, run.requiresProcessReview == true, run.stopEvidence == "unverified" else { throw AgentXError.corrupt }
        do { run.auditFailure = try audit.finishInterrupted(run) }
        catch {
            // The run stays visible, and the next launch retries the encrypted audit.
            writesBlocked = true
            reportFailure()
            return
        }
        if journal != nil || snapshot.fields["desktopInterruptionAuditPending"] as? Bool == true {
            // The earlier launch may already have served the pending snapshot.
            fields = try updatedFields(for: &run, previous: fields, kind: "auditConfirmed", changes: [:])
        }
        fields.removeValue(forKey: "desktopInterruptionAuditPending")
        fields.removeValue(forKey: "auditFailure")
        try persist(run, retaining: fields)
    }

    func list() throws -> Data {
        let records = history.values.sorted { $0.run.id < $1.run.id }.map(\.fields)
        return try JSONSerialization.data(withJSONObject: records)
    }

    private func reply(_ code: Int, _ fields: [String: Any] = [:]) throws -> (Int, Data) {
        (code, try JSONSerialization.data(withJSONObject: fields))
    }

    func lookup(_ id: String) throws -> (Int, Data) {
        guard let snapshot = history[id] else { return try reply(404) }
        return try reply(200, snapshot.fields)
    }

    enum EventBatch {
        case missing
        case snapshotRequired(Int)
        case available(Int, [[String: Any]])

        func response() throws -> (Int, Data) {
            switch self {
            case .missing: return (404, Data("{}".utf8))
            case .snapshotRequired(let revision):
                return (409, try JSONSerialization.data(withJSONObject: ["error": "snapshot_required", "revision": revision]))
            case let .available(revision, events):
                return (200, try JSONSerialization.data(withJSONObject: ["revision": revision, "events": events]))
            }
        }
    }

    func events(_ id: String, after cursor: UInt64) -> EventBatch {
        guard let snapshot = history[id] else { return .missing }
        let revision = snapshot.run.revision ?? 0
        let retained = snapshot.fields["events"] as? [[String: Any]] ?? []
        // Older desktop snapshots can have a revision without a corresponding event.
        // Only serve a suffix that reaches the current snapshot without a gap.
        var next = revision
        var batch: [[String: Any]] = []
        for event in retained.suffix(64).reversed() {
            guard UInt64(next) > cursor, event["revision"] as? Int == next else { break }
            batch.append(event)
            next -= 1
        }
        guard UInt64(next) == cursor else {
            return .snapshotRequired(revision)
        }
        return .available(revision, Array(batch.reversed()))
    }

    func setRead(_ id: String, body: Data) throws -> (Int, Data) {
        guard let input = try? StrictJSONPreflight.objectMembers(body), Set(input.keys) == ["isRead", "expectedRevision"],
              let flag = input["isRead"].flatMap({ Bool(String(decoding: $0, as: UTF8.self)) }),
              let raw = input["expectedRevision"].map({ String(decoding: $0, as: UTF8.self) }),
              raw.wholeMatch(of: /(?:-0|[0-9]+)/) != nil else { return try reply(400) }
        guard let snapshot = history[id] else { return try reply(404) }
        var run = snapshot.run
        // A valid JSON integer outside Swift's range is a stale revision as well.
        guard Int(raw) == run.revision else { return try reply(409, snapshot.fields) }
        guard snapshot.fields["isRead"] == nil || run.isRead != flag else { return try reply(200, snapshot.fields) }
        run.isRead = flag
        let fields = try updatedFields(for: &run, previous: snapshot.fields, kind: "readFlagChanged",
                                       changes: ["isRead": run.isRead])
        try save(run, fields: fields)
        if let saved = history[id] { _ = try deliverPending(saved) }
        return try lookup(id)
    }

    func stop(_ id: String, key: String?) throws -> (Int, Data) {
        guard let key, key.wholeMatch(of: /[a-zA-Z0-9_.:-]{1,128}/) != nil else {
            return try reply(400, ["error": "invalid_idempotency_key"])
        }
        guard let snapshot = history[id] else { return try reply(404) }
        var run = snapshot.run
        guard run.pilotCreateKey != nil else { return try reply(409, ["error": "not_a_service_execution"]) }
        if run.status.terminal { return try reply(200, snapshot.fields) }
        if run.status == .cancelling { return try reply(202, snapshot.fields) }
        guard activeRunID == id, let worker else { return try reply(409, ["error": "unverified_owner"]) }

        run.status = .cancelling
        run.stopEvidence = "pending"
        // Signal the owned task even if writing the pending snapshot fails.
        do {
            defer { worker.cancel() }
            try record(&run, phase: "cancel_requested", previous: snapshot.fields, changes: [
                "stopRequestedAt": Date().timeIntervalSinceReferenceDate, "pilotStopKey": AgentXPackageFiles.digest(Data(key.utf8))
            ])
        }
        guard let pending = history[id] else { throw AgentXError.corrupt }
        _ = try deliverPending(pending)
        return (202, try lookup(id).1)
    }

    private func updatedFields(for run: inout AgentXRun, previous: [String: Any], kind: String,
                               changes: [String: Any], eventFields: [String: Any] = [:]) throws -> [String: Any] {
        let revision = run.revision ?? 0
        guard revision < Int.max else { throw AgentXError.corrupt }
        run.revision = revision + 1
        var event: [String: Any] = ["eventId": "\(run.id):\(revision + 1)", "runId": run.id,
            "revision": revision + 1, "kind": kind, "state": run.status.rawValue]
        event.merge(eventFields) { field, _ in field }
        if kind == "readFlagChanged", let storedState = previous["status"] as? String { event["state"] = storedState }
        if let evidence = run.stopEvidence { event["stopEvidence"] = evidence }
        var fields = previous.merging(changes) { _, new in new }
        let retained = previous["events"] as? [Any] ?? []
        fields["events"] = Array(retained.suffix(63)) + [event]
        fields["revision"] = revision + 1
        return fields
    }

    func readAudit(runID: String) throws -> (Int, Data) {
        guard let snapshot = history[runID] else { return (404, Data("{}".utf8)) }
        do {
            let report = try audit.verifiedReport(for: snapshot.run, storedStatus: snapshot.fields["auditStatus"] as? String)
            return (200, try JSONSerialization.data(withJSONObject: report))
        } catch { return (503, Data(#"{"error":"audit_unavailable"}"#.utf8)) }
    }

    private func gatewayPlan(_ pilot: AgentXPilot.PiBinding) throws -> GatewayPlan? {
        let file = root.appendingPathComponent("manager/gateway.yaml")
        var info = stat()
        let requiresGateway = try budget?.requiresGateway() ?? false
        if lstat(file.path, &info) == -1, errno == ENOENT {
            guard !requiresGateway else { throw AgentXBudgetFailure.unavailable }
            if runtime is AgentXPiRuntime, let app = configuredApp() {
                let provider = AgentXProvider(id: pilot.providerID, name: pilot.providerID, baseURL: pilot.baseURL, models: [pilot.model])
                let permission = try AgentXExecutionPolicy(root: root, application: app, provider: provider)
                try permission.deny("runtime.gateway", runID: nil)
            }
            return nil
        }
        guard journal != nil, let state = gatewayState() else { throw AgentXError.unavailable }
        let configuration = try AgentXGatewayConfiguration.load(root: root)
        let binding = try configuration.binding(appID: appID, state: state)
        guard binding.providerID == pilot.providerID, binding.model == pilot.model,
              let provider = state.providers.first(where: { $0.id == binding.providerID }), provider.baseURL == pilot.baseURL,
              let member = state.instances.first(where: { $0.appID == appID && $0.id == pilot.instanceID }) else { throw AgentXError.unavailable }
        guard let app = configuredApp() else { throw AgentXError.unavailable }
        let permission = try AgentXExecutionPolicy(root: root, application: app, provider: provider)
        return GatewayPlan(binding: binding, provider: provider, permission: permission, credentialProfile: member.credentialProfile ?? provider.credentialProfile)
    }

    private func gatewaySecret(_ plan: GatewayPlan, pilot: AgentXPilot.PiBinding) throws -> String? {
        // Re-read config and enabled bindings immediately before resolving a key and submitting.
        guard try gatewayPlan(pilot) == plan, let state = gatewayState() else { throw AgentXError.unavailable }
        if let profile = plan.credentialProfile {
            let definitions = state.credentialProfiles ?? []
            if gatewayProfiles == nil || gatewayProfileDefinitions != definitions {
                gatewayProfiles = AgentXCredentialProfiles(profiles: definitions, store: credentials)
                gatewayProfileDefinitions = definitions
            }
            return try gatewayProfiles?.nextSecret(profile: profile)
        }
        return try credentials.read(id: plan.provider.credentialID)
    }

    private func validPiBinding(_ binding: AgentXPilot.PiBinding) -> Bool {
        guard let url = URLComponents(string: binding.baseURL), url.scheme == "http",
              ["127.0.0.1", "[::1]"].contains(url.host), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, !binding.baseURL.contains("\\"),
              !binding.baseURL.unicodeScalars.contains(where: { $0.value < 32 }),
              url.port.map({ (1...65535).contains($0) }) ?? true,
              !binding.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, binding.model.utf8.count <= 512 else {
            return false
        }
        return true
    }

    private func supports(_ app: AgentXApplication?) -> Bool {
        guard let declaration = app?.declaredTextRuntime else { return false }
        return declaration == .hostText || declaration.rawValue == runtime.runtimeCore
    }

    func runtimeReport() throws -> (Int, Data) {
        let selection = configuredApp()
        let supported = supports(selection)
        let health: String
        if !supported {
            health = "unsupported_runtime"
        } else if let binding {
            do {
                let gateway = try gatewayPlan(binding)
                health = (gateway != nil || validPiBinding(binding)) && canCreate(appID, binding) ? runtime.localHealth : "invalid_binding"
            } catch { health = "invalid_binding" }
        } else {
            health = "unbound"
        }
        var report: [String: Any] = ["appID": appID, "configuredRuntime": selection?.runtime as Any? ?? NSNull(),
                                    "runtimeCore": supported ? runtime.runtimeCore as Any : NSNull(), "health": health,
                                    "capabilities": supported ? runtime.capabilities(streaming: journal != nil) : [:]]
        do {
            if let summary = try budget?.summary(), summary["status"] as? String != "disabled" { report["budget"] = summary }
        } catch { report["budget"] = ["status": "unavailable"] }
        return try reply(200, report)
    }

    func create(key: String?, body: Data) throws -> (Int, Data) {
        let input: [String: Data]?
        do { input = body.isEmpty ? [:] : try StrictJSONPreflight.objectMembers(body) }
        catch { return try reply(400) }
        guard let key, key.wholeMatch(of: /[a-zA-Z0-9_.:-]{1,128}/) != nil else {
            return try reply(400, ["error": "invalid_idempotency_key"])
        }
        let decoder = JSONDecoder()
        guard let input, Set(input.keys) == ["prompt", "instanceId"],
              let prompt = input["prompt"].flatMap({ try? decoder.decode(String.self, from: $0) }),
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf8.count <= 100_000,
              let instance = input["instanceId"].flatMap({ try? decoder.decode(String.self, from: $0) }),
              instance.wholeMatch(of: /[A-Za-z0-9_-]{1,100}/) != nil else {
            return try reply(400, ["error": "invalid_run"])
        }
        let digest = AgentXPackageFiles.digest(Data(key.utf8))
        let id = Self.runID(appID: appID, digest: digest)
        if let existing = history[id] {
            guard existing.run.pilotCreateKey == digest, existing.run.instanceID == instance,
                  existing.run.prompt == prompt else { return try reply(409, ["error": "idempotency_conflict"]) }
            return (200, try JSONSerialization.data(withJSONObject: existing.fields))
        }
        guard supports(configuredApp()) else { return try reply(422, ["error": "unsupported_runtime"]) }
        guard let binding else { return try reply(503, ["error": "pi_unavailable"]) }
        for pending in Array(history.values) where pending.fields["auditStatus"] as? String == "pending" {
            guard try deliverPending(pending) else { return try reply(503, ["error": "audit_unavailable"]) }
        }
        guard !writesBlocked else { return try reply(503, ["error": "audit_unavailable"]) }
        guard instance == binding.instanceID else { return try reply(422, ["error": "unbound_instance"]) }
        let gateway: GatewayPlan?
        do { gateway = try gatewayPlan(binding) }
        catch { return try reply(422, ["error": "invalid_gateway_configuration"]) }
        guard gateway != nil || validPiBinding(binding) else {
            return try reply(422, ["error": "invalid_pi_configuration_or_context"])
        }
        guard canCreate(appID, binding) else { return try reply(422, ["error": "unbound_instance"]) }
        let turns = history.values.map(\.run).filter { $0.instanceID == binding.instanceID }
        guard worker == nil, !turns.contains(where: { !$0.status.terminal || $0.requiresProcessReview == true }) else { return try reply(409, ["error": "instance_busy"]) }
        var messages = [AgentXMessage(role: "system", content: binding.systemPrompt)]
        let completeTurns = turns.filter { turn in
            guard turn.status == .completed, turn.purpose == nil, let fields = history[turn.id]?.fields else { return false }
            return fields["startedAt"] != nil && fields["prompt"] != nil && fields["response"] != nil
        }
        for turn in completeTurns.sorted(by: { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }).suffix(20) {
            messages.append(.init(role: "user", content: turn.prompt))
            messages.append(.init(role: "assistant", content: turn.response))
        }
        messages.append(.init(role: "user", content: prompt))
        guard !history.keys.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) else { return try reply(409, ["error": "idempotency_conflict"]) }
        let provider = AgentXProvider(id: binding.providerID, name: binding.providerID, baseURL: gateway == nil ? binding.baseURL : "http://127.0.0.1:1", models: [binding.model])
        let payload: Data
        do { payload = try runtime.prepare(provider: provider, model: binding.model, secret: nil, messages: messages) }
        catch { return try reply(422, ["error": "invalid_pi_configuration_or_context"]) }
        var run = AgentXRun(id: id, appID: appID, instanceID: binding.instanceID, prompt: prompt, status: .running,
                            actualProviderID: provider.id, actualModel: binding.model, runtimeCore: runtime.runtimeCore, revision: 0, pilotCreateKey: digest)
        let context: [String: Any] = ["providerId": provider.id, "model": binding.model, "promptBytes": prompt.utf8.count,
                                      "requestTextBytes": messages.reduce(0) { $0 + $1.content.utf8.count }]
        var initialFields: [String: Any] = ["auditContext": context]
        if gateway != nil { initialFields["usageStatus"] = "unknown" }
        try record(&run, phase: "started", previous: initialFields)
        guard let start = history[id] else { throw AgentXError.corrupt }
        guard try deliverPending(start) else {
            run.status = .failed
            run.endedAt = Date()
            run.failure = "开始审计尚未确认，未启动 Pi。"
            try record(&run, phase: "failed", previous: start.fields)
            return try reply(503, ["error": "audit_unavailable"])
        }
        activeRunID = id
        worker = Task { await execute(run, payload: payload, gatewayPlan: gateway) }
        guard let created = history[id] else { throw AgentXError.corrupt }
        return try reply(201, created.fields)
    }

    // Match Python uuid.uuid5(uuid.NAMESPACE_URL, "agentxd/" + app + "/" + digest).
    private static func runID(appID: String, digest: String) -> String {
        var namespace = UUID(uuidString: "6ba7b811-9dad-11d1-80b4-00c04fd430c8")!.uuid
        let name = Data("agentxd/\(appID)/\(digest)".utf8)
        var bytes = Array(Insecure.SHA1.hash(data: withUnsafeBytes(of: &namespace) { Data($0) } + name).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)).uuidString.lowercased() }
    }

    private func persist(_ run: AgentXRun, retaining existing: [String: Any] = [:]) throws {
        let bytes = try JSONEncoder().encode(run)
        guard let updated = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw AgentXError.corrupt }
        let fields = existing.merging(updated) { _, new in new }
        try save(run, fields: fields)
    }

    private func save(_ run: AgentXRun, fields: [String: Any], checkpoint: Bool = true) throws {
        func writeProjection() throws {
            let file = try AgentXPackageFiles.safeURL("apps/\(appID)/runs/\(run.id).json", root: root)
            try AtomicFileWriter().write(Self.projectionBytes(fields), to: file)
        }
        if let journal {
            try journal.append(id: run.id, previous: history[run.id]?.fields, fields: fields)
            // A committed event stays visible even if its disposable cache is unavailable.
            if checkpoint {
                do { try writeProjection() } catch { reportFailure() }
            }
        } else {
            try writeProjection()
        }
        history[run.id] = Snapshot(run: run, fields: fields)
        didSave?(run.id)
    }

    private func progress(_ update: AgentXRunProgress, id: String) throws {
        guard let snapshot = history[id], snapshot.run.status == .running else { throw CancellationError() }
        var run = snapshot.run
        let fields: [String: Any]
        switch update {
        case .text(let text):
            guard !text.isEmpty, run.response.utf8.count + text.utf8.count <= 65_536 else {
                throw AgentXPiRuntimeError.invalidResponse
            }
            run.response += text
            fields = try updatedFields(for: &run, previous: snapshot.fields, kind: "textDelta",
                                       changes: ["response": run.response], eventFields: ["text": text])
        case .usage(let input, let output):
            guard input >= 0, output >= 0 else { throw AgentXPiRuntimeError.invalidResponse }
            let counts = ["inputTokens": input, "outputTokens": output]
            var changes: [String: Any] = ["usage": counts]
            if snapshot.fields["usageStatus"] != nil { changes["usageStatus"] = "reported" }
            fields = try updatedFields(for: &run, previous: snapshot.fields, kind: "usageReported",
                                       changes: changes, eventFields: counts)
        }
        try save(run, fields: fields, checkpoint: false)
    }

    private func execute(_ initial: AgentXRun, payload: Data, gatewayPlan plan: GatewayPlan?) async {
        var gateway: AgentXModelGateway?
        var runtimeInvoked = false
        defer { gateway?.close(); worker = nil; activeRunID = nil }
        var run = initial
        do {
            var payload = payload
            var sandbox: AgentXPiSandbox?
            if let plan, let pilot = binding {
                let proxy = try AgentXModelGateway(appID: appID, runID: initial.id, provider: plan.provider,
                    binding: plan.binding, permission: plan.permission, credential: { try self.gatewaySecret(plan, pilot: pilot) },
                    beforeSubmit: { try self.budget?.reserve(appID: self.appID, runID: initial.id, provider: plan.provider,
                                                           model: plan.binding.model, maxOutputTokens: plan.binding.maxOutputTokens) },
                    onUsage: { input, output in try self.budget?.observe(appID: self.appID, runID: initial.id, input: input, output: output) },
                    onComplete: { trusted in
                        if trusted { try self.budget?.complete(appID: self.appID, runID: initial.id) }
                        else { try self.budget?.abandon(appID: self.appID, runID: initial.id) }
                    }, onClose: { try self.budget?.abandon(appID: self.appID, runID: initial.id) })
                gateway = proxy
                let baseURL = try await proxy.start()
                sandbox = try plan.permission.sandbox(gatewayURL: baseURL, runID: initial.id)
                guard var request = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw AgentXError.corrupt }
                request["baseURL"] = baseURL
                request["gatewayToken"] = proxy.token
                request["maxOutputTokens"] = plan.binding.maxOutputTokens
                request["timeoutSeconds"] = plan.binding.timeoutSeconds
                request["secret"] = ""
                payload = try JSONSerialization.data(withJSONObject: request)
            }
            try Task.checkCancellation()
            var onProgress: AgentXRunProgressHandler?
            if journal != nil {
                onProgress = { event in try self.progress(event, id: initial.id) }
            }
            runtimeInvoked = true
            let proxy = gateway
            run.response = try await withTaskCancellationHandler {
                try await AgentXPermissionContext.$sandbox.withValue(sandbox) {
                    try await runtime.execute(runID: initial.id, payload: payload, progress: onProgress)
                }
            } onCancel: { Task { @MainActor in proxy?.close() } }
            run.status = .completed
        } catch {
            run.status = Task.isCancelled ? .cancelled : .failed
            if plan != nil, !Task.isCancelled { run.failure = "模型网关请求未完成，请检查配置、连接或请求限额。" }
        }
        gateway?.close()
        if let reason = gateway?.budgetFailure { run.failure = reason }
        let exited = runtime.confirmedExit(runID: run.id)
        run.stopEvidence = exited ? "confirmedExited" : "unverified"
        run.requiresProcessReview = runtimeInvoked && !exited
        run.endedAt = Date()
        // HTTP mutations may have committed while Pi was executing.
        guard let latest = history[run.id] else { reportFailure(); return }
        if run.status != .completed { run.response = latest.run.response }
        run.isRead = latest.run.isRead
        run.revision = latest.run.revision
        do {
            try record(&run, phase: run.status.rawValue, previous: latest.fields)
            guard let terminal = history[run.id] else { throw AgentXError.corrupt }
            _ = try deliverPending(terminal)
        } catch {
            writesBlocked = true
            reportFailure()
            return
        }
    }

    func cancelForShutdown() {
        guard let activeRunID else { return }
        do { _ = try stop(activeRunID, key: "service-shutdown") }
        catch { worker?.cancel(); reportFailure() }
    }

    func waitForExit() async { await worker?.value }
}
