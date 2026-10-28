import Foundation

public struct RepositoryExportProgress: Equatable, Sendable {
    public var completedFiles = 0
    public var copiedBytes: Int64 = 0
    public init() {}
}

/// Thread-safe cancellation and numeric progress. Publication and cancellation have
/// one commit boundary: after the final move a late cancellation cannot undo it.
public final class RepositoryExportControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var published = false
    private var publishing = false
    private var value = RepositoryExportProgress()
    private var lastReport = -Double.infinity
    private let minimumReportInterval: TimeInterval
    private let progress: @Sendable (RepositoryExportProgress) -> Void
    public init(minimumReportInterval: TimeInterval = 0.1, progress: @escaping @Sendable (RepositoryExportProgress) -> Void = { _ in }) {
        self.minimumReportInterval = minimumReportInterval.isFinite ? max(0, minimumReportInterval) : 0.1
        self.progress = progress
    }
    @discardableResult public func cancel() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !publishing, !published else { return false }
        cancelled = true; return true
    }
    public func checkCancellation() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
    func record(bytes: Int64 = 0, fileCompleted: Bool = false, forceReport: Bool = false) {
        lock.lock()
        value.copiedBytes += bytes
        if fileCompleted { value.completedFiles += 1 }
        let now = ProcessInfo.processInfo.systemUptime
        let report = forceReport || now - lastReport >= minimumReportInterval
        let snapshot = value
        if report { lastReport = now }
        lock.unlock()
        if report { progress(snapshot) }
    }
    func publish(_ commit: () throws -> Void) throws {
        lock.lock()
        guard !cancelled else { lock.unlock(); throw CancellationError() }
        // Reserve the commit boundary with a short critical section. Filesystem
        // publication can be slow; cancellation must never wait on its I/O lock.
        publishing = true
        lock.unlock()
        do {
            try commit()
            lock.lock(); published = true; publishing = false; lock.unlock()
        } catch {
            lock.lock(); publishing = false; lock.unlock()
            throw error
        }
    }
}
