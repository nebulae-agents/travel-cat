import SwiftUI
import AppKit

@MainActor
struct AgentXAppConfigurationView: View {
    @ObservedObject var controller: AgentXController
    var body: some View {
        if let app = controller.currentApp {
            AgentXCard {
                Label(app.name, systemImage: "slider.horizontal.3").font(.title3.bold())
                Text(app.kind == .workbench ? "受控工作台：实例和权限在工作台内管理。" : app.kind == .blackcat ? "BlackCat：旅行设置、桌面入口与生成服务。" : app.canRunHostText ? "宿主文本应用：定义发布后由实例引用；独立前台随应用包更新。" : "此应用类型尚未接入运行框架；配置与已有文件已保留。")
                    .foregroundStyle(AgentXTheme.muted)
                HStack {
                    Button("进入前台") { controller.openApp(app.id) }.buttonStyle(.borderedProminent)
                    Button("成员与实例") { controller.page = .instances }
                }
            }
            AgentXCard {
                Label("成员与定义", systemImage: "person.2").font(.headline)
                if controller.currentInstances.isEmpty { Text("尚未配置成员。通过“成员与实例”添加本应用的 Agent。").foregroundStyle(AgentXTheme.muted) }
                ForEach(controller.currentInstances) { instance in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(instance.name)
                            Text(controller.state.definitions.first { $0.id == instance.definitionID }?.name ?? "定义缺失").font(.caption).foregroundStyle(AgentXTheme.muted)
                        }
                        Spacer()
                        Text(instance.model).font(.caption.monospaced())
                    }
                }
            }
            AgentXCard {
                Label("记录、目录与版本", systemImage: "folder").font(.headline)
                Text("apps/\(app.id)/").font(.caption.monospaced()).textSelection(.enabled)
                Text("输入与业务数据保存在此应用目录；跨应用共享通过 shared 的显式授权处理。").font(.caption).foregroundStyle(AgentXTheme.muted)
                HStack {
                    Button("运行记录") { controller.page = .runs }
                    Button("应用版本与备份") { controller.page = .settings }
                }
            }
        } else {
            Text("请先选择应用。")
            Button("所有应用") { controller.page = .apps }
        }
    }
}
