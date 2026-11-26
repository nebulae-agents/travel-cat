# AgentX shell v7 隔离原生预览

先完成 `Scripts/travel-cat-swift.sh test --filter AgentX`，确认没有其他 Swift 进程再启动：

```sh
AGENTX_SHELL_V7_PREVIEW=1 AGENTX_SHELL_V7_SECONDS=900 Scripts/travel-cat-swift.sh test --skip-build --filter AgentXAppShellTests/testShellV7InteractivePreview
```

窗口：`AgentX Shell v7 — 隔离预览`。关闭窗口或超时即退出测试；结束时请求取消预览任务，移除本测试生成的临时 root。测试代码位于 `Tests/TravelCatAppTests/AgentXAppShellTests.swift`。

数据边界：`/private/tmp/AppShell-<UUID>`，内存 `AgentXTestCredentials`，禁用自动模型目录刷新。两个应用、成员和场景均为明确标记的测试数据；响应为 20 秒后返回的本地模拟文本，真实控制器负责草稿、运行、取消、发布和导航。没有正式模型、网络请求或钥匙串读取。生成修改入口会接收模拟文本，不能据此声称真实模型建议解析验收通过。

验收顺序：

1. 核对轻顶栏、居中正文、三个选项；点击选择后只填输入，修改再发送。
2. 运行期间核对成员回应状态；点击状态打开任务详情；单任务停止并等待取消终态。
3. ⌘, 进入设置，修改场景规则，等待草稿保存；查看差异，确认发布后返回，核对位置和输入保留。
4. ⌘K 搜应用和模块/成员/运行；⌘1/⌘2 切换；设置分别记忆；平台四项和次级管理入口可达且返回原位置。
5. 发起任务后在切换器分别验证两秒长按停止和点击后确认停止；无任务时没有停止按钮。
6. 深浅主题、960×640 与1280×820各检查；Tab、⌘K、⌘P、⌘,、⌘1–9、⌘Return、输入撤销可达。图标44pt且有辅助功能标签。

正式数据前后清单由父任务比对；这里的临时预览成功不代表安装版或正式模型验收。

## CUA 无法发现裸 XCTest 进程时

本轮提供临时独立包 `/private/tmp/AgentXShellV7Preview.app`，bundle ID `local.agentx.shell-v7.preview`。包内为本机 Xcode 的 XCTest runner，本轮已构建测试作为参数；通过 LaunchServices `open` 启动，且显式设置 `AGENTX_SHELL_V7_PREVIEW=1`、`AGENTX_SHELL_V7_SECONDS=900`。XCTest 框架路径来自本机 Xcode 的 MacOSX Developer/Library/Frameworks 与 PrivateFrameworks；`DYLD_LIBRARY_PATH` 指向该平台 Developer/usr/lib，以加载 `libXCTestSwiftSupport.dylib`。不读取正式应用数据或钥匙串。

裸 XCTest 与临时包不可同时运行。CUA 通过上述 bundle ID 或 `.app` 绝对路径选择；界面操作仅使用 CUA。临时包不安装进 Applications，也不属于发布产物。
