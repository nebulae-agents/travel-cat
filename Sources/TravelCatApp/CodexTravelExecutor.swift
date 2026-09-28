import Darwin
import Foundation

/// A single ephemeral CLI request. Callers supply a private temporary workspace.
@MainActor
final class CodexTravelExecutor {
    enum Failure: Error, LocalizedError, Equatable {
        case notInstalled, notLoggedIn, timedOut, generationFailed
        var errorDescription: String? {
            switch self {
            case .notInstalled: "未找到 Codex 命令行程序，请先安装 Codex。"
            case .notLoggedIn: "Codex 尚未登录或登录已失效，请先在 Codex 中登录。"
            case .timedOut: "Codex 生成超时，请稍后重试。"
            case .generationFailed: "Codex 未能完成生成，请检查连接后重试。"
            }
        }
    }

    private let executableURL: URL?
    private let timeout: TimeInterval
    private let diagnostics: @Sendable (Data) -> Void
    private var active: [UUID: Invocation] = [:]

    init(executableURL: URL? = nil, timeout: TimeInterval = 900, diagnostics: @escaping @Sendable (Data) -> Void = { _ in }) {
        self.executableURL = executableURL
        self.timeout = timeout
        self.diagnostics = diagnostics
    }

    /// Also called synchronously from applicationWillTerminate.
    func cancelAll() {
        for invocation in active.values { invocation.cancel() }
    }

    func run(prompt: String, workspace: URL, schema: URL? = nil, images: [URL] = []) async throws -> Data {
        try Task.checkCancellation()
        guard let executable = executableURL ?? Self.locateExecutable(),
              FileManager.default.isExecutableFile(atPath: executable.path) else { throw Failure.notInstalled }
        let limit = timeout
        let sink = diagnostics
        let id = UUID()
        let invocation = Invocation()
        active[id] = invocation
        defer { active[id] = nil }
        let worker = Task.detached(priority: .utility) {
            try Self.execute(executable: executable, prompt: prompt, workspace: workspace, schema: schema, images: images, timeout: limit, invocation: invocation, diagnosticsSink: sink)
        }
        return try await withTaskCancellationHandler {
            let data = try await worker.value
            try Task.checkCancellation()
            try invocation.checkCancellation()
            return data
        } onCancel: {
            invocation.cancel()
            worker.cancel()
        }
    }

    /// Finder does not inherit the user's shell or nvm PATH. Only inspect known
    /// installation directories and select a native executable, never a wrapper.
    private static func locateExecutable() -> URL? {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        var candidates: [URL] = []
        for directory in [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] {
            for app in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where app.lastPathComponent.hasPrefix("Codex") && app.pathExtension == "app" {
                candidates.append(app.appendingPathComponent("Contents/Resources/codex"))
            }
        }
        var packageRoots = [URL(fileURLWithPath: "/opt/homebrew/lib/node_modules"), URL(fileURLWithPath: "/usr/local/lib/node_modules")]
        let versions = home.appendingPathComponent(".nvm/versions/node")
        for version in ((try? manager.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            packageRoots.append(version.appendingPathComponent("lib/node_modules"))
        }
        #if arch(arm64)
        let architecture = "aarch64-apple-darwin"
        let package = "codex-darwin-arm64"
        #else
        let architecture = "x86_64-apple-darwin"
        let package = "codex-darwin-x64"
        #endif
        for root in packageRoots {
            candidates.append(root.appendingPathComponent("@openai/codex/node_modules/@openai/\(package)/vendor/\(architecture)/bin/codex"))
            candidates.append(root.appendingPathComponent("@openai/codex/node_modules/@openai/\(package)/vendor/\(architecture)/codex/codex"))
            candidates.append(root.appendingPathComponent("@openai/codex/vendor/\(architecture)/codex/codex"))
        }
        return candidates.first { url in
            guard manager.isExecutableFile(atPath: url.path), let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            guard let magic = try? handle.read(upToCount: 4) else { return false }
            return [[0xcf, 0xfa, 0xed, 0xfe], [0xfe, 0xed, 0xfa, 0xcf], [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca]].contains(Array(magic))
        }
    }

    nonisolated private static func execute(executable: URL, prompt: String, workspace: URL, schema: URL?, images: [URL], timeout: TimeInterval, invocation: Invocation, diagnosticsSink: @Sendable (Data) -> Void) throws -> Data {
        var diagnostics = Data()
        defer { diagnosticsSink(diagnostics) }
        try Task.checkCancellation()
        let result = workspace.appendingPathComponent("codex-result-\(UUID().uuidString).json")
        let resultFD = open(result.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard resultFD >= 0 else { throw Failure.generationFailed }
        close(resultFD)
        defer { try? FileManager.default.removeItem(at: result) }
        var arguments = [executable.path, "exec", "--ephemeral", "--skip-git-repo-check", "--sandbox", "workspace-write", "--ignore-user-config", "--json", "--color", "never", "-c", "sandbox_workspace_write.exclude_tmpdir_env_var=true", "-c", "sandbox_workspace_write.exclude_slash_tmp=true", "--output-last-message", result.path]
        if let schema { arguments += ["--output-schema", schema.path] }
        for image in images { arguments += ["--image", image.path] }
        arguments += ["-"]

        var input: [Int32] = [0, 0]
        var output: [Int32] = [0, 0]
        guard pipe(&input) == 0 else { throw Failure.generationFailed }
        defer { close(input[0]); close(input[1]) }
        guard pipe(&output) == 0 else { throw Failure.generationFailed }
        defer { close(output[0]); close(output[1]) }
        for descriptor in input + output { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(input[1], F_SETNOSIGPIPE, 1)
        _ = fcntl(input[1], F_SETFL, O_NONBLOCK)
        _ = fcntl(output[0], F_SETFL, O_NONBLOCK)

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw Failure.generationFailed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw Failure.generationFailed }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, output[1], STDERR_FILENO) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, workspace.path) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else { throw Failure.generationFailed }
        let argv = arguments.map { strdup($0) } + [nil]
        // Keep login discovery, but never inherit a repository writable-root override.
        let allowedEnvironment = Set(["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "CODEX_HOME", "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "all_proxy", "no_proxy", "SSL_CERT_FILE", "SSL_CERT_DIR", "CODEX_SANDBOX_NETWORK_DISABLED"])
        let environment = ProcessInfo.processInfo.environment.filter { allowedEnvironment.contains($0.key) }
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in argv + envp { free(pointer) } }
        try invocation.spawn { pid in
            argv.withUnsafeBufferPointer { args in
                envp.withUnsafeBufferPointer { env in
                    posix_spawn(pid, executable.path, &actions, &attributes, args.baseAddress!, env.baseAddress!)
                }
            }
        }
        close(input[0]); input[0] = -1
        close(output[1]); output[1] = -1
        defer { invocation.stop() }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        let bytes = Array(prompt.utf8)
        var written = 0
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.timedOut }
            if input[1] >= 0 {
                if written < bytes.count {
                    let count = bytes.withUnsafeBytes { write(input[1], $0.baseAddress!.advanced(by: written), min(bytes.count - written, 8192)) }
                    if count > 0 { written += count }
                    else if count < 0 && errno != EAGAIN && errno != EINTR { close(input[1]); input[1] = -1 }
                }
                if written == bytes.count && input[1] >= 0 { close(input[1]); input[1] = -1 }
            }
            // Bound each drain cycle so an output flood cannot starve cancellation.
            for _ in 0..<8 {
                let count = read(output[0], &buffer, buffer.count)
                if count <= 0 { break }
                diagnostics.append(contentsOf: buffer.prefix(count))
                if diagnostics.count > 65536 { diagnostics.removeFirst(diagnostics.count - 65536) }
            }
            if let status = try invocation.poll() {
                guard status == 0 else {
                    let log = String(decoding: diagnostics, as: UTF8.self).lowercased()
                    if ["not logged in", "unauthorized", "authentication", "401", "please log in", "please login"].contains(where: log.contains) { throw Failure.notLoggedIn }
                    throw Failure.generationFailed
                }
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let descriptor = open(result.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Failure.generationFailed }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0, info.st_size <= 4 * 1024 * 1024 else { throw Failure.generationFailed }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: 4 * 1024 * 1024 + 1), data.count <= 4 * 1024 * 1024, !data.isEmpty else { throw Failure.generationFailed }
        return data
    }
    /// Serializes spawn, reaping and application-exit cancellation to avoid PID reuse races.
    private final class Invocation: @unchecked Sendable {
        private let lock = NSLock()
        private var pid: pid_t?
        private var cancelled = false
        private var descendants: [pid_t: ProcessIdentity] = [:]
        private var lastObservation: TimeInterval = 0

        func checkCancellation() throws {
            lock.lock(); defer { lock.unlock() }
            if cancelled { throw CancellationError() }
        }

        func spawn(_ launch: (UnsafeMutablePointer<pid_t>) -> Int32) throws {
            lock.lock(); defer { lock.unlock() }
            if cancelled { throw CancellationError() }
            var child: pid_t = 0
            guard launch(&child) == 0 else { throw Failure.generationFailed }
            pid = child
        }

        func poll() throws -> Int32? {
            lock.lock(); defer { lock.unlock() }
            if cancelled { throw CancellationError() }
            guard let child = pid else { throw Failure.generationFailed }
            if ProcessInfo.processInfo.systemUptime - lastObservation >= 0.05 {
                observeDescendants(of: child, freeze: false)
                lastObservation = ProcessInfo.processInfo.systemUptime
            }
            var status: Int32 = 0
            let waited = waitpid(child, &status, WNOHANG)
            if waited == child {
                stopDescendants(of: nil)
                kill(-child, SIGKILL)
                pid = nil
                return status
            }
            if waited < 0 && errno != EINTR { throw Failure.generationFailed }
            return nil
        }

        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            stopLocked()
        }

        func stop() {
            lock.lock(); defer { lock.unlock() }
            stopLocked()
        }

        private func stopLocked() {
            guard let child = pid else { return }
            // Freeze the live root before walking children so it cannot keep forking.
            // A zombie is harmless and remains ours until waitpid, preventing PID reuse.
            kill(child, SIGSTOP)
            stopDescendants(of: child)
            kill(-child, SIGKILL)
            var status: Int32 = 0
            while waitpid(child, &status, 0) == -1 && errno == EINTR {}
            pid = nil
        }

        private struct ProcessIdentity: Hashable {
            let pid: pid_t
            let seconds: UInt64
            let microseconds: UInt64

            static func read(_ pid: pid_t, expectedParent: pid_t? = nil) -> ProcessIdentity? {
                var info = proc_bsdinfo()
                guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
                      info.pbi_pid == UInt32(pid), info.pbi_uid == getuid(),
                      expectedParent == nil || info.pbi_ppid == UInt32(expectedParent!) else { return nil }
                return .init(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
            }

            var isCurrent: Bool { Self.read(pid) == self }

            func signal(_ signal: Int32) {
                // Never act on a cached bare PID after its original process has gone.
                if isCurrent { kill(pid, signal) }
            }
        }

        private func observeDescendants(of root: pid_t?, freeze: Bool) {
            descendants = descendants.filter { $0.value.isCurrent }
            var queue = root.map { [$0] } ?? []
            queue += descendants.values.map(\.pid)
            var visited = Set<pid_t>()
            while let parent = queue.popLast() {
                guard visited.insert(parent).inserted else { continue }
                if parent != root {
                    guard let known = descendants[parent], known.isCurrent else { continue }
                    if freeze { known.signal(SIGSTOP) }
                }
                // libproc returns a PID count; buffersize is still measured in bytes.
                let capacity = max(64, Int(proc_listchildpids(parent, nil, 0)) + 32)
                var children = [pid_t](repeating: 0, count: capacity)
                let count = proc_listchildpids(parent, &children, Int32(children.count * MemoryLayout<pid_t>.size))
                guard count > 0 else { continue }
                for child in children.prefix(min(Int(count), children.count)) where child > 0 {
                    guard let identity = ProcessIdentity.read(child, expectedParent: parent) else { continue }
                    descendants[child] = identity
                    if freeze { identity.signal(SIGSTOP) }
                    queue.append(child)
                }
            }
        }

        private func stopDescendants(of root: pid_t?) {
            // Remembered identities also cover a child that detached and was reparented
            // before the CLI exited. New process groups/sessions are not an escape hatch.
            observeDescendants(of: root, freeze: true)
            for identity in descendants.values { identity.signal(SIGKILL) }
            descendants.removeAll()
        }
    }

}
