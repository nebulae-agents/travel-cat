import Foundation
import Dispatch
import TravelCore
#if canImport(Darwin)
import Darwin
#endif

public struct AgentCLIInvocation: Sendable {
    public let command: TravelCLICommand
    public let standardInput: Data
    public let dataRoot: URL

    public init(command: TravelCLICommand, standardInput: Data = Data(), dataRoot: URL) {
        self.command = command
        self.standardInput = standardInput
        self.dataRoot = dataRoot
    }
}

public struct AgentCLIResponse: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public init(status: Int32, stdout: Data, stderr: Data) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol TravelAgentCLIExecuting: AnyObject {
    func run(_ invocation: AgentCLIInvocation) throws -> AgentCLIResponse
}

public enum TravelAgentRepairKind: Equatable, Sendable {
    case structural
    case semantic
}

public enum TravelAgentStopReason: Equatable, Sendable {
    case claimOperational
    case candidateInvalid
    case repositoryBusy
    case validationOperational
    case validationRejected
    case publishOperational
    case acknowledgementMismatch
    case repairUnauthorized
}

public enum TravelAgentHeartbeatOutcome: Equatable, Sendable {
    case noOp
    case published(eventID: UUID, stateVersion: Int)
    case stopped(TravelAgentStopReason)
}

/// Executable conformance/reference semantics for tests and integrations.
/// This type is not a scheduled entry point and does not provide an LLM callback.
public struct TravelAgentHeartbeatRunner {
    public typealias CandidateProvider = (DueClaim) throws -> Data
    public typealias CandidateRepair = (Data, [String], TravelAgentRepairKind) throws -> Data

    private let cli: any TravelAgentCLIExecuting
    private let expectedDataRoot: URL

    public init(cli: any TravelAgentCLIExecuting, expectedDataRoot: URL) {
        self.cli = cli
        self.expectedDataRoot = expectedDataRoot
    }

    public func run(
        candidate candidateProvider: CandidateProvider,
        repair candidateRepair: CandidateRepair? = nil
    ) -> TravelAgentHeartbeatOutcome {
        guard Self.isTrustedAbsoluteFileURL(expectedDataRoot), expectedDataRoot.path != "/" else {
            return .stopped(.claimOperational)
        }
        let expectedDataRoot = expectedDataRoot.standardizedFileURL

        let claimResponse: AgentCLIResponse
        do {
            claimResponse = try cli.run(.init(command: .claim, dataRoot: expectedDataRoot))
        } catch {
            return .stopped(.claimOperational)
        }
        guard claimResponse.status == 0 else { return .stopped(.claimOperational) }
        guard !claimResponse.stdout.isEmpty else { return .noOp }
        guard let claim = try? JSONDecoder.travelCat.decode(DueClaim.self, from: claimResponse.stdout) else {
            return .stopped(.claimOperational)
        }
        guard claim.due else { return .noOp }

        var candidateData: Data
        do {
            candidateData = try candidateProvider(claim)
        } catch {
            return .stopped(.candidateInvalid)
        }

        var successfulValidation: ValidationResult?
        for attempt in 0..<2 {
            let response: AgentCLIResponse
            do {
                response = try cli.run(.init(
                    command: .validateCandidate,
                    standardInput: candidateData,
                    dataRoot: expectedDataRoot
                ))
            } catch {
                return .stopped(.validationOperational)
            }

            if response.status == 75 {
                guard let result = decodeRejectedValidation(response.stdout, expectedVersion: -1),
                      result.violations == ["repositoryBusy"] else {
                    return .stopped(.validationOperational)
                }
                return .stopped(.repositoryBusy)
            }

            if response.status == 65 || response.status == 66 {
                guard let result = decodeRejectedValidation(
                    response.stdout,
                    expectedVersion: claim.snapshot.stateVersion
                ) else {
                    return .stopped(.validationOperational)
                }
                guard attempt == 0, let candidateRepair else {
                    return .stopped(.validationRejected)
                }
                do {
                    let kind: TravelAgentRepairKind = response.status == 65 ? .structural : .semantic
                    let semanticAllowed: Set<CandidateField>?
                    let structuralAllowed: Set<String>?
                    if kind == .semantic {
                        guard let allowed = Self.allowedSemanticRepairFields(for: result.violations) else {
                            return .stopped(.repairUnauthorized)
                        }
                        semanticAllowed = allowed
                        structuralAllowed = nil
                    } else {
                        semanticAllowed = nil
                        guard let allowed = Self.allowedStructuralRepairRoots(
                            before: candidateData, violations: result.violations
                        ) else { return .stopped(.repairUnauthorized) }
                        structuralAllowed = allowed
                    }
                    let repairedData = try candidateRepair(candidateData, result.violations, kind)
                    let repaired = try AgentEventEnvelope.decode(repairedData)
                    switch kind {
                    case .structural:
                        guard let allowed = structuralAllowed,
                              Self.structuralRepairIsAuthorized(
                            before: candidateData, after: repairedData, allowed: allowed
                        ) else { return .stopped(.repairUnauthorized) }
                    case .semantic:
                        guard let allowed = semanticAllowed,
                              let original = try? AgentEventEnvelope.decode(candidateData),
                              Self.changedFields(from: original, to: repaired).isSubset(of: allowed) else {
                            return .stopped(.repairUnauthorized)
                        }
                    }
                    candidateData = repairedData
                } catch {
                    return .stopped(.candidateInvalid)
                }
                continue
            }

            guard response.status == 0,
                  let result = try? JSONDecoder.travelCat.decode(ValidationResult.self, from: response.stdout),
                  result.valid,
                  result.violations.isEmpty,
                  result.stateVersion == claim.snapshot.stateVersion,
                  result.publishEnvelope != nil else {
                return .stopped(.validationOperational)
            }
            successfulValidation = result
            break
        }

        guard let validation = successfulValidation,
              let envelope = validation.publishEnvelope else {
            return .stopped(.validationRejected)
        }

        guard let publishData = try? JSONEncoder.travelCat.encode(envelope) else {
            return .stopped(.publishOperational)
        }
        let publishResponse: AgentCLIResponse
        do {
            publishResponse = try cli.run(.init(
                command: .publish,
                standardInput: publishData,
                dataRoot: expectedDataRoot
            ))
        } catch {
            return .stopped(.publishOperational)
        }
        guard publishResponse.status == 0 else { return .stopped(.publishOperational) }
        guard let acknowledgement = try? JSONDecoder.travelCat.decode(
            PublishAcknowledgement.self,
            from: publishResponse.stdout
        ), acknowledgement.ok,
           acknowledgement.eventID == envelope.event.id,
           acknowledgement.stateVersion == validation.stateVersion + 1 else {
            return .stopped(.acknowledgementMismatch)
        }
        return .published(eventID: acknowledgement.eventID, stateVersion: acknowledgement.stateVersion)
    }

    private func decodeRejectedValidation(_ data: Data, expectedVersion: Int) -> ValidationResult? {
        guard let result = try? JSONDecoder.travelCat.decode(ValidationResult.self, from: data),
              !result.valid,
              !result.violations.isEmpty,
              result.stateVersion == expectedVersion,
              result.publishEnvelope == nil else { return nil }
        return result
    }

    private static func isTrustedAbsoluteFileURL(_ url: URL) -> Bool {
        url.isFileURL && url.baseURL == nil && url.path.hasPrefix("/")
    }

    private enum CandidateField: String, Hashable {
        case eventId, tripId, previousEventId, occurredAt, phase
        case location, transport, summary, mood, continuityReferences, openHook, consumedItemId, postcard
    }

    private static func allowedSemanticRepairFields(for violations: [String]) -> Set<CandidateField>? {
        var allowed = Set<CandidateField>()
        for violation in violations {
            let fields: Set<CandidateField>?
            if violation == "moodJump" { fields = [.mood] }
            else if violation == "missingAnchorReference" { fields = [.summary, .continuityReferences] }
            else if violation == "repeatedPlace" { fields = [.location] }
            else if violation == "consumedItemMismatch" || violation.hasPrefix("itemAlreadyConsumed:") {
                fields = [.consumedItemId]
            } else if violation.hasPrefix("locationRequired:") || violation.hasPrefix("locationForbidden:") {
                fields = [.location]
            } else if violation == "postcardPhaseMismatch"
                        || violation == "scenePromptRequired"
                        || violation == "scenePromptForbidden" {
                fields = [.postcard]
            } else if violation == "occurredAtAfterNow" {
                fields = [.occurredAt]
            } else {
                fields = nil
            }
            guard let fields else { return nil }
            allowed.formUnion(fields)
        }
        return allowed
    }

    private static func allowedStructuralRepairRoots(
        before: Data, violations: [String]
    ) -> Set<String>? {
        guard (try? JSONSerialization.jsonObject(with: before) as? [String: Any]) != nil else { return nil }
        let protected = Set(["eventId", "tripId", "previousEventId", "occurredAt", "phase"])
        let acceptedPrefixes = Set(["unknownKey", "missing", "invalid", "type", "range", "length", "duplicate", "untrimmed"])
        var allowed = Set<String>()
        for violation in violations {
            let parts = violation.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, acceptedPrefixes.contains(parts[0]),
                  let root = parts[1].split(separator: ".").first else { return nil }
            let rootName = String(root)
            guard !protected.contains(rootName) else { return nil }
            allowed.insert(rootName)
        }
        return allowed.isEmpty ? nil : allowed
    }

    private static func structuralRepairIsAuthorized(
        before: Data, after: Data, allowed: Set<String>
    ) -> Bool {
        guard let beforeRoot = try? JSONSerialization.jsonObject(with: before) as? [String: Any],
              let afterRoot = try? JSONSerialization.jsonObject(with: after) as? [String: Any] else { return false }
        let keys = Set(beforeRoot.keys).union(afterRoot.keys)
        let changed = Set(keys.filter { key in
            switch (beforeRoot[key], afterRoot[key]) {
            case (nil, nil): return false
            case let (lhs?, rhs?): return !NSDictionary(dictionary: ["v": lhs]).isEqual(to: ["v": rhs])
            default: return true
            }
        })
        return !changed.isEmpty && changed.isSubset(of: allowed)
    }

    private static func changedFields(
        from before: AgentEventEnvelope, to after: AgentEventEnvelope
    ) -> Set<CandidateField> {
        var changed = Set<CandidateField>()
        if before.eventId != after.eventId { changed.insert(.eventId) }
        if before.tripId != after.tripId { changed.insert(.tripId) }
        if before.previousEventId != after.previousEventId { changed.insert(.previousEventId) }
        if before.occurredAt != after.occurredAt { changed.insert(.occurredAt) }
        if before.phase != after.phase { changed.insert(.phase) }
        if before.location != after.location { changed.insert(.location) }
        if before.transport != after.transport { changed.insert(.transport) }
        if before.summary != after.summary { changed.insert(.summary) }
        if before.mood != after.mood { changed.insert(.mood) }
        if before.continuityReferences != after.continuityReferences { changed.insert(.continuityReferences) }
        if before.openHook != after.openHook { changed.insert(.openHook) }
        if before.consumedItemId != after.consumedItemId { changed.insert(.consumedItemId) }
        if before.postcard != after.postcard { changed.insert(.postcard) }
        return changed
    }
}

public enum ProcessTravelAgentCLIError: Error, Equatable, Sendable {
    case invalidExecutable
    case invalidLimits
    case unsafeDataRoot
    case timedOut
    case outputLimitExceeded
    case streamReadFailed
    case launchFailed(Int32)
}

/// Invokes a prebuilt CLI directly, never through a shell or `swift run`.
/// A dedicated process group bounds the whole child tree; output is drained into a combined bounded buffer.
public final class ProcessTravelAgentCLI: TravelAgentCLIExecuting {
    private let executableURL: URL
    private let timeout: TimeInterval
    private let terminationGrace: TimeInterval
    private let maxOutputBytes: Int
    private let directoryConfigurator: (URL) throws -> Void
    public private(set) var lastPeakBufferedBytes = 0

    public init(
        executableURL: URL,
        timeout: TimeInterval = 30,
        terminationGrace: TimeInterval = 0.5,
        maxOutputBytes: Int = 1_048_576
    ) throws {
        try Self.validate(executableURL, timeout: timeout, terminationGrace: terminationGrace, maxOutputBytes: maxOutputBytes)
        self.executableURL = executableURL.standardizedFileURL
        self.timeout = timeout
        self.terminationGrace = terminationGrace
        self.maxOutputBytes = maxOutputBytes
        self.directoryConfigurator = { url in
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }

    init(
        executableURL: URL,
        timeout: TimeInterval,
        terminationGrace: TimeInterval,
        maxOutputBytes: Int,
        directoryConfigurator: @escaping (URL) throws -> Void
    ) throws {
        try Self.validate(executableURL, timeout: timeout, terminationGrace: terminationGrace, maxOutputBytes: maxOutputBytes)
        self.executableURL = executableURL.standardizedFileURL
        self.timeout = timeout
        self.terminationGrace = terminationGrace
        self.maxOutputBytes = maxOutputBytes
        self.directoryConfigurator = directoryConfigurator
    }

    private static func validate(
        _ executableURL: URL,
        timeout: TimeInterval,
        terminationGrace: TimeInterval,
        maxOutputBytes: Int
    ) throws {
        guard executableURL.isFileURL,
              executableURL.baseURL == nil,
              executableURL.path.hasPrefix("/") else {
            throw ProcessTravelAgentCLIError.invalidExecutable
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.standardizedFileURL.path) else {
            throw ProcessTravelAgentCLIError.invalidExecutable
        }
        guard timeout.isFinite, terminationGrace.isFinite,
              timeout > 0, terminationGrace >= 0, maxOutputBytes > 0 else {
            throw ProcessTravelAgentCLIError.invalidLimits
        }
    }

    public func run(_ invocation: AgentCLIInvocation) throws -> AgentCLIResponse {
        guard invocation.dataRoot.isFileURL,
              invocation.dataRoot.baseURL == nil,
              invocation.dataRoot.path.hasPrefix("/"),
              invocation.dataRoot.path != "/" else {
            throw ProcessTravelAgentCLIError.unsafeDataRoot
        }
        let dataRoot = invocation.dataRoot.standardizedFileURL

        let parent = dataRoot.deletingLastPathComponent()
        let ioRoot = parent.appendingPathComponent(".travel-cat-agent-io-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ioRoot, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: ioRoot) }
        try directoryConfigurator(ioRoot)

        let inputURL = ioRoot.appendingPathComponent("stdin.json")
        try privateWrite(invocation.standardInput, to: inputURL)
        let input = try FileHandle(forReadingFrom: inputURL)
        defer { try? input.close() }
        let stdoutPipe = try makePipe()
        let stderrPipe: PipeDescriptors
        do { stderrPipe = try makePipe() }
        catch {
            Darwin.close(stdoutPipe.read); Darwin.close(stdoutPipe.write)
            throw error
        }
        var parentOwnsAllPipeEnds = true
        defer {
            if parentOwnsAllPipeEnds {
                Darwin.close(stdoutPipe.read)
                Darwin.close(stdoutPipe.write)
                Darwin.close(stderrPipe.read)
                Darwin.close(stderrPipe.write)
            }
        }

        let pid = try spawn(
            command: invocation.command.rawValue,
            dataRoot: dataRoot.path,
            inputFD: input.fileDescriptor,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe
        )
        Darwin.close(stdoutPipe.write)
        Darwin.close(stderrPipe.write)
        parentOwnsAllPipeEnds = false

        let collector = BoundedOutputCollector(limit: maxOutputBytes)
        let readerGroup = DispatchGroup()
        startReader(fd: stdoutPipe.read, stream: .stdout, collector: collector, group: readerGroup, processGroup: pid)
        startReader(fd: stderrPipe.read, stream: .stderr, collector: collector, group: readerGroup, processGroup: pid)

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var processError: ProcessTravelAgentCLIError?
        var waitStatus: Int32 = 0
        var reaped = false
        while !reaped || processGroupExists(pid) {
            if !reaped {
                let result = Darwin.waitpid(pid, &waitStatus, WNOHANG)
                if result == pid { reaped = true }
            }
            if collector.hasExceeded {
                processError = .outputLimitExceeded
                stopProcessGroup(pid)
                break
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                processError = .timedOut
                stopProcessGroup(pid)
                break
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        if !reaped { _ = Darwin.waitpid(pid, &waitStatus, 0) }
        if readerGroup.wait(timeout: .now() + max(1, terminationGrace * 4)) == .timedOut {
            processError = processError ?? .streamReadFailed
        }
        let captured = collector.snapshot()
        lastPeakBufferedBytes = captured.peak
        if captured.readFailed { processError = processError ?? .streamReadFailed }
        if captured.exceeded { processError = .outputLimitExceeded }
        if let processError { throw processError }

        return AgentCLIResponse(
            status: Self.exitStatus(waitStatus),
            stdout: captured.stdout,
            stderr: captured.stderr
        )
    }

    private typealias PipeDescriptors = (read: Int32, write: Int32)

    private func makePipe() throws -> PipeDescriptors {
        var descriptors = [Int32](repeating: 0, count: 2)
        guard descriptors.withUnsafeMutableBufferPointer({ Darwin.pipe($0.baseAddress!) }) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return (descriptors[0], descriptors[1])
    }

    private func spawn(
        command: String,
        dataRoot: String,
        inputFD: Int32,
        stdoutPipe: PipeDescriptors,
        stderrPipe: PipeDescriptors
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        let actionsInitialization = posix_spawn_file_actions_init(&actions)
        guard actionsInitialization == 0 else {
            throw ProcessTravelAgentCLIError.launchFailed(actionsInitialization)
        }
        let attributesInitialization = posix_spawnattr_init(&attributes)
        guard attributesInitialization == 0 else {
            posix_spawn_file_actions_destroy(&actions)
            throw ProcessTravelAgentCLIError.launchFailed(attributesInitialization)
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        func requireSetup(_ code: Int32) throws {
            guard code == 0 else { throw ProcessTravelAgentCLIError.launchFailed(code) }
        }
        try requireSetup(posix_spawn_file_actions_adddup2(&actions, inputFD, STDIN_FILENO))
        try requireSetup(posix_spawn_file_actions_adddup2(&actions, stdoutPipe.write, STDOUT_FILENO))
        try requireSetup(posix_spawn_file_actions_adddup2(&actions, stderrPipe.write, STDERR_FILENO))
        try requireSetup(posix_spawn_file_actions_addclose(&actions, stdoutPipe.read))
        try requireSetup(posix_spawn_file_actions_addclose(&actions, stderrPipe.read))
        if inputFD != STDIN_FILENO {
            try requireSetup(posix_spawn_file_actions_addclose(&actions, inputFD))
        }
        try requireSetup(posix_spawn_file_actions_addclose(&actions, stdoutPipe.write))
        try requireSetup(posix_spawn_file_actions_addclose(&actions, stderrPipe.write))
        try requireSetup(posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        ))
        try requireSetup(posix_spawnattr_setpgroup(&attributes, 0))

        var pid: pid_t = 0
        let result = try withCStringArray([executableURL.path, command]) { argv in
            try withCStringArray(["TRAVEL_CAT_DATA=\(dataRoot)"]) { environment in
                posix_spawn(&pid, executableURL.path, &actions, &attributes, argv, environment)
            }
        }
        guard result == 0 else { throw ProcessTravelAgentCLIError.launchFailed(result) }
        return pid
    }

    private func withCStringArray<R>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> R
    ) throws -> R {
        var allocated: [UnsafeMutablePointer<CChar>?] = []
        for string in strings {
            guard let pointer = strdup(string) else {
                allocated.forEach { free($0) }
                throw ProcessTravelAgentCLIError.launchFailed(ENOMEM)
            }
            allocated.append(pointer)
        }
        defer { allocated.forEach { free($0) } }
        var values = allocated
        values.append(nil)
        return try values.withUnsafeMutableBufferPointer { try body($0.baseAddress!) }
    }

    private func startReader(
        fd: Int32,
        stream: BoundedOutputCollector.Stream,
        collector: BoundedOutputCollector,
        group: DispatchGroup,
        processGroup: pid_t
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                while let data = try handle.read(upToCount: 4_096), !data.isEmpty {
                    if !collector.append(data, to: stream) {
                        _ = Darwin.kill(-processGroup, SIGTERM)
                        break
                    }
                }
            } catch {
                collector.markReadFailed()
            }
            try? handle.close()
        }
    }

    private func stopProcessGroup(_ pid: pid_t) {
        signalProcessGroup(pid, signal: SIGTERM)
        waitForProcessGroup(pid, interval: terminationGrace)
        if processGroupExists(pid) {
            signalProcessGroup(pid, signal: SIGINT)
            waitForProcessGroup(pid, interval: terminationGrace)
        }
        if processGroupExists(pid) {
            signalProcessGroup(pid, signal: SIGKILL)
            waitForProcessGroup(pid, interval: max(0.1, terminationGrace))
        }
    }

    private func signalProcessGroup(_ pid: pid_t, signal: Int32) {
        _ = Darwin.kill(-pid, signal)
    }

    private func processGroupExists(_ pid: pid_t) -> Bool {
        if Darwin.kill(-pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func waitForProcessGroup(_ pid: pid_t, interval: TimeInterval) {
        let deadline = ProcessInfo.processInfo.systemUptime + interval
        while processGroupExists(pid), ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    private static func exitStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    private func privateWrite(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }
}

private final class BoundedOutputCollector: @unchecked Sendable {
    enum Stream { case stdout, stderr }
    private let lock = NSLock()
    private let limit: Int
    private var stdout = Data()
    private var stderr = Data()
    private var exceeded = false
    private var readFailed = false
    private var peak = 0

    init(limit: Int) { self.limit = limit }

    var hasExceeded: Bool {
        lock.lock(); defer { lock.unlock() }
        return exceeded
    }

    func append(_ data: Data, to stream: Stream) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limit - stdout.count - stderr.count)
        if remaining > 0 {
            let prefix = data.prefix(remaining)
            if stream == .stdout { stdout.append(prefix) } else { stderr.append(prefix) }
        }
        peak = max(peak, stdout.count + stderr.count)
        if data.count > remaining { exceeded = true }
        return !exceeded
    }

    func markReadFailed() {
        lock.lock(); readFailed = true; lock.unlock()
    }

    func snapshot() -> (stdout: Data, stderr: Data, exceeded: Bool, readFailed: Bool, peak: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (stdout, stderr, exceeded, readFailed, peak)
    }
}
