import Darwin
import Dispatch
import Foundation
import SwiftUI

/// LaunchServices may reopen a temporary acceptance bundle without its shell environment.
enum AgentXAcceptanceLaunch {
    static let bundleIdentifier = "local.agentx.pi-run.acceptance"

    #if DEBUG
    static func recordMergedRuns(_ runs: [AgentXRun]) {
        guard Bundle.main.bundleIdentifier == bundleIdentifier else { return }
        for run in runs {
            if let line = receiptLine(for: run) { try? FileHandle.standardError.write(contentsOf: line) }
        }
    }

    static func receiptLine(for run: AgentXRun) -> Data? {
        guard let revision = run.revision else { return nil }
        let evidence = run.stopEvidence.flatMap { ["pending", "confirmedExited", "unverified"].contains($0) ? $0 : nil }
        let receipt: [String: Any] = [
            "pid": getpid(), "runID": run.id, "revision": revision, "status": run.status.rawValue,
            "stopEvidence": evidence as Any? ?? NSNull(), "displayedStatus": run.displayedStatus
        ]
        guard var bytes = try? JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]) else { return nil }
        bytes.append(0x0A)
        return bytes
    }
    #endif

    static func permits(bundleID: String?, environment: [String: String]) -> Bool {
        guard bundleID == bundleIdentifier else { return true }
        let prefix = "/private/tmp/agentxd-pi-e2e-"
        guard let root = environment["AGENTX_ROOT"], root.hasPrefix(prefix), root.hasSuffix("/root"),
              !root.contains("\0"), let host = environment["AGENTX_HOST_DIRECTORY"] else { return false }
        let workspace = String(root.dropLast("/root".count))
        let name = workspace.dropFirst(prefix.count)
        guard !name.isEmpty, !name.contains("/"), host == workspace + "/host" else { return false }

        func isOwnDirectory(_ path: String, mayBeMissing: Bool = false) -> Bool {
            var info = stat()
            if lstat(path, &info) != 0 { return mayBeMissing && errno == ENOENT }
            return info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
        }
        guard isOwnDirectory(workspace), isOwnDirectory(root), isOwnDirectory(host, mayBeMissing: true) else { return false }
        // The host's locator and pending operations can select other data roots after startup.
        for filename in ["location.json", "pending-migration.json", "app-lifecycle-request.json"] {
            var info = stat()
            guard lstat(host + "/" + filename, &info) == -1, errno == ENOENT else { return false }
        }
        let marker = URL(fileURLWithPath: root).appendingPathComponent(".agentxd-pilot.json")
        do {
            let pilot = try JSONDecoder().decode(AgentXPilot.self, from: AgentXLocalAppZIP.read(marker))
            try AgentXPackageFiles.validateID(pilot.appID)
            return pilot.root == root && pilot.pi != nil && !["blackcat", "workbench"].contains(pilot.appID)
        } catch { return false }
    }
}

/// Decide before SwiftUI constructs the delegate (which owns credentials, diagnostics
/// and normal application startup). Rejected probe requests never fall through.
@main
@MainActor
enum TravelCatEntryPoint {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains(where: { $0.hasPrefix("--agentx-audit") }) {
            AgentXAuditHelper.dispatch(arguments: arguments)
        }
        guard AgentXAcceptanceLaunch.permits(bundleID: Bundle.main.bundleIdentifier, environment: ProcessInfo.processInfo.environment) else {
            FileHandle.standardError.write(Data("AgentX Pi acceptance requires its isolated environment.\n".utf8))
            exit(78)
        }
        do {
            if try PackagedTravelAcceptance.isRequested(arguments: Array(CommandLine.arguments.dropFirst())) {
                Task {
                    do {
                        let result = try await PackagedTravelAcceptance.run()
                        let data = try JSONEncoder().encode(result)
                        print(String(decoding: data, as: UTF8.self))
                        exit(EXIT_SUCCESS)
                    } catch {
                        print(PackagedTravelAcceptance.failureJSON(error))
                        exit(EXIT_FAILURE)
                    }
                }
                dispatchMain()
            }
        } catch {
            print(PackagedTravelAcceptance.failureJSON(error))
            exit(64)
        }
        TravelCatApp.main()
    }
}
