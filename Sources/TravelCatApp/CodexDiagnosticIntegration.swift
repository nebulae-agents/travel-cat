import Foundation

extension CodexGenerationDiagnosticStore {
    static func applicationStore() -> CodexGenerationDiagnosticStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return CodexGenerationDiagnosticStore(fileURL: support.appendingPathComponent("TravelCat/diagnostics/codex-latest.json"))
    }
}
