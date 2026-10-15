# CI 构建缓存与并发

`Source checks` 保留 `push`、`pull_request` 和 `workflow_dispatch`，使用 macOS 15、Xcode 26.2、只读仓库权限。Python、上传工具、插件、技能、代理、UTC 完整 Swift 回归、上海时区提示测试和公开上传审计仍逐项执行；缓存命中不会跳过任何检查。没有路径过滤。

## 并发规则

同一工作流、事件类型和 ref 的开发分支新运行会取消旧运行，包括旧的待运行任务。`push`、PR 和手动触发各自使用独立分组，因此一次推送触发的 push 与 PR 检查可以同时保留。

`main` 和 tag 的分组额外包含 `github.run_id`，且不取消运行，确保每次提交或手动触发都保留检查。仅设置 `cancel-in-progress: false` 仍可能让同组的新待运行任务替换旧待运行任务，因此这些 ref 使用每次运行独有的分组。

## 检出时间与增量编译

重新检出会改变源文件的修改时间，即使文件内容相同，SwiftPM 的构建数据库仍可能将其判为需要重新编译。工作流在校验工具链之后、准备和恢复缓存之前，将 Git 跟踪的 `Package.swift` 以及 `Sources/`、`Tests/` 下的 `.swift` 文件修改时间统一设为各文件最后一次 Git 提交的 Unix 秒数。完整检出历史用于取得这些时间；文件缺失、路径越界、符号链接、非普通文件或提交时间缺失、无效都会让此步骤失败。

该步骤保留文件内容和访问时间，不调整资源、图片、其他夹具或旅行数据的时间。技能脚本独立的临时模块缓存设置保持原样。同一缓存键的输入内容和提交时间稳定时，这可消除重新检出时间引起的重复编译；整体提速仍需当前提交的远端冷、暖缓存运行核实。

## 缓存范围与失效

缓存路径来自 `Scripts/travel-cat-swift.sh scratch-path` 的实际输出。CI 先通过 `GITHUB_ENV` 将根目录设为 `$RUNNER_TEMP/travel-cat-swift`，由包装脚本创建、校验当前用户拥有且权限为 0700 的项目构建目录，后续 Swift 命令使用同一目录。

缓存包含该目录中的 SwiftPM 编译产物、测试二进制及资源副本、构建数据库和模块缓存。只缓存这一项目构建目录，不缓存 checkout、`.local/`、旅行数据、诊断裁片、测试结果或其他私人目录；技能脚本独立的临时模块缓存设置保持原样。

精确键为：

```text
runner.os-runner.arch-travel-cat-swiftpm-v2-toolchain_sha256-inputs_sha256
```

`toolchain_sha256` 取以下命令原始输出的 SHA-256：`swift --version`、`xcodebuild -version`、`xcrun --sdk macosx --show-sdk-version` 和 `sw_vers -productVersion`。`inputs_sha256` 使用 `hashFiles` 覆盖 `Package.swift`、存在时的 `Package.resolved`、`Scripts/travel-cat-swift.sh`、`Sources/**` 和 `Tests/**`，包括正式资源和测试夹具。操作系统、架构、工具链或这些输入变化都会生成新键。

缓存键版本由 `v1` 升为 `v2`，避免恢复时间归一化之前保存的构建数据库。使用固定到 v6.1.0 提交的官方 `actions/cache`，不设置 `restore-keys`。缓存未命中时照常完整构建；命中时仍执行完整回归和所有契约、审计。这一保守范围减少不同源码或资源复用旧产物的机会，也意味着源码或测试修改会重新构建。

## 验证边界

CI 三处仍明确清除真实提供方、原生验收、地标与计时相关启用变量，保持离线策略。诊断产物仍只保留合成日期、邮票和公共京都地名裁片三天，排除完整画面、姓名、地址和正文。

测量时应对同一提交分别记录缓存未命中与命中的远端耗时，核对缓存保存、恢复日志和各检查步骤，不能预先保证提速幅度。并发规则另以开发分支连续运行、main 和 tag 独立保留的实际记录核对。最终结论以当前提交的 GitHub Checks 为准；本机工作流语法和契约检查不能代替远端证据。

行为依据：[GitHub 并发文档](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)、[官方 actions/cache](https://github.com/actions/cache)。
