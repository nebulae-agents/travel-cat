# Travel Cat

一个拥有自有桌面小猫、旅行记录与明信片相册的 macOS 应用。

**状态：Apache-2.0 开源开发版，尚未公证发行。** 本仓库维护独立应用、默认宠物素材及迁移期兼容代码。桌面宠物已不依赖 Codex 窗口；生产内置调度与可切换 Runtime 仍在建设中。源码回归及隔离构建不代替真实账户下的安装、系统权限和完整旅程验收。

## 当前可用与边界

- 自有桌面小猫、准备行李、外出空屋、隐藏与位置记忆。
- 自有右键菜单、跟随纸条、已有旅行状态与相册。
- 隔离的紧凑旅程测试使用固定剧情和已有图片，不调用模型。
- 正式自动旅行、图片任务内置调度、Runtime 配置与 ACP 接入尚未完成；不能把桌面独立等同于完整生成流程独立。

## 使用候选应用

新的候选包只有 `Travel Cat.app` 和说明/许可文件，不附带 Codex 插件或宠物安装脚本。默认黑猫已内置，不需要在 Codex 中开启宠物，也不需要为自有右键菜单申请跨应用输入监控权限。

先阅读[安装与使用](docs/installation.md)。从菜单栏爪印可打开状态、相册和设置；手动隐藏后使用“显示桌面小猫”恢复。已有 Codex 宠物不会被自动关闭或修改，可自行收起以免重复显示。

当前构建为临时签名的开发候选，尚未 Apple 公证。不要覆盖已有安装、移动旧相册、重置系统权限或关闭 Gatekeeper。未验证的迁移步骤必须单独完成。

## 本地部署与源码发布

`Deploy Local.command` 已改为从干净、已提交源码构建并仅安装应用，保留签名校验、备份与失败恢复。新配置为 v2，只询问应用目录和相册目录，不需要 Codex 用户目录；旧 v1 配置可原样复用，重新生成时先备份再升级。新安装记录也为仅应用的 v2，不会安装或修改 Codex 宠物、插件。详见[本地部署说明](docs/local-deployment.md)。隔离事务测试不代表本轮已实际安装，未提交源码仍会被入口拒绝。不要删除现有配置、备份、插件或 heartbeat；停止旧调度需要单独确认。

`Publish to GitHub.command` 只审核并推送明确提交，不安装应用，也不会自动提交工作区修改。

### 第一次上传 GitHub

先安装 [GitHub CLI](https://cli.github.com/)，然后在终端登录：

```sh
gh auth login --hostname github.com
```

发布入口不会自动安装工具或嵌入凭据。首次使用需要填写 `OWNER/REPO`、选择可见性（默认 private）并确认摘要；已有 `origin` 时会核对实际仓库。它只推送显示的提交和分支，不强制覆盖，不推送全部分支或标签。命令行为参考 [GitHub 创建仓库说明](https://cli.github.com/manual/gh_repo_create)与[登录检查说明](https://cli.github.com/manual/gh_auth_status)。

上传前同时检查当前源码和待推送历史中的已知私有路径；即使本地配置后来删除，历史仍可能阻止上传。这不是完整历史内容的秘密扫描保证，请自行复核拟公开内容。工作区未提交、远端异常、历史不完整，或存在 Git replace/graft 历史替换设置时会停止。若远端已创建但推送失败，保留实际状态供检查，不自动删除远端。

本仓库包含 macOS CI 配置，但没有因此宣称远端 CI 已运行或通过；首次推送后应在 GitHub Actions 查看真实结果。

## 产品组成

- **兼容插件源码**：保留旧旅行工作流，未随新的 App-only 候选分发，也不会自动停用已有安装。
- **macOS 独立桌面应用**：自有小猫、设置、旅行纸条、最新明信片、旅行册和隔离测试。
- **默认黑猫素材**：作者自定义的 Cute Black Cat 图集与角色参考图。

桌面窗口、右键菜单与纸条锚点由 Travel Cat 自己管理，不定位或操作 Codex 窗口。兼容模块仍保留在源码中，不代表应用会启动旧监听器。

通用版本支持导入兼容宠物、为旅程冻结角色，并在生成流程中使用该角色与参考图。源码测试通过不等于另一账户下的实际 Codex 安装和生成验收；没有参考图的自定义角色无法保证跨图一致。

## 使用条件

桌面展示、已有相册和紧凑测试需要 macOS 14 或更新版本，不要求运行 Codex 桌面应用。真实生成测试仍需要已安装并授权的 Codex CLI，会使用用户额度；通用 Runtime 和正式内置调度尚未交付。

关闭快速测试后，正式旅行和相册入口仍应可用；测试区域与真实旅行记录隔离。紧凑测试不等于真实生成服务验收。

## 开发构建

需要支持 Swift 6.2 的开发工具链、Python 3.9 或更新版本和 Git；完整测试还使用 Node.js 运行协议边界检查。当前候选构建面向 Apple Silicon（arm64）；其他架构不能视为已验收。这些是开发测试依赖，不是已打包应用的用户运行依赖。在项目目录执行：

```sh
Scripts/travel-cat-swift.sh test
Scripts/package-app.sh
```

构建缓存位于项目之外。应用打包输出到 `dist/Travel Cat.app`；当前使用临时签名，不是经过 Apple 公证的公开发行包。测试完成后的 dist 是可重建输出，不应提交到源码。

不要手工直接覆盖已有生产安装；部署前先核对相册与旧调度，阅读[安装说明](docs/installation.md)与[数据路径和兼容说明](docs/portable-runtime.md)。首次启动可能需要系统确认，不应关闭系统安全保护。

### 完整候选包组装

评审完成并提交干净源码后，开发者可指定一个仓库外、尚不存在的绝对目录：

```sh
Scripts/package-project.py /absolute/new/output-directory
```

该工具先调用干净源码导出器，再在带空格的临时目录中解压、全测和构建默认应用；随后组装彼此独立的源码 ZIP 与候选 ZIP、SHA-256 文件和验证报告，并从候选 ZIP 再解压验证签名、素材字节与 App-only 布局。工具拒绝覆盖旧输出。执行会运行完整 Swift 测试与 macOS 签名工具，仅供开发者使用，不会安装到当前账户或写入旅行数据。

## 项目结构

| 目录 | 内容 |
| --- | --- |
| `Sources/TravelCore` | 旅行状态与核心模型 |
| `Sources/TravelStorage` | 持久化、校验、代理协议和调度 |
| `Sources/TravelUI` | 明信片、旅行册及资源 |
| `Sources/TravelCatApp` | macOS 自有桌面应用 |
| `Sources/TravelCatCLI` | 签名包内的命令行辅助程序 |
| `Plugins/travel-cat` | 可移植 Codex 插件、签名应用发现入口与独立协议引用 |
| `Assets/CharacterReference` | 默认黑猫生成参考素材 |
| `Tests`、`Fixtures` | 回归测试与夹具 |
| `Scripts`、`packaging` | 构建、安装和安全校验 |

## 数据与隐私

旅行数据留在用户本地，不能随项目归档。调用生成能力时，相关叙事、角色参考图和上下文可能交给生成服务处理；本地存储不等于生成过程离线。

不要提交 TravelPetData、账户配置、凭据、个人日志或完整本地 Git 历史。正式资源和测试夹具不能仅因扩展名像日志而删除。发布前运行：

```sh
Scripts/audit-project-upload.sh
Scripts/verify-travel-cat-plugin.sh
```

## 许可证与发布

代码、文档和自有项目素材按 [Apache License 2.0](LICENSE) 开源，版权及归属见 [NOTICE](NOTICE)。第三方字体仍按其原有 [SIL Open Font License 1.1](Sources/TravelUI/Resources/Fonts/OFL.txt) 分发，详见[第三方声明](Sources/TravelUI/Resources/Fonts/THIRD_PARTY_NOTICES.md)，不受 Apache-2.0 替代。Travel Cat 是独立项目，并非 OpenAI 官方产品。

发布前必须完成干净环境安装、完整旅程与原生菜单验收，并附校验摘要和已知限制。不会把仅完成构建的归档标记为正式可用版本。
