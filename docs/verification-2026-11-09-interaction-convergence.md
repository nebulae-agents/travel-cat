# AgentX 交互收敛 A 验证记录

日期：2026-11-09。源码目录：agentx-manager-install。未提交、推送或替换正式安装。

## 实现与审查

- 导航：应用前后台分别记忆页面，平台往返、模块失效回落、Dock和运行入口统一区域；常驻前后台入口、路径与助手用途同步。22项专项测试通过，规格与独立质量复审通过。
- 配置：普通请求/工作流步骤记录无凭据配置快照；展开详情、清除会话覆盖、旧记录缺失标注、共享定义影响与所有发布入口确认。27项初轮专项通过，补充详情/跨应用测试17项通过，最终发布入口11项通过。规格与独立质量复审通过。
- 创建引导：来源、名称、成员、依赖、预览、安装成功分步流程；服务修复返回保留输入；编辑使预览失效；安装默认停用，启用不执行任务。28项专项通过，规格与独立质量复核通过。
- 修复重复预览重映射成员ID导致编辑丢失：同一来源保留身份，重新检查源摘要与当前依赖。未知能力字段在预览中保留，但仍阻止安装，不扩大能力范围。

## 自动验证

- 基线：212 XCTest、49 Swift Testing，零失败。
- github_preflight：status=ok。
- upload-audit：status=ok；physical_bytes=80658432、tracked_bytes=77619879、staged_bytes=0（当次检查值）。
- git diff --check：通过。
- 完整回归共1,876项XCTest（17项条件跳过），仅1条旧Dock契约断言失败；87项Swift Testing全部通过。旧断言要求无待处理时回chat，与已确认前台页面记忆冲突，已改为恢复inbox并增加frontend区域断言，保留应用归属与提醒隔离检查。随后AgentXTests 14项全部通过。生产代码未为该断言改动；没有重复完整套件，不将首轮表述为全绿。

## 隔离客户端

- `/private/tmp/agentx-convergence-native/AgentX Convergence Preview.app`
- 独立 bundle ID：`com.nebulae.agentx.convergence.preview`。
- 启动器固定 AGENTX_ROOT、AGENTX_HOST_DIRECTORY、TRAVEL_CAT_DATA 到该临时目录下的 root、host、travel，未使用正式业务目录。
- 当前debug产物及资源、ad-hoc签名；不是正式release包验收。
- 原生验收结果见下方；旧管理窗口渲染测试不能替代新的 AgentXAppCreationView 验收。

## 证据日志

`/private/tmp/agentx-convergence-baseline.log`
`/private/tmp/agentx-navigation-assistant-green.log`
`/private/tmp/agentx-config-publish-final.log`
`/private/tmp/agentx-creation-final2.log`
`/private/tmp/agentx-convergence-full.log`

- Dock契约复验日志：`/private/tmp/agentx-convergence-dock-recheck.log`。

## 原生验收结果与阻塞

主线程已在隔离客户端实际验证：
- 常驻前台/后台入口可用；后台人物页 → 前台 → 后台恢复人物页。
- 已查看完整窗口截图并检查当时窗口布局。
- 应用管理模板引导能够进入成员步骤；未配置模型时正确阻断。
- 修复模型服务页面可返回，引导中的应用 ID `acceptance-app` 保留。
- 关闭引导执行取消。

以上为主线程的实际UI观察，不等同以下剩余项目通过：本机响应服务端到端请求及持久化快照回读、新创建流程的成功安装/启用、重启恢复、960/1280两种尺寸和深浅主题组合、键盘与中文输入法完整验收、发布确认与配置详情的实际点击验收。相应行为有自动测试覆盖的部分，仍不能替代这些原生操作。

接续验收时，桌面工具初始化调用 `cua.getApp('com.nebulae.agentx.convergence.preview')` 未返回可用状态，约238.8秒后被中断。接续阶段未执行任何后续桌面操作，未创建新fixture、未启动本地响应服务、未修改正式应用或正式数据。工具是否改变前台焦点没有返回证据，不能判断。主线程另报告其首次桌面初始化也出现长时间等待，后续操作曾恢复正常。

按主线程指示停止继续调用桌面工具。Task 7 原生验收未完整完成，不能将本次交付表述为已完成全部客户端验收；隔离调试包保留，正式客户端未替换。

## 主线程原生验证追加

隔离客户端实际确认：常驻前台/后台按钮、后台人物页切前台再返回恢复人物页、平台应用管理入口、完整窗口截图布局。模板创建实际进入来源、名称与ID、成员步骤；无模型点击下一步明确阻断；进入服务修复页再返回并退回名称页，acceptance-app输入保留；关闭引导返回模板库。

尚未完成带本机响应服务的完整安装启用、配置快照端到端、重启、双尺寸深浅主题与中文输入法验收。追加验收代理的桌面调用长时间未返回，已中断等待；不将未返回结果视为成功。主线程首个CUA启动也曾异常耗时，随后上述交互正常。完整验收未完成，Task7保持未完成；未替换正式安装。

## 解锁后补充验收

主线程在隔离客户端完成 Local Acceptance 模型服务配置，模板 `acceptance-app` 安装成功且默认停用，随后明确启用并进入应用。发送“验收请求：返回当前模型。”后，界面出现完成记录。

磁盘与本机服务回读确认：
- `http://127.0.0.1:55286/v1/chat/completions` 收到 model=`acceptance-a` 及该用户请求。
- 运行 `7852f589-14d0-49cf-b4fd-16f87b2dd651` 状态 `completed`，响应“本地验收成功，模型：acceptance-a”，无failure。
- actualModel 与服务请求一致；effectiveConfiguration 保存 appID=`acceptance-app`、modelSource=`publishedBinding`、definitionRevision=1、appRevision=1、definitionPinned=false，以及对应成员/服务/定义ID。
- 证据：`/private/tmp/agentx-convergence-native/stub/requests.jsonl` 与 `root/apps/acceptance-app/runs/7852f589-14d0-49cf-b4fd-16f87b2dd651.json`。

这是本机固定响应端到端验收，不代表外部模型质量或正式安装验收。前述安装启用和本机请求快照待验收项至此完成；其余待验收项仍以后续实际记录为准。

### 主线程原生增量验收

- 安装成功页明确显示默认停用，点击启用后进入前台，本地运行数为0；启用未自动发起任务。
- 本机模型a的回复在前台实际可见；展开“本次运行配置”，显示应用、成员、服务以及版本1。
- 通过Cmd-Q正常退出，再按隔离应用路径重启；关闭旅行初始配置窗口后，从Agent菜单进入平台，恢复 `acceptance-app`、模型a和历史回复。
- Cmd-K打开应用切换器，Esc关闭。
- 选择模型b后，下次请求摘要显示“来自会话选择”；旧运行仍显示模型a及publishedBinding。
- 恢复发布绑定后，下次请求摘要回到模型a。此次切换模型b仅验证选择与摘要，未声称已执行模型b请求。

仍未完成：960/1280两种窗口宽度与深浅主题组合矩阵、中文输入法完整验收、发布确认的实际UI交互。Task7保留部分未完成，不将本轮表述为完整客户端验收。

本轮自建本机HTTP响应服务在上述验收后停止；隔离预览客户端保留，未退出或替换正式客户端。

### 发布确认与渲染矩阵补充

主线程实际操作定义编辑发布：确认框显示“对话助手 / Assistant 下次请求使用新版本”的影响；确认后 publishedRevision=2，前台下次请求摘要显示v2，旧运行仍保留v1。

新增 `AgentXAppManagementTests.testConvergenceShellAndCreationRenderMatrix`，复用NSWindow/NSHostingView与bitmapImageRepForCachingDisplay机制。在独立临时数据中渲染前台、后台、新创建界面的成员步骤、安装预览步骤，分别覆盖960×640与1280×820点、Aqua与DarkAqua，共16张PNG。创建界面保持生产使用的680×550点内容尺寸，置于对应宿主尺寸中。测试通过，且实际使用view_image逐张审查全部16张：未见主入口或主要操作按钮被遮挡、文本溢出；窄后台为纵向滚动内容，宽后台为分栏；深浅主题文字可辨。

这是原生离屏渲染与截图审查证据，并非逐尺寸鼠标/键盘交互验收，也不是正式安装包证明。截图位于 `/private/tmp/agentx-convergence-render/`，日志 `/private/tmp/agentx-convergence-render.log`。本次只增加渲染测试与验证记录，未修改功能实现。

中文输入法：主线程尝试Ctrl-Space及输入duihua，仅观察到英文直接输入，没有候选框；随后清空搜索并Esc返回。因此中文组合输入/候选选择仍未验证，需要明确选择中文输入源后再验收；该观察不是代码故障证据。Task7不标为全部完成。

## 最后一项中文输入法验收通过

用户切换中文拼音后，主线程在隔离客户端应用切换器逐键输入 d/u/i，搜索框保留组合文本 dui，列表未提前按拼音筛选。组合期间按 Down、Up、Return 后文本提交为“对”，切换器保持打开并筛出“对话助手”，当前应用仍为 BlackCat，未触发进入应用。清空后逐键输入 h/u/a，首次 Escape 仅取消组合文本，切换器仍打开；第二次 Escape 才关闭切换器，返回 BlackCat。由实际输入提交与取消行为确认中文组合处理通过；截图未独立捕获系统候选窗口，不将其作为视觉证据。

此前列出的剩余验收项现已补齐：发布确认及新旧版本隔离为原生交互证据，960/1280深浅主题为16张原生渲染截图证据，中文输入法为本节原生交互证据。正式安装、远端发布未执行；完整回归首轮与修正旧断言后专项复验的口径保持不变。
