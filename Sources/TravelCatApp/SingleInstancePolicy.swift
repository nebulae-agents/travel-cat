import AppKit
import Darwin
import Foundation

final class SingleInstanceLock {
    private let fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        Darwin.close(fileDescriptor)
    }

    static func acquire(at url: URL) -> SingleInstanceLock? {
        let fileDescriptor = Darwin.open(
            url.path,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC,
            mode_t(0o600)
        )
        guard fileDescriptor >= 0 else {
            return nil
        }

        var status = stat()
        guard fstat(fileDescriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_nlink == 1,
              status.st_uid == geteuid(),
              status.st_mode & mode_t(0o777) == mode_t(0o600)
        else {
            Darwin.close(fileDescriptor)
            return nil
        }

        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fileDescriptor)
            return nil
        }

        return SingleInstanceLock(fileDescriptor: fileDescriptor)
    }
}

struct RunningApplicationIdentity: Equatable, Sendable {
    let processIdentifier: Int32
    let bundleIdentifier: String?
}

enum SingleInstanceDecision: Equatable, Sendable {
    case primary
    case secondary(existingPID: Int32?)
}

enum SingleInstancePolicy {
    @MainActor private static var applicationLock: SingleInstanceLock?

    static func decision(
        currentPID: Int32,
        expectedBundleID: String?,
        running: [RunningApplicationIdentity]
    ) -> SingleInstanceDecision {
        guard let expectedBundleID else {
            return .secondary(existingPID: nil)
        }

        let existingPID = running
            .lazy
            .filter { $0.processIdentifier != currentPID }
            .filter { $0.bundleIdentifier == expectedBundleID }
            .map(\.processIdentifier)
            .min()

        guard let existingPID else {
            return .primary
        }
        return .secondary(existingPID: existingPID)
    }

    @MainActor
    static func claimApplicationOwnership() -> Bool {
        if applicationLock != nil {
            return true
        }

        guard let bundleIdentifier = Bundle.main.bundleIdentifier,
              let lockURL = lockFileURL(bundleIdentifier: bundleIdentifier),
              let lock = SingleInstanceLock.acquire(at: lockURL)
        else {
            rejectSecondaryInstance(expectedBundleID: Bundle.main.bundleIdentifier)
            return false
        }
        applicationLock = lock
        return true
    }

    private static func lockFileURL(bundleIdentifier: String) -> URL? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        guard !bundleIdentifier.isEmpty,
              bundleIdentifier.unicodeScalars.allSatisfy(allowed.contains)
        else {
            return nil
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("\(bundleIdentifier).instance.lock", isDirectory: false)
    }

    @MainActor
    private static func rejectSecondaryInstance(expectedBundleID: String?) {
        let workspace = NSWorkspace.shared
        let runningApplications = workspace.runningApplications
        let decision = decision(
            currentPID: ProcessInfo.processInfo.processIdentifier,
            expectedBundleID: Bundle.main.bundleIdentifier,
            running: runningApplications.map {
                RunningApplicationIdentity(
                    processIdentifier: $0.processIdentifier,
                    bundleIdentifier: $0.bundleIdentifier
                )
            }
        )

        switch decision {
        case .primary:
            break
        case let .secondary(existingPID):
            if let existingPID,
               let existingApplication = runningApplications.first(where: {
                   $0.processIdentifier == existingPID
               }) {
                existingApplication.activate(options: .activateAllWindows)
            }
        }
        NSApplication.shared.terminate(nil)
    }
}
