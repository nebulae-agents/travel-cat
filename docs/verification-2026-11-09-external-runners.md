# 真实外部运行器治理验收（2026-11-09）

范围：基于 build 55 对应工作树的生产运行器实现，使用临时独立配置、工作目录及本次容器。正式客户端未替换，未迁移正式数据、未复制登录或模型密钥、未提交或推送。下列证据分别覆盖运行器边界，不等同正式 UI 已完整验收或真实模型生成成功。

## 真实 Codex app-server

运行 `Scripts/run-agentx-native-governance-acceptance.py <official-codex-path>`，直接调用生产 `CodexNativeController` 和 Unix WebSocket transport，无替身。实际 CLI 为 ChatGPT.app 内官方 `codex`，版本 `0.167.0-alpha.3.2`。新建临时 managed profile，`authenticated=false`，模型目录返回 9 项；未发起模型 turn。

2026-11-09 最后运行退出码 0，12 项检查均通过：

- 连接与初始化成功，服务器回传 profile 身份匹配。
- 主动断开宿主连接后，daemon 的 PID 与启动身份保持；新 Controller 重新连接同一 daemon。
- 真实空线程创建成功；后台终端查询/停止确认成功（空线程没有后台命令）。
- `native_quiesce` 返回停止确认，daemon 退出经生产身份凭据及进程回收检查确认。
- 重复 quiesce 成功；已封锁 Controller 拒绝重新连接。
- 新 Controller 启动新 daemon，`(PID, processIdentity)` 改变；再次停止与退出确认成功。

证据保留：`/private/var/folders/bf/5cgzm23s1dd0444j1q8x3gk40000gn/T/agentx-real-native-f05vl0fg/report.json`。

**明确边界：**以上包含 daemon 断连重连，不包含正在推理的 turn 或带真实后台命令的恢复。额外尝试创建未执行任何 turn 的空线程、断开后 `thread/resume`，官方服务器拒绝该请求；没有把它记成线程恢复通过，也没有在缺少服务端原因时断言产品缺陷。成功推理历史恢复仍需独立认证的测试账户及新一轮验收。

## 真实 Docker ACP：断连、恢复与精确退出

初始专用 Colima profile `travelcat-agent` 为 Stopped。启动后核验本机 Docker `29.2.1`，显式 context `colima-travelcat-agent`，验收前无既有容器。使用本地已有固定摘要镜像，未 pull：

`localhost:5000/travelcat-codex-acp@sha256:9e1ac8187c77450bb885f269cf82464aea77fff820fd798a6b1bd8012b838bce`

生产 `sidecar.Task` 启动真实 `/opt/travelcat-acp/node_modules/.bin/codex-acp`，完成 ACP initialize/session-new，两个宿主 exec 客户端真实存活。容器回读确认非 root `65532:65532`、只读根、network none、没有宿主挂载。

随后实际停止专用 Colima VM：Docker 不可达，生产 Controller 的 quiesce 返回未确认并保留原任务。重新启动后沿用同一 Task/容器身份重试，返回确认，注册表清空，两个 exec 子进程均已回收。再次停止幂等成功。

最终以精确容器 ID `874d0b07b77fac9138844c2ee58fbddcd65612c2bfbade519b46e3d70a771e20` 查询，返回 `No such container`，同时 Docker info 成功，排除“服务离线所以查不到”的假成功。11 项检查全 true，额外 cleanupConfirmed=true。

证据：`/var/folders/bf/5cgzm23s1dd0444j1q8x3gk40000gn/T/agentx-real-docker-escx0xrm/report.json`。首次脚本使用泛型 `docker inspect` 并依赖错误文本，导致清理断言假阴性；独立 `container inspect` 证实已清理，修正验收脚本后完整断连恢复重跑通过，生产实现未为此改动。

可复现脚本：`Scripts/run-agentx-docker-governance-acceptance.py --allow-empty-profile-disconnect`。它要求整个专用 VM 的独占验收窗口、显式开关、精确本机 Colima socket、Docker 可达且没有既有容器；启动前检查无容器，断连前再次检查仅有本次精确容器 ID；这些仍是时点检查，期间不可并发启动其他工作。重启使用 `--activate=false`。脚本要求开始时服务已运行，结束保持该状态。本次额外恢复环境原始状态：Colima Stopped，Docker 当前 context 为 default，停止前确认没有剩余容器。

另由主任务执行既有 `AgentCodexLiveIntegrationTests.testRealSidecarCodexApprovalAuditAndCleanup`：真实 Swift Workbench → sidecar → Docker ACP → 模型请求审批 → 拒绝上游请求 → 清理链路通过（2.349 秒）。使用测试占位密钥，不发送真实上游推理。该测试同时校验导入、产物读取、审计、下载等既有契约；不将测试外部写入文件称为 Agent 创作。

## 旅行 CLI

新增显式启用的 `AgentXRealTravelLifecycleTests`：使用官方真实可执行文件及空临时 `CODEX_HOME`，由生产 `CodexTravelExecutor` 启动，验证受控失败后回收、shutdown 封锁和恢复不自动执行。前置检查拒绝非临时目录、任意用户符号链接、非空配置及不可执行程序；仅兼容 macOS 系统 `/tmp`、`/private/tmp` 别名。

收紧分类断言后最终重跑结果为 `timedOut`（15.016 秒；日志 `/private/tmp/agentx-p1-travel-verified.log`，1 项测试通过），不是已确认的 `notLoggedIn`：官方 CLI 到达执行期限后，由生产执行器回收所属进程，随后 shutdown/fence/resume 检查通过。没有将未知网络/认证原因归为某一确定根因。分类断言仅接受 notLoggedIn、timedOut、networkUnavailable，CLI 不兼容或通用执行错误会使测试失败。

此阶段完整文字与图片生成、运行中旅行任务取消及认证账户恢复尚未验证；不将未登录 CLI 的受控失败记为完整旅行通过。后续已完成用户隔离登录后的单张旅行链路，见文末补充与独立报告。

## 结论与剩余验收

真实外部进程与 daemon/container 停止证据已补齐到上述范围。当前可确认：Codex daemon 和空线程停止、Docker 真 ACP 会话断连时保持未知、恢复后重试确认、所属客户端回收及容器清理。此阶段尚需独立测试账户支持的真实推理中断、已持久化线程恢复、真实旅行文字与图片生成/取消；以下认证补充更新这些历史缺口，不能把上面的早期结果单独表述为全部完成。

正式数据保护由主任务前后核验：7 个根目录、7554 个文件，changed/add/remove 均为 0；两份清单 SHA-256 一致为 `43ee512f10956d228772aff9413f652918928bd193c50b2dda84752efff765b1`。

## 追加：用户隔离登录后的真实原生推理与恢复

用户随后明确授权在隔离环境登录并继续剩余验收。本轮新建根为 `/private/tmp/agentx-authenticated-jidovuzf`；未读取或迁移正式账户凭据。该 CLI 的 `login --with-access-token` 要求 agent identity credential，拒绝普通 OAuth access token；没有伪造该格式，也没有放宽生产认证策略。最终由用户通过官方 OAuth 完成专属 managed profile 的 **keyring** 登录，生产 `account/read` 确认 authenticated=true。登录仅属于本次 UUID profile，按用户要求保留以便后续验收。

通过生产 `CodexNativeController` 与真实官方 app-server 执行 2 个无文件、无工具请求，模型 `gpt-6.1-sol`，总计 52.915 秒。原认证报告中 **21 个布尔检查均为 true**，但后续独立审查发现其中 2 个固定回复检查及 2 个无工具检查的判定方式不足，不能把原报告独立视为 21 项充分验收证据。具体纠正与 0 请求补证见下节。实际流程如下：

1. 第一个短 turn 正常 `completed`，返回固定文本 `AGENTX_NATIVE_ACCEPTANCE_OK`。
2. 关闭 Controller 后 daemon 仍存活；新 Controller 连接同一 daemon，`native_resume` 回读已持久化线程，完成状态保留；固定文本内容由后续严格只读补证确认。
3. 第二个长文本 turn 收到官方 `turn/started` 和首个 `item/agentMessage/delta`，确认仍 active 后调用生产 `native_cancel`。官方匹配终态为 **interrupted**，并非仅发送取消请求；返回 `backgroundStopped=true`、`terminatedCount=0`。
4. 生产 `native_quiesce` 确认停止，原 daemon 经凭据校验和进程回收确认退出。
5. 重新创建 Controller 启动新 `(PID, processIdentity)` 的 daemon，再次 `native_resume` 同一线程：第一 turn 的 completed、第二 turn 的 interrupted 均恢复，固定短回复保留。
6. 回读历史无工具调用项，无后台进程；最终 quiesce 和新 daemon 退出再次确认。

实际执行命令为 `python3 /private/tmp/agentx-authenticated-native-run.py`，该临时脚本与输入 `native-session.json` 均保留；输入仅含 profile/workspace/executable/instanceId，不含凭据。证据：`/private/tmp/agentx-authenticated-jidovuzf/native-authenticated-report.json`。本次验收生成的 thread ID 为 `01a1bec7-d35d-7860-bbfc-9aee0edd1a0d`，保留于隔离 profile，未写入正式应用历史。

可复现入口：`Scripts/run-agentx-authenticated-native-acceptance.py <native-session.json> --allow-two-model-requests`。它要求专属临时根、managed profile 与工作目录归属一致、无既有活跃 daemon，并保留显式两次请求开关。脚本本身不读取凭据；须事先由用户完成该 profile 的官方登录。全程保持生产权限与认证策略，不为验收增加权限。仓库复现入口仅作语法检查，没有为验证包装入口而重复付费生成；上述成功证据来自保留的实际临时脚本。原报告布尔值及最后 daemon 退出已独立回读，native-workspace 文件数为 0；固定回复与无工具项仍须以下严格补证作为依据。

该补充关闭了上文“认证推理中断、成功短 turn、已持久化线程断连及重启恢复”的原生 Codex 验收缺口。空线程恢复被拒绝的先前记录继续保留，不影响这次有真实 completed/interrupted turn 的恢复通过。仍不将“无后台命令”解释成“真实后台工具进程已验收”，也不将原生 Codex 结果外推为旅行图片生成或正式客户端 UI 验收。旅行另有独立证据如下。


## 独立审查纠正：严格助手回复与无工具历史补证

原脚本 `contains_marker` 对整个 items JSON 搜索固定文本，用户提示词自身就含该文本，因此可能假阳性；原 `no_tools` 读取顶层 type，而真实 `thread/items/list` 返回 `{turnId, item: {...}}`，也不足以证明无工具。原 `native-authenticated-report.json` 保留不覆盖，这 4 个旧布尔值不能作为充分证据。

修正后的仓库脚本按生产 Swift 同样的历史格式解包 `entry.item`，要求指定已完成 turn 的 `item.type == agentMessage` 且 `item.text.strip()` **精确等于**固定回复。无工具判断要求每条 wrapper 都有类型化 item，且类型属于 userMessage、agentMessage、reasoning；未知类型也不会默认为安全。7 个针对性正反检查覆盖用户提示词同名、错误 turn、错误 wrapper、真实工具项及正确助手消息。

只读补证执行 `python3 /private/tmp/agentx-native-typed-reply-readback-v2.py`，**新增模型请求 0 次**。通过生产 native_resume 恢复同一个隔离线程，9 项检查全部通过：

- 已登录；所有历史条目均正确解包。
- 唯一 agentMessage 的正文精确匹配，绑定 completed turn `01a1bec7-d40d-7b70-bb3e-2d6ee9251b81`；匹配 item ID 为 `msg_003019c4eaf3ea50016af15a2b7bf087d2aaa502be2bcd92f3`。
- 实际历史类型只有 agentMessage、reasoning、userMessage，无工具项。
- completed 与 interrupted 两个终态继续保留，无活跃 turn、无后台进程。
- 读回后生产 quiesce 成功，所属新 daemon 确认退出。

报告：`/private/tmp/agentx-authenticated-jidovuzf/native-typed-reply-readback-report-v2.json`。第一次补证误把 wrapper 当直接 item，严格匹配失败；该失败报告 `native-typed-reply-readback-report.json` 同样保留。随后对照生产 Swift 解包逻辑修正并重新只读验证，未为补证新增推理或改写原结果。

## 独立旅行链路补充

主任务随后完成隔离认证旅行 live XCTest（376.118 秒）：4 次真实叙事生成、1 次图片生成，明信片 ready、重开回读、CLI 取消与回收，并独立检查 1536×1024 PNG 画面与哈希。详见 [认证旅行验收报告](verification-2026-11-09-authenticated-travel.md)。这是单张隔离旅行链路证据；不把它扩展为长期稳定性、多模型覆盖或正式 UI 验收。
