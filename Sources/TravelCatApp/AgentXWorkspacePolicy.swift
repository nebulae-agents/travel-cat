import Foundation
import AgentXAppSDK

enum AgentXWorkspacePolicy {
    static let prefix = "apps/workbench/workspace/"
    static func validate(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix(prefix), parts.count >= 4,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains(where: { $0.isNewline || $0 == "\0" }) }) else {
            throw WorkbenchFailure("工作目录必须位于当前应用的 workspace 子目录内。")
        }
    }
    static func resolve(_ path: String, root: URL) throws -> URL {
        try validate(path)
        let grants = [AppFileGrant(appID: "workbench", relativePath: path, access: .readWrite)]
        // Validates ancestors and the granted tree, including symlinks/hardlinks.
        _ = try AppSandboxProfile.generate(root: root, appID: "workbench", grants: grants)
        let url = root.appendingPathComponent(path)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
            throw WorkbenchFailure("工作目录不存在。")
        }
        return url
    }
    static func relativeSelection(_ selected: URL, root: URL) throws -> String {
        let base = root.path + "/"
        guard selected.path.hasPrefix(base) else { throw WorkbenchFailure("请选择当前应用 workspace 内的子目录。") }
        let relative = String(selected.path.dropFirst(base.count))
        _ = try resolve(relative, root: root)
        return relative
    }
}

@MainActor
extension AgentWorkbenchModel {
    func nativeConfiguration(instance: WorkbenchInstance, requireModel: Bool = true) throws -> NativeRuntimeConfiguration {
        guard var configuration = instance.native else { throw WorkbenchFailure("原生实例配置无效。") }
        if let managedRoot {
            guard configuration.workspaceIsRelative == true else { throw WorkbenchFailure("旧绝对目录授权不可复用，请为此应用重新选择工作目录。") }
            configuration.workspace = try AgentXWorkspacePolicy.resolve(configuration.workspace, root: managedRoot).path
            configuration.workspaceIsRelative = nil
        } else if configuration.workspaceIsRelative == true { throw WorkbenchFailure("缺少应用根目录，无法解析相对授权。") }
        try configuration.validate(requireModel: requireModel)
        return configuration
    }
}
