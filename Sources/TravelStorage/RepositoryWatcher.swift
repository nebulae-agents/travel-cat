import Darwin
import Dispatch
import Foundation

public struct RepositoryWatcherBackoff: Sendable {
    private let baseDelay: Double
    private let maximumDelay: Double
    private var currentDelay: Double

    public init(baseDelay: Double = 0.15, maximumDelay: Double = 5) {
        self.baseDelay = max(0, baseDelay)
        self.maximumDelay = max(self.baseDelay, maximumDelay)
        currentDelay = self.baseDelay
    }

    public mutating func nextDelay() -> Double {
        let result = currentDelay
        currentDelay = min(maximumDelay, max(baseDelay, currentDelay * 2))
        return result
    }

    public mutating func reset() {
        currentDelay = baseDelay
    }
}

public final class RepositoryWatcher: @unchecked Sendable {
    private let repository: TravelRepository
    private let debounceSeconds: Double
    private let reportError: @Sendable (String) -> Void
    private let countLock = NSLock()
    private var streamCount = 0

    public init(
        repository: TravelRepository,
        debounce: Duration = .milliseconds(150),
        reportError: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.repository = repository
        self.reportError = reportError
        let components = debounce.components
        debounceSeconds = max(0, Double(components.seconds) + Double(components.attoseconds) / 1e18)
    }

    public var activeStreamCount: Int {
        countLock.withLock { streamCount }
    }

    public func contents() -> AsyncStream<RepositoryContents> {
        AsyncStream { continuation in
            countLock.withLock { streamCount += 1 }
            let session = Session(
                repository: repository,
                debounceSeconds: debounceSeconds,
                continuation: continuation,
                reportError: reportError
            ) { [weak self] in
                self?.countLock.withLock { self?.streamCount -= 1 }
            }
            continuation.onTermination = { @Sendable _ in session.stop() }
            session.start()
        }
    }
}

private final class Session: @unchecked Sendable {
    private let repository: TravelRepository
    private let debounceSeconds: Double
    private let continuation: AsyncStream<RepositoryContents>.Continuation
    private let reportError: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "com.nebulae.travelcat.repository-watcher")
    private let onStop: @Sendable () -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?
    private var needsReopen = false
    private var last: RepositoryContents?
    private var stopped = false
    private var retryBackoff: RepositoryWatcherBackoff

    init(
        repository: TravelRepository,
        debounceSeconds: Double,
        continuation: AsyncStream<RepositoryContents>.Continuation,
        reportError: @escaping @Sendable (String) -> Void,
        onStop: @escaping @Sendable () -> Void
    ) {
        self.repository = repository
        self.debounceSeconds = debounceSeconds
        self.continuation = continuation
        self.reportError = reportError
        self.onStop = onStop
        retryBackoff = RepositoryWatcherBackoff(baseDelay: debounceSeconds, maximumDelay: 5)
    }

    func start() {
        queue.async { [self] in
            guard !stopped else { return }
            reopenSources()
            loadAndYield()
        }
    }

    func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            pending?.cancel()
            pending = nil
            sources.forEach { $0.cancel() }
            sources.removeAll()
            continuation.finish()
            onStop()
        }
    }

    private func reopenSources() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        for name in ["state", "journal"] {
            let url = repository.root.appendingPathComponent(name, isDirectory: true)
            let descriptor = open(url.path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else {
                scheduleRetry(reopen: true)
                continue
            }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .link, .rename, .delete],
                queue: queue
            )
            source.setEventHandler { [self, weak source] in
                let flags = source?.data ?? []
                retryBackoff.reset()
                schedule(reopen: flags.contains(.rename) || flags.contains(.delete))
            }
            source.setCancelHandler { _ = close(descriptor) }
            sources.append(source)
            source.resume()
        }
    }

    private func schedule(reopen: Bool = false, delay: Double? = nil) {
        guard !stopped else { return }
        needsReopen = needsReopen || reopen
        pending?.cancel()
        let item = DispatchWorkItem { [self] in
            guard !stopped else { return }
            let reopenNow = needsReopen
            needsReopen = false
            if reopenNow { reopenSources() }
            loadAndYield()
        }
        pending = item
        queue.asyncAfter(deadline: .now() + (delay ?? debounceSeconds), execute: item)
    }

    private func scheduleRetry(reopen: Bool = false) {
        schedule(reopen: reopen, delay: retryBackoff.nextDelay())
    }

    private func loadAndYield() {
        guard !stopped else { return }
        do {
            let loaded = try repository.loadContents()
            retryBackoff.reset()
            if loaded != last {
                last = loaded
                continuation.yield(loaded)
            }
        } catch RepositoryError.lockUnavailable {
            scheduleRetry()
        } catch RepositoryError.recoveryRequired {
            scheduleRetry()
        } catch {
            reportError(String(describing: error))
            scheduleRetry()
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
