import Foundation

struct JourneyTestCodexInstallation: Sendable {
    enum DiscoveryError: Error { case unavailable }
    let executableURL: URL
    let searchPath: String

    static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        commonDirectories: [URL] = [URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")]
    ) throws -> Self {
        guard isPlainFileURL(home) else { throw DiscoveryError.unavailable }
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":")
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        return try resolve(
            searchDirectories: pathDirectories + commonDirectories,
            nvmRoot: home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        )
    }

    static func resolve(searchDirectories: [URL], nvmRoot: URL?) throws -> Self {
        var directories = searchDirectories
        if let nvmRoot, isPlainFileURL(nvmRoot),
           let versions = try? FileManager.default.contentsOfDirectory(
               at: nvmRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
           ) {
            directories += versions
                .filter { $0.lastPathComponent.range(of: #"^v[0-9]+(\.[0-9]+){1,2}$"#, options: .regularExpression) != nil }
                .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
                .prefix(50)
                .map { $0.appendingPathComponent("bin", isDirectory: true) }
        }
        for directory in directories where isPlainFileURL(directory) {
            let executable = directory.appendingPathComponent("codex")
            guard let header = executableHeader(executable) else { continue }
            if !isNative(header) {
                guard String(decoding: header, as: UTF8.self).hasPrefix("#!/usr/bin/env node\n"),
                      let nodeHeader = executableHeader(directory.appendingPathComponent("node")),
                      isNative(nodeHeader) else { continue }
            }
            return Self(executableURL: executable, searchPath: directory.path + ":/usr/bin:/bin")
        }
        throw DiscoveryError.unavailable
    }

    private static func isPlainFileURL(_ url: URL) -> Bool {
        url.isFileURL && url.baseURL == nil && url.host == nil && url.query == nil
            && url.fragment == nil && url.path.hasPrefix("/")
    }

    private static func executableHeader(_ url: URL) -> Data? {
        let resolved = url.resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: resolved.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let handle = try? FileHandle(forReadingFrom: resolved) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: 64)
    }

    private static func isNative(_ data: Data) -> Bool {
        let magic = Array(data.prefix(4))
        let machoHeaders: [[UInt8]] = [
            [0xcf, 0xfa, 0xed, 0xfe], [0xfe, 0xed, 0xfa, 0xcf],
            [0xce, 0xfa, 0xed, 0xfe], [0xfe, 0xed, 0xfa, 0xce],
            [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca],
            [0xca, 0xfe, 0xba, 0xbf], [0xbf, 0xba, 0xfe, 0xca],
        ]
        return machoHeaders.contains(magic)
    }
}
