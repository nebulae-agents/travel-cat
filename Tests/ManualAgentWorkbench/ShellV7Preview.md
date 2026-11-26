# AgentX shell v7 隔离原生预览

先完成 `Scripts/travel-cat-swift.sh test --filter AgentX`，确认没有其他 Swift 进程再启动：

```sh
AGENTX_SHELL_V7_SECONDS=900 Scripts/preview-agentx-shell-v7.sh
```

窗口：`AgentX Shell v7 — 隔离预览`。关闭窗口或超时即退出；结束时请求取消预览任务，移除本预览生成的临时 root。入口位于 `Tests/ManualAgentWorkbench/ShellV7Preview.swift`，使用独立 `NSApplication.run()`，不运行正式应用入口。脚本先运行壳测试，再链接 Xcode Debug testable 生产对象；需要本机 Xcode Swift 工具链。

数据边界：`/private/tmp/AppShell-<UUID>`，内存 `PreviewCredentials`，禁用自动模型目录刷新。两个应用、成员和场景均为明确标记的测试数据；响应为 20 秒后返回的本地模拟文本，真实控制器负责草稿、运行、取消、发布和导航。预置运行使用本地模拟响应，不自动请求模型目录，也不读取钥匙串。手动模型目录刷新仍属于控制器现有能力；本预览配置只指向本机模拟地址，不代表任意配置下都离线。生成修改入口会接收模拟文本，不能据此声称真实模型建议解析验收通过。

验收顺序：

1. 核对轻顶栏、居中正文、三个选项；点击选择后只填输入，修改再发送。
2. 运行期间核对成员回应状态；点击状态打开任务详情；单任务停止并等待取消终态。
3. ⌘, 进入设置，修改场景规则，等待草稿保存；查看差异，确认发布后返回，核对位置和输入保留。
4. ⌘K 搜应用和模块/成员/运行；⌘1/⌘2 切换；设置分别记忆；平台四项和次级管理入口可达且返回原位置。
5. 发起任务后在切换器分别验证两秒长按停止和点击后确认停止；无任务时没有停止按钮。
6. 深浅主题、960×640 与1280×820各检查；Tab、⌘K、⌘P、⌘,、⌘1–9、⌘Return、输入撤销可达。图标44pt且有辅助功能标签。

正式数据前后清单由父任务比对；这里的临时预览成功不代表安装版或正式模型验收。

## 预览启动与存活证据

旧的 XCTest 交互入口已删除。它虽然创建窗口，但只等待异步测试完成，主线程采样为 `XCTWaiter → CFRunLoop`，没有 AppKit 事件派发循环；测试通过不能证明窗口可以操作。不要再使用复制 XCTest runner 的 `/private/tmp/AgentXShellV7Preview.app`。

新脚本每次生成独立的 `/private/tmp/agentx-shell-v7.XXXXXX/AgentXShellV7Preview.app`，不安装进 Applications。正式 UI 和控制器来自当前构建对象，进程不链接 XCTest。标准错误立即输出 `SHELL_V7_PREVIEW_READY`（PID、临时 root、`appRunning=true`），前 3 秒及此后每 30 秒输出 `SHELL_V7_HEARTBEAT`，退出输出 `SHELL_V7_PREVIEW_EXIT`。可用 `AGENTX_SHELL_V7_SECONDS=8` 做有界启动/退出检查。

心跳只证明 AppKit 主循环仍在运行，不代替人工输入、点击、快捷键验收。用户手工操作；未经明确授权不使用任何自动界面操作。
