# Agent 工作台对话与设置重构验收（2026-10-23 实施，2026-10-24 完成）

## 当前结果

对话、设置和制品入口已实现，正式应用已从 1.4.1 build 40 更新到 **build 42**，并于 **2026-10-24 完成最终实机验收**。用户手动完成 macOS 钥匙串授权后，原会话和账号恢复正常；重启后的制品版本确认、下载一致性与继续对话均已实际回读。安装文件签名和一致性再次验证通过。以下分别记录实现、自动测试、离线组件验收和正式应用实机证据。

- 正式应用：`/Users/nebulae/Applications/Travel Cat.app`，1.4.1（42）。
- 正式源码：`/Users/nebulae/Source/Codex/.worktrees/TravelCat-Public/agent-mailbox-install`，保留当前分支及既有未提交改动。
- 最终主程序 SHA-256：`329586b91e55562d48f14f1a65ecebcbc80188248c8b821a112c7511bf8e75d1`。
- 未提交、推送、发布或创建持续任务；未重置账号或旅行数据。

## 本次改动

- 新对话与历史对话进入同一主界面，侧栏集中显示对话、Agent 筛选和设置；筛选列表不会强制跳走当前会话。
- 单一输入框按新建 Agent / 既有任务独立保存草稿，发送成功只清理相同 revision，保留期间继续输入的内容。Enter 发送，Shift/Option + Enter 换行；编辑器保留输入法组合态保护。
- 用户和助手正文独立呈现；过程记录、完整会话信息、调用与审计放入详情，空 reasoning JSON 和空白助手记录不占正文，原始记录保留。重要断线、待核实与审批状态仍直接显示。
- 停止 / 恢复按会话状态显示；交接、后台命令停止、断开、审计和设置进入更多操作。审批显示完整操作详情及运行时实际提供的选项。
- 设置独立为 Agent、运行环境、数据与审计；原生账号设置和 ACP 常用 / 高级配置分开，添加流程分步呈现，保留原有连接、探测、清理证明及锁定条件。
- 新增“制品与文件”：列出已绑定任务工作目录的普通文件，文本 / HTML 源码只读查看，图片和 PDF 内嵌预览，其他格式下载。列表明确不等于全部为本轮新建；单文件不超过 4 MiB。
- “确认此版本”在重新读取并核对 SHA-256 后写入加密快照；下载保存预览字节，不自动执行或打开文件。

## 实现和复核

- 原生制品读取只使用服务端已验证、同代次连接任务的固定 workspace，不接受调用方自选根目录。父目录逐级 no-follow 打开并固定目录描述符，复用普通文件 / 链接 / 隐藏和敏感名称限制。
- 下载路径竞态先被测试复现：旧实现会把 318 字节加密快照覆盖成 5 字节制品。现以固定父目录描述符、实际 inode 祖先存储保护、临时普通文件和 renameat 替换；保存前复核目录身份。8 项制品测试通过，独立质量复核关闭该 P2。
- 实机发现空助手消息会留下空名称行；新增失败用例后，仅在显示层过滤空白 assistant 消息，保持 `task.messages` 不变。最终 48 项相关测试通过，独立质量复核通过。
- 对话 / 设置规格与质量复核、制品规格与质量复核均已通过，无未解决的已确认重要代码问题。

## 自动测试

| 范围 | 结果和口径 | 证据 |
| --- | --- | --- |
| 本次重构整套 Swift | XCTest 1390 项，17 项跳过，0 失败；另有 Swift Testing 36 项通过。该完整运行早于最终下载与空白显示两个小修正 | `/tmp/travelcat-ui-full-swift.log` |
| 最终 42 相关 Swift | 48 项，0 失败，含呈现 9、制品 8、导航 7、原生模型 24 | `/tmp/travelcat-ui-final42-green.log` |
| Python 运行时完整回归 | 150 项通过，含原生制品和连接代次边界 | `/private/tmp/travelcat-artifact-generation-runtime.log` |
| 下载竞态 RED / GREEN | RED 确认旧代码覆盖快照；GREEN 8 项通过 | `/private/tmp/travelcat-artifact-download-red.log`、`/private/tmp/travelcat-artifact-download-green.log` |
| 空回复 RED | 旧代码会保留两个空回复行；修正后的覆盖见最终 48 项 | `/tmp/travelcat-ui-empty-reply-red.log` |
| 正式 release 打包 | 最终 42 编译、签名、安装通过 | `/tmp/travelcat-ui-package42.log`、`/tmp/travelcat-ui-install42.log` |

未将最终 48 项针对性回归称作再次运行全部 Swift 测试。图片 / PDF 的端到端实机下载、远程 SSH 和完整 ACP 模型执行未在本轮重新验收。

## 真实组件离线验收

夹具使用生产视图和内存凭据 / 确定性运行时，不读取真实账号。已检查正文与运行过程分区、审批选择与状态回读、断线及恢复、新建 / 历史草稿隔离、不同 Agent 的新草稿隔离、Enter 发送及 Shift + Enter 换行、列表筛选不跳转当前对话。

已检查设置分类、原生常用配置与高级诊断展开、运行环境、数据与审计、ACP 选择镜像页和高级手动配置切换 / 取消返回。已检查制品只读内容和版本确认反馈。不能把离线夹具结果当成真实模型或真实 Docker 执行证据。

2026-10-24 使用最终42源码重建隔离夹具，补充检查1000×740与760×600窗口、长中文换行、小窗口审批及拒绝回读、失败提示、保留历史位置时的新回复按钮和跳转。原生添加完整走通基本配置 → 离线连接检查 → 模型确认 → 保存并选中新Agent；ACP完整走通固定镜像 → 离线握手/清理确认 → 模型配置 → 保存并选中新Agent，并验证缺少API Key时保存失败。两种新增均只使用内存凭据和独立临时目录，真实账号与正式Agent配置未变。

## 正式 41 实机结果

保留原有账号和两段历史会话，另建专用低风险验收对话，未向生日贺词和原 P0 会话追加验收消息。

- 任务 ID：`921CA702-5CB1-4847-89EF-3472C7E8D6ED`。
- 使用现有官方账号和固定目录 `/private/tmp/travelcat-native-p0-client/workspace`，真实工具审批展示限定文件写入命令，点击单次允许后实际生成 `ui-delivery-build41.md`。
- 文件内容、应用预览和通过原生保存框生成的 `/private/tmp/travelcat-ui41-downloaded.md` 逐字相同，共 **127 字节**；SHA-256 为 `7008a5cb3945f40860da6d8d14fdcbb2c538ed963f2af43ce4116bb5f16b1682`。
- 真实点击“确认此版本”后显示“此版本已确认”，审计 `artifact.confirm.verified` 时间为 `2026-10-23T14:32:32Z`；下载完成审计 `artifact.download.completed` 为 `14:33:08Z`，摘要相同。
- 更多操作的“停止后台命令”成功停止一个真实后台命令，会话信息显示停止 1 个且当前无运行中的后台命令；`ui41-interrupt-v2-should-not-exist.txt` 在原 90 秒期限后仍不存在。停止确认审计时间为 `14:42:52Z`。
- 主操作栏“停止本轮”在等待审批时成功取消本轮，官方状态回读为已取消，`ui41-toolbar-cancel-should-not-exist.txt` 不存在；清理确认审计为 `14:47:28Z`。
- 活动轮次长命令的另两次尝试中，模型提前结束本轮，未在活动轮次中及时触发主按钮。这两次**不计作执行中主按钮中断通过**；其生成的 `ui41-interrupt-should-not-exist.txt` 和 `ui41-interrupt-v3-should-not-exist.txt` 原样保留。现有后台停止已另行验证；原生中断模型相关 24 项回归通过，旧 build 40 的真实执行中中断证据见原 P0 验收报告。
- 正式设置页的数据与审计入口可用；通过系统保存框导出不含正文的审计摘要，`includesContents=false`，当次导出包含 437 条记录。未更改保留策略或清理证据。

证据：`/tmp/travelcat-ui41-artifact-receipt.json`、`/tmp/travelcat-ui41-control-file-check.json`、`/private/tmp/travelcat-ui41-audit-summary.json`。截图存于本次工作台实机截图目录。

## 正式 42 最终实机结果（2026-10-24）

- 首次打开仍读到此前钥匙串失败状态，工作台按保护规则阻止调用、未覆盖原文件。正常退出重启后，由用户手动放行系统钥匙串；工具没有操作受保护窗口、读取密钥值或创建替代密钥。
- 三段真实会话均恢复，原生日贺词正文与既有P0会话保留，未向这两段追加验收请求。工作台不再显示钥匙串错误或空白助手名称行。
- 在同一验收任务恢复官方线程 `01a1692a-7ed0-7132-ab79-936ef2d5e59d`，账号已登录、固定workspace未变，回读后台命令0个；未重新执行制品写入或重放旧审批。
- 再次打开 `ui-delivery-build41.md` 时直接显示“此版本已确认”，没有再次点击确认。说明41保存的任务 / 路径 / 内容版本确认在42重启后恢复。
- 在42通过原生保存框下载 `/private/tmp/travelcat-ui42-downloaded.md`，应用回读“预览版本已保存”。源文件、41下载与42下载三者逐字相同，127字节，SHA-256均为 `7008a5cb3945f40860da6d8d14fdcbb2c538ed963f2af43ce4116bb5f16b1682`。
- 同一线程真实发送不调用工具的后续消息，实际助手回复“界面与制品验收已完成.”，仅出现一次；状态回读本轮完成，输入框为空，没有待审批请求。
- 正式42设置页仍显示原Agent及已登录状态；关闭设置后返回原对话。正式应用留在已验收的对话中，可继续使用。
- 最终实际进程16619来自正式应用路径；主程序摘要、全部46个bundle文件与42安装收据一致；严格签名检查通过，两个原生制品运行时资源与正式源码逐字一致。

证据：`/tmp/travelcat-ui42-final-client-receipt.json`、`/tmp/travelcat-ui42-final-process.txt`、`/tmp/travelcat-ui42-final-protection-20261024.json`。

[最终对话截图](/Users/nebulae/.codex/visualizations/2026/10/16/01a14439-36a7-7073-95c4-70395c954db8/travelcat-workbench-build42/conversation-final.jpg) · [重启后的制品确认截图](/Users/nebulae/.codex/visualizations/2026/10/16/01a14439-36a7-7073-95c4-70395c954db8/travelcat-workbench-build42/confirmed-after-restart.jpg) · [正式设置截图](/Users/nebulae/.codex/visualizations/2026/10/16/01a14439-36a7-7073-95c4-70395c954db8/travelcat-workbench-build42/settings-final.jpg)

## 安装与数据保护

- 40 → 41 和 41 → 42 均先正常退出旧应用，再用原生安装器替换，保留旧包备份。两次安装后全部 **46 个 bundle 文件** SHA-256 与源安装包一致，`codesign --verify --deep --strict` 通过。
- 两次安装各自前后 **76 个 TravelPetData 文件** SHA-256 均相同。与开始重构的更早基线相比，仅 `state/automatic-travel.json` 在旧应用运行期间发生变化；未手动改写该文件，不将其称作全程字节不变。其余旅行文件保持一致。
- 493 个既有源文件基线中，13 个属于本次预期修改，其余 480 个未变；`Assets`、`Fixtures`、`Tests/Fixtures`、`Sources/TravelUI/Resources` 下的正式资源无变化。新增实现和测试另行保留。
- 初次打包遇到旧独立构建缓存中缺少固定 CLI 文件，未绕过不可变制品保护，改用 `/private/tmp/travelcat-ui-release41` 完整重建并成功打包。
- 最终安装收据：`/tmp/travelcat-ui-install41-receipt.json`、`/tmp/travelcat-ui-install42-receipt.json`；源 / 数据保护收据：`/tmp/travelcat-ui42-final-protection.json`。

## 最终验收和清理

- [x] 用户完成macOS钥匙串授权后，42完成启动；同一官方会话恢复，空白助手行消失，原有记录保留。
- [x] 重读真实制品，重启后同版本已确认；42再次下载摘要匹配，真实继续对话完成。
- [x] 已删除仅含已核验42安装包的 `dist`；最终上传审计 `upload-audit: status=ok`、`git diff --check` 通过，暂存区0字节。日志：`/tmp/travelcat-ui42-final-upload-audit.log`。

历史启动诊断 `/tmp/travelcat42-startup-sample.txt` 曾显示42主线程等待 `SecItemCopyMatching`；该阻塞已在用户完成授权并重启后解除。系统授权由用户完成，未绕过安全保护，也未读取或输出密钥值。
