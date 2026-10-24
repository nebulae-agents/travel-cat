# 思考内容默认折叠：实现与验证记录

日期：2026-10-24。独立第 9 项，起始于第 8 项提交 `75200c219a15e9c09a01fb05ceac4e8c1a80b974`，最终依赖基线为 `f951917e9524121d15fc66d8012e05bb15a5929a`；不替代第 1–8 项。

## 已实现范围

- 仅折叠 `role == assistant` 且来源精确为 `acp.agent_thought_chunk` 的 ACP 消息，以及 `NativeTimelineItem.kind == reasoning` 的已有内容。普通答案、Native `agentMessage`、legacy nil 和未知来源仍直接显示；不按关键词、phase、role、Markdown 标题或 `<think>` 猜测。
- `WorkbenchMessage.sourceKind` 是可选字符串，旧 schema 1 不迁移，未知值可无损往返。ACP 两种文本分片分别按连续同来源累加，保留稳定消息 ID；不与 legacy、不同来源或其他消息合并，不 trim 原始文本。非 text content 与未知 update 类型不伪造文本。
- Native 是只读投影，按既有 items 顺序显示在正文之后、运行过程入口之前；不复制保存为 messages，不伪造时间。读取 detail 已保留的 text、summary、content，按该字段顺序和数组顺序展示全部已知非空文本，分隔符仅存在显示层。已知空内容不占位；未知、畸形或 legacy 纯文本保留原始记录入口；其他未知 Native kind 继续留在运行过程。
- 新条目默认收起，仅展开后构造 Markdown reader 和原文/复制按钮。临时展开状态按 task + 稳定 message/item ID 隔离，不用正文作为外层身份。正文、审批和状态更新不重置该展开状态。
- Native 投影以 task/item 身份和 detail 的精确 UTF-8 字节缓存，空投影也缓存。普通状态刷新不重复解析；只有变更条目重解析。缓存不发布或修改存储状态，切换任务时不复用另一任务的记录。
- 展开复用现有 Markdown 阅读、完整原文快照和代码复制。ACP 原文对应 message.text；Native 的“查看原始记录/复制原始记录”始终对应原 item.detail，绝不把重拼的展示文本当原始记录。原文窗口保留打开时快照；普通消息的原有动作保持兼容。

## R2 审查修复：交接正文选择

独立质量审查确认 P2：ACP typed thought 作为 assistant 保存后，旧的“最后一个 assistant”交接逻辑会把后续思考当作上轮回复，且仅思考时仍启用交接。共享 `latestAssistantBody` 现在仅排除精确来源 `acp.agent_thought_chunk` 的 assistant；菜单启用状态与真实交接草稿动作共同使用它，nil/unknown/Native 正文不受影响。

原 View 中的草稿与导航动作移入 `AgentWorkbenchModel.prepareHandoff`，View 在成功准备后仅更新输入焦点。保留既有草稿追加、附件、父对话及目标选择行为；没有可交接正文时即使过期 UI 触发也不改变状态。未过滤搜索、滚动、runtime history 或审计等应保留思考的消费路径。

TDD 先抽取旧行为后，3 个真实交接测试按预期失败（草稿含 B、仅思考仍改变导航等），修正共用选择器后与原相关套件一同 138 项通过。旧 R1 全量运行不作为 R2 修复覆盖证据；修复后全量 aggregate/第 8 项独立修复由根代理另行验证，本记录仅报告 R2 相关验证。

## 数据与证据边界

`AgentWorkbenchModel+Native.swift`、恢复、控制、会话 attention、Python runtime、原生 items/detail/order 和既有审计路径均未修改；原始 Assets、Fixtures、Tests/Fixtures、TravelUI Resources 也未修改。投影/展开/复制不回写正文、detail 或审计。

“全部可用文本”仅指 detail 当前已保留的数据。既有 Native ingestion 在 item.text 为字符串时优先保存该 text，可能已省略同一 wire item 的 summary/content；第 9 项不能恢复这些字段，不迁移旧记录，也不声称捕获完整 wire 内容。已有接收上限仍为 500,000 字符。ACP 原始 sessionUpdate 没有因本项新增逐条事件审计。

本项没有新增 Native reasoning 专用 summary/text delta 的实时展示；只投影 item started/completed/resume 已保存的内容。专用 delta 不会误拼进 JSON detail，既有事件审计行为保持。

## 自动验证

最终 R2 相关 Swift 回归：**138 项 XCTest，0 失败**。

```sh
Scripts/travel-cat-swift.sh test --filter 'AgentThinkingContentTests|AgentWorkbenchTests|AgentWorkbenchPresentationTests|AgentMarkdownContentTests|NativeAgentModelTests|AgentConversationManagementTests|AgentWorkbenchNavigationTests'
```

其中新增 16 项测试：Thinking 9 项、ACP/兼容存储 2 项、Native 生命周期/恢复 2 项、真实交接 3 项。覆盖：

- 旧记录与未知来源 Codable 往返；思考→思考→答案→答案→思考各自累加、稳定 ID、legacy 隔离、非文本排除、普通思考关键词/标签答案保持正文。
- Native 多字段及数组顺序、空内容、顶层/嵌套未来格式、部分未知数组中已知文本、legacy raw fallback、未知过程保留，以及投影前后完整编码/文本字节不变。
- 60 次无关状态刷新不重复投影，空结果缓存，规范等价但 UTF-8 不同的 Unicode 更新只重解析变更项，任务身份隔离。
- 默认收起、稳定身份上的手动展开、不同任务/条目隔离、新展示会话重新收起；这属于组件状态验证，不等同屏幕键盘或 AX 验收。
- 显示正文与 raw 来源不同的完整 pasteboard 字节、固定快照、原生选区对同快照保持、大原始记录完整复制与原始记录可访问名称。
- 实际 Native started/completed 的 detail/审计字节及顺序保留，typed reasoning 更新唤醒已归档会话，专用 delta 不改变 detail，重复 resume 不复制思考项或消息。
- 实际交接动作在 A→下一轮 user→typed thought B 时保留 A；仅思考时不生成草稿或切换选择；legacy、unknown、Native 正文仍可交接。验证已有草稿追加、附件、parent、目标 Agent/导航、源记录保留与零 runtime 调用，搜索仍保留思考。

现有 Markdown 回归继续覆盖仅正文 UTF-8 变化时解析、128 KiB/512 blocks 上限、8 KiB 预览及完整 raw、CRLF/tab/emoji/代码字节。第 9 项未修改 Markdown parser。

本轮真实行为失败再通过的证据包括：ACP 思考被忽略/legacy 粘连与未知来源丢失、混合数组丢已知文本、空 summary 掩盖未来顶层字段、空 text 掩盖未来嵌套字段。新增 API 在实现前的编译失败日志仅说明接口当时不存在，不作为行为验收。

临时证据路径：

- `/private/tmp/travelcat-pr9-red-ingest.log`
- `/private/tmp/travelcat-pr9-red-partial-shape.log`
- `/private/tmp/travelcat-pr9-red-unknown-payload.log`
- `/private/tmp/travelcat-pr9-red-nested-unknown.log`
- `/private/tmp/travelcat-pr9-r2-red-handoff-behavior.log`
- `/private/tmp/travelcat-pr9-r2-regression.log`
- `/private/tmp/travelcat-pr9-r2-preview-build.log`
- `/private/tmp/travelcat-pr9-r2-preflight.log`
- `/private/tmp/travelcat-pr9-r2-upload-audit.log`
- `/private/tmp/travelcat-pr9-r2-source-freeze.json`（15 个生产/测试/夹具文件与独立 App 的构建冻结）

上传 preflight、upload audit 和 diff whitespace 检查通过。全量 aggregate/Python 由根代理在 Swift slot 交接后单独执行；本记录的 138 项不代表其结果。

## 独立离线 UI 候选

仅构建成功，未由实施者启动、安装或进行 UI 验收：

- App：`/private/tmp/travelcat-thinking-acceptance-20261024-r9-r2/TravelCatThinkingAcceptanceR9R2.app`
- Bundle ID：`com.nebulae.travelcat.thinking-acceptance.r9r2`，首次启动前已写入独立名称和身份。旧 R9R1 的 11 个文件与原冻结 SHA 完全匹配，未修改旧 App。
- 使用第 8 项 `prepare-agent-preview.py` 和 `preview-agent-workbench.sh` 打包；脚本仅增加两个生产思考源码的链接。SwiftPM 对 `--build-system native` 的弃用提示来自既有预览构建流程。

夹具使用生产 conversation、Markdown、折叠组件、审批与 composer，临时加密存储和内存凭据。无账号、Keychain、网络、sidecar、真实工作目录或用户数据。ACP 与 Native 两个固定任务涵盖 typed thought、普通 final/关键词、legacy/未知 source、Native 多字段/空/未知/legacy reasoning 和未知 process、CRLF/tab/emoji、长代码与超限内容。Native 多字段是直接赋给现有 detail 的投影夹具，不证明现有 ingestion 会保留 wire 中所有字段。

工具栏“追加思考”只修改夹具内存，不代表新增 Native delta 支持；“追加答案/刷新审批”用于检验稳定展开态与原文选区。审批拒绝仅使用离线 runtime 回执，不执行命令。首次启动后，原始期待字节写到独立 App 旁的 `expected/acp-thought.txt`、`expected/native-detail.json`、`expected/large-acp-thought.txt`，可用于初始或打开时快照复制核对。

40 pt 工具栏和 1 pt 分隔线额外保留：1000×740 产品视口对应 1000×781 window content；760×600 产品视口对应 760×641 window content，minimum 同样为 760×641。没有挤压产品 600 pt 最小高度。

待 UI 验收：初始仅见思考标题且答案直接可读；鼠标/全键盘展开收起；AX 名称和展开状态；收起无隐藏焦点目标；追加思考、答案、审批刷新保留展开态和 raw 选区；完整复制回读；长内容滚动以及审批/输入区域在两个视口均可用。自动测试和仅构建不替代这些屏幕证据。正式安装、真实运行时、远端 CI、合并或发布不属于本实施者已完成的验证。

## 根代理最终整合验证

第 8 项后续修复以本地快进整合，15 个第 9 项生产、测试和夹具文件与 R2 冻结 SHA 全部保持一致；此后仅由根代理补充本节证据。独立规格复核与质量复核均通过，交接 P2 已闭环。

| 验证 | 实际结果 |
| --- | --- |
| 完整 Swift，UTC | 1,538 项 XCTest 记录，其中 17 项按条件跳过、实际执行 1,521 项，零失败；另 36 项 Swift Testing 通过 |
| 上海时区提示词合同 | 21 项通过 |
| 完整 Scripts，包括其自有 Swift 探针 | 174 项通过，355.072 秒 |
| 第 8 项最终 runtime 源码，Python 3.13 独占复验 | 203 项通过，12.873 秒；成功注释输出零字节 |
| 最新 Python 资源整合后的 Native、退出与打包合同 | 90 项记录、1 项 opt-in 跳过，实际执行 89 项，零失败 |
| 上传工具、插件、技能、Agent 合同 | 串行通过 |

顺序为完整 Swift → 上海时区子集 → 上传工具 → 插件/技能/Agent → 完整 Scripts；所有其他测试与编译结束后，再独占复验 runtime。第 8 项先前一次完整 runtime 的旧 audit keepalive 失败与其单项通过记录均保留，不将最后通过反推为已查明前次失败原因。最后 Python 资源更新未修改 Swift 源码，整合后受影响子集另行通过。通过 wrapper 的当前产物目录核对，活动 Debug 测试包与资源包内 `codex_native_transport.py` 均等于源码 SHA `9346c2448d79a8701a1d18bcfa0aeed559ef6d19a10e1cab67fd05f088e8d2f0`；旧构建系统的闲置缓存保持原样，不当作当前运行产物。

根代理证据索引为 `/private/tmp/travelcat-final-integration-evidence.json`，对应完整日志为 `/private/tmp/travelcat-final9-r2-swift.log`、`/private/tmp/travelcat-final9-prompt.log`、`/private/tmp/travelcat-final9-r2-scripts.log`、`/private/tmp/travelcat-root-final-runtime.log` 与 `/private/tmp/travelcat-final9-integrated-runtime-subset.log`。当前活动包资源哈希为 `/private/tmp/travelcat-final-built-runtime-hashes.json`。远端检查需按提交后的准确 head 独立读取，不以这些本地结果代替。

### R9R2 原生界面实际观察与限制

独立界面操作者已核对 R9R2 bundle ID、可执行文件和夹具源 SHA；报告为 `/private/tmp/travelcat-r9-ui-evidence.md`。实际原生可访问控件操作确认：明确 typed 思考初始收起、其正文及 raw/copy 控件不在收起树内；普通答案、legacy 与 unknown 来源直接可读；展开/收起、代码横向滚动、追加思考/答案/审批后展开态保持；原文窗口快照及选区稳定；Native 显示投影与原始 JSON 入口分离；未知/旧格式入口、超限原文滚动可达；离线审批拒绝后草稿保留。这里的原生可访问动作不等同物理鼠标命中或完整键盘验收。

工具始终只返回台前调度缩略图，两个视口都没有完整窗口布局证据。Tab/粘贴没有产生可用输入结果，因此真实键盘遍历/展开、剪贴板完整字节回读均未计通过；不得以可访问文本或 expected 文件哈希替代。夹具没有隔离的 thought-only 状态及真实交接 handler，菜单边界和实际交接草稿仍只有自动化行为测试证据。上述限制没有被隐藏或升级为通过。

R9R2 与此前 R8R2 的打包 runtime 快照早于第 8 项最终 transport 修复；它们的离线会话视图未调用该 transport，界面证据只对应各自冻结的展示代码。没有正式安装、GitHub 合并、SSH、真实官方 Native 登录/活跃回合中断或模型调用的通过声明。验收 fixture、草稿和期望文件保留。
