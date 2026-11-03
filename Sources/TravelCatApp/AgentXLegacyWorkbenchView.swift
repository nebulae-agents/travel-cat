import SwiftUI

/// An imported history is inspectable without constructing a runtime or writing a snapshot.
struct AgentXLegacyWorkbenchView: View {
    let root: URL
    @State private var snapshot: WorkbenchSnapshot?
    @State private var failure: String?
    @State private var expandedTaskID: UUID?
    @State private var visibleMessageCount = 50
    @MainActor
    static func readSnapshot(root: URL) throws -> WorkbenchSnapshot {
        let key: Data
        if try EncryptedWorkbenchStorage.hasSealedFile(root: root) {
            let credentials = KeychainTravelServiceCredentialStore(service: "com.nebulae.travelcat.agent-content")
            guard let stored = try credentials.read(id: "workbench-content-v1"),
                  let decoded = Data(base64Encoded: stored), decoded.count == 32 else {
                throw WorkbenchFailure("原工作台密钥缺失，请恢复原钥匙串；源数据未修改。")
            }
            key = decoded
        } else { key = Data(repeating: 0, count: 32) }
        guard let bytes = try EncryptedWorkbenchStorage(root: root, keyData: key).loadReadOnly() else { return WorkbenchSnapshot() }
        return try JSONDecoder().decode(WorkbenchSnapshot.self, from: bytes)
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text("已导入工作台 · 只读历史").font(.title.bold())
                Text("原文件已保留。旧实例的外部 workspace、主机和执行配置尚未重新绑定到相对授权，当前禁止运行；native-runtime 运行目录留在原处，未复制、未恢复。旧外部任务当前状态未知；以下记录仅供核对。")
                if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
                if let snapshot {
                    ForEach(snapshot.instances) { instance in
                        GroupBox(instance.name) {
                            VStack(alignment: .leading) {
                                if let native = instance.native {
                                    Text("外部 workspace：\(native.workspace)")
                                    Text("执行器：\(native.executable)")
                                }
                                if !instance.host.isEmpty { Text("远程主机：\(instance.host)") }
                                if !instance.dockerContext.isEmpty { Text("Docker context：\(instance.dockerContext)") }
                                Text("需要在新的受控实例中明确选择应用内 workspace 或 shared 授权；本次未扩大任何授权。")
                            }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                    }
                    Text("会话默认折叠。展开后显示最近 50 条消息，可继续加载更早记录。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(snapshot.tasks) { task in
                        GroupBox {
                            DisclosureGroup(isExpanded: Binding(
                                get: { expandedTaskID == task.id },
                                set: { expanded in
                                    if expanded {
                                        visibleMessageCount = 50
                                        expandedTaskID = task.id
                                    } else if expandedTaskID == task.id {
                                        expandedTaskID = nil
                                    }
                                }
                            )) {
                                // Construct message views only for the currently expanded session.
                                if expandedTaskID == task.id {
                                    let count = min(visibleMessageCount, task.messages.count)
                                    LazyVStack(alignment: .leading, spacing: 10) {
                                        Text("来源实例：\(snapshot.instances.first(where: { $0.id == task.instanceID })?.name ?? task.instanceID.uuidString)")
                                            .font(.caption).textSelection(.enabled)
                                        Text("历史状态：\(task.status.rawValue)（不是当前运行证明）").font(.caption)
                                        if task.messages.isEmpty {
                                            Text("此会话没有已保存的消息。").foregroundStyle(.secondary)
                                        } else {
                                            Text("显示最近 \(count) / \(task.messages.count) 条消息")
                                                .font(.caption).foregroundStyle(.secondary)
                                            if count < task.messages.count {
                                                Button("加载更早 50 条") {
                                                    visibleMessageCount = count + min(50, task.messages.count - count)
                                                }
                                            }
                                            ForEach(task.messages.suffix(count)) { message in
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(message.role).font(.caption).foregroundStyle(.secondary)
                                                    Text(message.text).textSelection(.enabled)
                                                }
                                            }
                                        }
                                    }.padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(task.displayTitle).font(.headline)
                                    Text("\(task.messages.count) 条消息 · 历史状态：\(task.status.rawValue)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if snapshot.tasks.isEmpty { Text("没有已保存的历史对话。") }
                } else if failure == nil { ProgressView("正在只读打开历史…") }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.task {
            do {
                guard FileManager.default.fileExists(atPath: root.path) else {
                    throw WorkbenchFailure("旧工作台导入尚未完成，原记录仍保留在旧目录。请先处理管理平台显示的迁移错误，再正常退出重试。")
                }
                let key: Data
                if try EncryptedWorkbenchStorage.hasSealedFile(root: root) {
                    let credentials = AgentWorkbenchCredentialStores.system().content
                    guard let stored = try await credentials.read(id: "workbench-content-v1"),
                          let decoded = Data(base64Encoded: stored), decoded.count == 32 else {
                        throw WorkbenchFailure("原对话密钥缺失，请恢复原钥匙串；密文未修改。")
                    }
                    key = decoded
                } else { key = Data(repeating: 0, count: 32) }
                if let bytes = try EncryptedWorkbenchStorage(root: root, keyData: key).loadReadOnly() {
                    snapshot = try JSONDecoder().decode(WorkbenchSnapshot.self, from: bytes)
                } else { snapshot = WorkbenchSnapshot() }
            } catch { failure = error.localizedDescription }
        }
    }
}
