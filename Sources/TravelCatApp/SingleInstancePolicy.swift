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
    @MainActor private static var applicationLocks: [SingleInstanceLock] = []

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
            .filter { $0.bundleIdentifier.map(ownershipIdentifier) == ownershipIdentifier(expectedBundleID) }
            .map(\.processIdentifier)
            .min()

        guard let existingPID else {
            return .primary
        }
        return .secondary(existingPID: existingPID)
    }

    static func ownershipIdentifier(_ bundleIdentifier: String) -> String {
        let family = "com.nebulae.travelcat"
        return bundleIdentifier == family || bundleIdentifier.hasPrefix(family + ".") ? family : bundleIdentifier
    }

    @MainActor
    static func claimApplicationOwnership() -> Bool {
        if !applicationLocks.isEmpty { return true }
        guard let identifier = Bundle.main.bundleIdentifier,
              let paths = lockFileURLs(bundleIdentifier: identifier) else {
            rejectSecondaryInstance(expectedBundleID: Bundle.main.bundleIdentifier)
            return false
        }
        var acquired: [SingleInstanceLock] = []
        for path in paths {
            guard let lock = SingleInstanceLock.acquire(at: path) else {
                rejectSecondaryInstance(expectedBundleID: identifier)
                return false
            }
            acquired.append(lock)
        }
        applicationLocks = acquired
        return true
    }

    static func lockFileURLs(bundleIdentifier: String) -> [URL]? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        guard !bundleIdentifier.isEmpty, bundleIdentifier.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        let identity = ownershipIdentifier(bundleIdentifier)
        // Stable across bundle copies and launchers with different TMPDIR values.
        let shared = URL(fileURLWithPath: "/private/tmp/\(identity).user-\(geteuid()).desktop.lock")
        // Retain the previous lock during upgrades so an older installed app also blocks a duplicate.
        let legacy = FileManager.default.temporaryDirectory.appendingPathComponent("\(identity).instance.lock")
        return [shared, legacy]
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
