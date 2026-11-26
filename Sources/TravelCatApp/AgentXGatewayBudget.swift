import Foundation
import Darwin
import TravelStorage

/// One instance is shared by every application under the desktop's exclusive root lease.
/// No await occurs between reading the durable balance and committing a reservation.
@MainActor
final class AgentXGatewayBudget {
    private enum Status: String, Codable { case reserved, pending, settled }
    private struct Entry: Codable {
        let appID: String
        let runID: String
        let provider: String
        let model: String
        let day: String
        let price: AgentXBudgetConfiguration.Price
        let inputCeiling: Int
        let outputCeiling: Int
        let reserved: AgentXBudgetMoney
        var held: AgentXBudgetMoney
        var status: Status = .reserved
        var input: Int?
        var output: Int?
        var actual: AgentXBudgetMoney?
    }
    private struct Ledger: Codable {
        var version = 1
        let id: String
        let currency: String
        let timeZone: String
        var blocked = false
        var entries: [String: Entry] = [:]
    }
    private let root: URL
    private let now: () -> Date
    private var poisoned = false
    private var initialized = false
    init(root: URL, now: @escaping () -> Date = { Date() }) { self.root = root; self.now = now }
    private var folder: URL { root.appendingPathComponent("manager/gateway-budget-v1") }
    private var seal: URL { root.appendingPathComponent("manager/.gateway-budget-v1") }
    private var activation: URL { root.appendingPathComponent(".gateway-budget-required-v1") }
    private var file: URL { folder.appendingPathComponent("ledger.json") }

    private func exists(_ path: URL) throws -> Bool {
        var info = stat()
        if lstat(path.path, &info) == 0 { return true }
        guard errno == ENOENT else { throw AgentXBudgetFailure.unavailable }
        return false
    }
    private func policy() throws -> AgentXBudgetConfiguration? {
        guard !poisoned else { throw AgentXBudgetFailure.unavailable }
        let path = try AgentXPackageFiles.safeURL("manager/gateway-budget.yaml", root: root)
        guard try exists(path) else {
            guard !initialized, try !exists(seal), try !exists(folder), try !exists(activation) else { throw AgentXBudgetFailure.unavailable }
            return nil
        }
        return try AgentXBudgetConfiguration.parse(AgentXGatewayConfiguration.read(root: root, fileName: "gateway-budget.yaml"))
    }
    func requiresGateway() throws -> Bool { try policy() != nil }

    private func day(_ date: Date, zone: String) throws -> String {
        guard let timeZone = TimeZone(identifier: zone) else { throw AgentXBudgetFailure.invalid }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    private func checkDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { throw AgentXBudgetFailure.unavailable }
    }
    private func read(_ url: URL, limit: Int = 16_777_216) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw AgentXBudgetFailure.unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o022 == 0, info.st_size <= limit else { throw AgentXBudgetFailure.unavailable }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw AgentXBudgetFailure.unavailable }
        return data
    }
    private func sync(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw AgentXBudgetFailure.unavailable }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw AgentXBudgetFailure.unavailable }
    }
    private func bytes(_ ledger: Ledger) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(ledger)
        guard bytes.count <= 16_777_216 else { throw AgentXBudgetFailure.unavailable }
        return bytes
    }
    private func load(policy: AgentXBudgetConfiguration? = nil, create: Bool = false, repair: Bool = true) throws -> Ledger? {
        guard !poisoned else { throw AgentXBudgetFailure.unavailable }
        _ = try AgentXPackageFiles.safeURL("manager/gateway-budget-v1/ledger.json", root: root)
        _ = try AgentXPackageFiles.safeURL("manager/.gateway-budget-v1", root: root)
        _ = try AgentXPackageFiles.safeURL(".gateway-budget-required-v1", root: root)
        let manager = root.appendingPathComponent("manager")
        if try !exists(folder) {
            guard !initialized, try !exists(seal), try !exists(activation) else { throw AgentXBudgetFailure.unavailable }
            guard let policy else { return nil }
            let initial = Ledger(id: UUID().uuidString, currency: policy.currency, timeZone: policy.timeZone)
            guard create else { return initial }
            try checkDirectory(manager)
            let stage = manager.appendingPathComponent(".budget-bootstrap-" + UUID().uuidString)
            guard mkdir(stage.path, 0o700) == 0 else { throw AgentXBudgetFailure.unavailable }
            defer { try? FileManager.default.removeItem(at: stage) }
            do {
                try AtomicFileWriter().write(bytes(initial), to: stage.appendingPathComponent("ledger.json"))
                guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, folder.path, UInt32(RENAME_EXCL)) == 0 else { throw AgentXBudgetFailure.unavailable }
                try sync(manager)
                try AtomicFileWriter().write(Data(initial.id.utf8), to: seal)
                try checkDirectory(root)
                try AtomicFileWriter().write(Data(initial.id.utf8), to: activation)
                initialized = true
            } catch { poisoned = true; throw AgentXBudgetFailure.unavailable }
            return initial
        }
        try checkDirectory(manager); try checkDirectory(folder)
        let data = try read(file)
        _ = try StrictJSONPreflight.objectMembers(data)
        let ledger = try JSONDecoder().decode(Ledger.self, from: data)
        guard ledger.version == 1, UUID(uuidString: ledger.id) != nil, ledger.entries.count <= 10_000,
              ledger.currency.wholeMatch(of: /[A-Z]{3}/) != nil, TimeZone(identifier: ledger.timeZone) != nil else { throw AgentXBudgetFailure.unavailable }
        if let policy {
            guard ledger.currency == policy.currency, ledger.timeZone == policy.timeZone else { throw AgentXBudgetFailure.invalid }
        }
        if try exists(seal) {
            guard try read(seal, limit: 64) == Data(ledger.id.utf8) else { throw AgentXBudgetFailure.unavailable }
        } else {
            // Only the empty, atomically published bootstrap may recover a missing seal.
            guard repair, ledger.entries.isEmpty else { throw AgentXBudgetFailure.unavailable }
            try AtomicFileWriter().write(Data(ledger.id.utf8), to: seal)
        }
        if try exists(activation) {
            guard try read(activation, limit: 64) == Data(ledger.id.utf8) else { throw AgentXBudgetFailure.unavailable }
        } else {
            guard repair, !initialized, ledger.entries.isEmpty else { throw AgentXBudgetFailure.unavailable }
            try checkDirectory(root)
            try AtomicFileWriter().write(Data(ledger.id.utf8), to: activation)
        }
        for (key, entry) in ledger.entries {
            try AgentXPackageFiles.validateID(entry.appID); try AgentXPackageFiles.validateID(entry.runID)
            guard key == entry.appID + "/" + entry.runID, (1...10_000_000).contains(entry.inputCeiling),
                  (1...65_536).contains(entry.outputCeiling), entry.day.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}/) != nil,
                  !entry.price.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !entry.price.revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  entry.reserved == (try entry.price.cost(input: entry.inputCeiling, output: entry.outputCeiling)),
                  entry.status == .settled ? entry.held == .zero : entry.held >= entry.reserved else { throw AgentXBudgetFailure.unavailable }
            if let input = entry.input, let output = entry.output {
                guard input >= 0, output >= 0 else { throw AgentXBudgetFailure.unavailable }
                if input > entry.inputCeiling || output > entry.outputCeiling {
                    guard ledger.blocked, entry.status != .settled else { throw AgentXBudgetFailure.unavailable }
                }
                if entry.status == .settled {
                    guard entry.actual == (try entry.price.cost(input: input, output: output)) else { throw AgentXBudgetFailure.unavailable }
                }
            } else if entry.input != nil || entry.output != nil || entry.status == .settled { throw AgentXBudgetFailure.unavailable }
            guard entry.status == .settled || entry.actual == nil else { throw AgentXBudgetFailure.unavailable }
        }
        if repair { initialized = true }
        return ledger
    }
    private func write(_ ledger: Ledger) throws {
        do {
            try checkDirectory(folder)
            _ = try read(file)
            try AtomicFileWriter().write(bytes(ledger), to: file)
        } catch { poisoned = true; throw AgentXBudgetFailure.unavailable }
    }
    private func totals(_ ledger: Ledger, day: String) throws -> (held: AgentXBudgetMoney, spent: AgentXBudgetMoney) {
        var held = AgentXBudgetMoney.zero, spent = AgentXBudgetMoney.zero
        for entry in ledger.entries.values where entry.day == day {
            held = try held.adding(entry.held)
            spent = try spent.adding(entry.actual ?? .zero)
        }
        return (held, spent)
    }
    func reserve(appID: String, runID: String, provider: AgentXProvider, model: String, maxOutputTokens: Int) throws {
        guard let policy = try policy() else { return }
        try AgentXPackageFiles.validateID(appID); try AgentXPackageFiles.validateID(runID)
        guard (1...65_536).contains(maxOutputTokens), let price = policy.prices[provider.id]?[model],
              let models = provider.modelSelection?.models.filter({ $0.id == model }), models.count == 1,
              let metadata = models.first, metadata.enabled, metadata.available, metadata.supportsTextOutput,
              !metadata.hasTieredPricing, let context = metadata.contextLength, (1...10_000_000).contains(context) else { throw AgentXBudgetFailure.invalid }
        for (key, value) in metadata.pricing ?? [:] where key != "prompt" && key != "completion" {
            guard (try? AgentXBudgetMoney(value)) == .zero else { throw AgentXBudgetFailure.invalid }
        }
        let amount = try price.cost(input: context, output: maxOutputTokens)
        guard var ledger = try load(policy: policy, create: true), !ledger.blocked else { throw AgentXBudgetFailure.unavailable }
        let key = appID + "/" + runID
        guard ledger.entries[key] == nil, ledger.entries.count < 10_000 else { throw AgentXBudgetFailure.duplicate }
        let today = try day(now(), zone: policy.timeZone)
        let total = try totals(ledger, day: today)
        guard try total.held.adding(total.spent).adding(amount) <= policy.limit else { throw AgentXBudgetFailure.exceeded }
        ledger.entries[key] = Entry(appID: appID, runID: runID, provider: provider.id, model: model, day: today,
            price: price, inputCeiling: context, outputCeiling: maxOutputTokens, reserved: amount, held: amount)
        try write(ledger)
    }
    func observe(appID: String, runID: String, input: Int, output: Int) throws {
        guard var ledger = try load(), var entry = ledger.entries[appID + "/" + runID] else { return }
        guard input >= 0, output >= 0 else { throw AgentXBudgetFailure.invalid }
        if let previous = entry.input {
            guard previous == input, entry.output == output else { throw AgentXBudgetFailure.invalid }
            return
        }
        let cost = try? entry.price.cost(input: input, output: output)
        entry.input = input; entry.output = output
        let breach = input > entry.inputCeiling || output > entry.outputCeiling || cost == nil || cost! > entry.reserved
        if breach {
            ledger.blocked = true
            if let cost { entry.held = max(entry.held, cost) }
            entry.status = .pending
        }
        ledger.entries[appID + "/" + runID] = entry
        try write(ledger)
        if breach { throw AgentXBudgetFailure.boundaryExceeded }
    }
    func complete(appID: String, runID: String) throws {
        guard var ledger = try load(), var entry = ledger.entries[appID + "/" + runID], entry.status != .settled else { return }
        guard !ledger.blocked, let input = entry.input, let output = entry.output else {
            try abandon(appID: appID, runID: runID); return
        }
        entry.actual = try entry.price.cost(input: input, output: output)
        entry.held = .zero; entry.status = .settled
        ledger.entries[appID + "/" + runID] = entry
        try write(ledger)
    }
    func abandon(appID: String, runID: String) throws {
        guard var ledger = try load(), var entry = ledger.entries[appID + "/" + runID], entry.status == .reserved else { return }
        entry.status = .pending; ledger.entries[appID + "/" + runID] = entry
        try write(ledger)
    }
    func receipt(appID: String, runID: String) throws -> [String: Any]? {
        guard let ledger = try load(), let entry = ledger.entries[appID + "/" + runID] else { return nil }
        return ["status": entry.status.rawValue, "day": entry.day, "currency": ledger.currency,
                "reserved": entry.reserved.description, "held": entry.held.description,
                "actual": entry.actual?.description as Any? ?? NSNull(), "priceSource": entry.price.source, "priceRevision": entry.price.revision]
    }
    struct Presentation {
        let status: String
        let day: String
        let currency: String
        let timeZone: String
        let limit: String
        let spent: String
        let held: String
        let available: String
        let source: Data?
    }
    func presentation() throws -> Presentation {
        guard let policy = try policy() else {
            return Presentation(status: "disabled", day: "", currency: "", timeZone: "", limit: "", spent: "", held: "", available: "", source: nil)
        }
        guard let ledger = try load(policy: policy, repair: false) else { throw AgentXBudgetFailure.unavailable }
        let today = try day(now(), zone: policy.timeZone)
        let total = try totals(ledger, day: today)
        let used = try total.spent.adding(total.held)
        let source = try AgentXGatewayConfiguration.read(root: root, fileName: "gateway-budget.yaml")
        let confirmed = try AgentXBudgetConfiguration.parse(source)
        guard confirmed.limit == policy.limit, confirmed.currency == policy.currency,
              confirmed.timeZone == policy.timeZone, confirmed.prices == policy.prices else { throw AgentXBudgetFailure.unavailable }
        return Presentation(status: ledger.blocked ? "blocked" : "enabled", day: today, currency: policy.currency,
            timeZone: policy.timeZone, limit: policy.limit.description, spent: total.spent.description,
            held: total.held.description, available: AgentXBudgetMoney(units: max(0, policy.limit.units - used.units)).description, source: source)
    }
    // Caller must hold the host gateway's root lease. No suspension occurs during validation or replacement.
    func saveLimit(_ limit: String, expectedSource: Data) throws {
        let amount = try AgentXBudgetMoney(limit)
        guard amount > .zero, try presentation().source == expectedSource else { throw AgentXBudgetFailure.invalid }
        var fields = try AgentXGatewayConfiguration.object(expectedSource)
        fields["daily_limit"] = limit
        let replacement = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        _ = try AgentXBudgetConfiguration.parse(replacement)
        let destination = try AgentXPackageFiles.safeURL("manager/gateway-budget.yaml", root: root)
        try checkDirectory(root.appendingPathComponent("manager"))
        guard try read(destination) == expectedSource else { throw AgentXBudgetFailure.invalid }
        try AtomicFileWriter().write(replacement, to: destination)
    }

    func summary() throws -> [String: Any] {
        guard let policy = try policy(), let ledger = try load(policy: policy) else { return ["status": "disabled"] }
        let today = try day(now(), zone: policy.timeZone), total = try totals(ledger, day: today)
        return ["status": ledger.blocked ? "blocked" : "enabled", "currency": policy.currency, "timeZone": policy.timeZone,
                "day": today, "limit": policy.limit.description, "held": total.held.description, "spent": total.spent.description]
    }
}
