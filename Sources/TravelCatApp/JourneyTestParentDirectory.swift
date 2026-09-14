import Foundation
import TravelStorage

enum JourneyTestParentDirectory {
    static func prepare(at parent: URL, productionRoot: URL) throws {
        guard parent.isFileURL, productionRoot.isFileURL,
              parent.baseURL == nil, productionRoot.baseURL == nil,
              parent.host == nil, productionRoot.host == nil,
              parent.query == nil, productionRoot.query == nil,
              parent.fragment == nil, productionRoot.fragment == nil,
              parent.lastPathComponent == "JourneyTests" else {
            throw JourneyTestSession.SessionError.invalidParent
        }
        // Resolve existing ancestors before creating anything. Case folding is deliberately
        // conservative on case-sensitive volumes; the session performs inode validation too.
        let candidate = parent.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        let production = productionRoot.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        func contains(_ ancestor: String, _ child: String) -> Bool {
            child == ancestor || child.hasPrefix(ancestor == "/" ? "/" : ancestor + "/")
        }
        guard !contains(production, candidate), !contains(candidate, production) else {
            throw JourneyTestSession.SessionError.productionOverlap
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}
