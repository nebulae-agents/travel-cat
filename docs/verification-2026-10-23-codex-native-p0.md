# Codex 原生 P0 实施与验收记录（2026-10-23）

当前状态：本机 P0 闭环已完成，正式安装并运行 1.4.1 build 40。官方登录、真实模型请求、单次批准与取消、执行中断后的后台进程停止、同一官方 thread 的重启恢复和继续对话均取得客户端证据。验收覆盖本机 Codex CLI 0.158.0、官方账号的 GPT-6-Luna；后续运行时保留扩展入口，本次没有实现 Claude/DSH 原生适配。

## 交付内容与边界

- 新增 Codex 原生分支，保留 ACP Docker。独立 profile 与官方 ChatGPT 登录使用系统 keyring，不读取或复制既有 CLI 账号凭据；通过私有 Unix WebSocket 连接官方 App Server。
- 发起、审批、中断前保存操作意图与加密审计；RPC 接受、官方轮次终态与后台命令停止分别确认。超时显示待核实，不自动重发正文。
- 审批绑定 task/thread/turn/item、连接代次、摘要和期限，只允许单次决定；未知或扩大权限的请求拒绝。原生模型请求由官方 Codex 提交，界面区分其工具审批与容器模型网关审批。
- 中断先等待官方轮次完成，再根据本产品的绑定查询后台终端，调用官方 terminate 并完整读回为空。已经结束的轮次可单独停止本会话后台命令；不根据用户传入 PID 或系统 PID 杀进程。
- 审批卡片取消使用同一停止确认链。旧控制回调不能覆盖恢复后的下一轮；中断、审批、断开、恢复与追问之间有互斥保护。新轮次清除旧停止提示，避免将过去的检查显示成当前状态。
- 恢复使用 thread/resume 和分页历史，按稳定 item ID 合并。无增量游标时，交界处的流式文本以最终 item 为准；界面保留断连审计缺口说明，不重放旧审批。
- 工作台加密自身对话、配置和审计；Codex 运行时独立管理其记录，不将后者宣称为工作台 AES 加密数据。成本价格表、其他原生运行时和 SQLite 迁移不在 P0 范围。

## 自动验证

- 控制修复后的完整 Swift 回归：1376 项 XCTest，17 项跳过、0 失败；另 36 项 Swift Testing 通过。日志 `/tmp/travelcat-build39-final-swift.log`。
- 最终 build 40 仅增加新轮次清除旧提示；原生与安全存储定向 35 项通过，其中原生模型测试 24 项，且完成 release 编译和真实 UI 验证。最后增量没有重新执行全部 Swift 图形回归。日志 `/tmp/travelcat-stale-notice-red.log`、`/tmp/travelcat-build40-native-green.log`、`/tmp/travelcat-build40-package.log`。
- Python AgentRuntime 全量 144 项通过，其中原生模块 55 项。最终包内 Python 源码与这次测试的源码一致。日志 `/tmp/travelcat-build39-full-python.log`。
- 新控制竞争与旧提示用例先失败后通过。原生规格、传输及控制质量复核报告的问题均已修复，收尾复核未发现新的有证据 P1/P2。
- 移除已验证安装包的临时 dist 后，上传审计 status=ok、staged bytes=0，`git diff --check` 通过。日志 `/tmp/travelcat-build40-final-upload-audit.log`。

## 正式客户端验收证据

所有模型与文件操作仅使用本次独立实例和目录 `/private/tmp/travelcat-native-p0-client/workspace`。

| 项目 | 实际结果 | 最值得核对的证据 |
| --- | --- | --- |
| 官方登录与任务 | 用户本人登录；刷新得到已登录状态及 7 个模型，选择 GPT-6-Luna；真实无工具请求完成 | 原生实例 `52B662BC-086F-42C2-8C14-2116C815C1F0` |
| 单次批准 | 正式卡片选择“仅允许这次”，命令退出码 0 | `native-acceptance.txt` 内容 `travelcat-native-p0`，SHA-256 `b0b432d171784c3e5586b20b1450f412c2bc017de76d332366e0318805248f3c` |
| 拒绝/取消审批 | build 38 和最终 build 40 均从卡片取消，官方轮次 interrupted；拒绝文件未创建 | `denied-acceptance.txt`、`build40-denied-marker.txt` 均不存在；最终取消轮次 `01a16754-9cad-72e1-987a-dc10809b81db` |
| 执行中断 | build 39 在 shell/sleep 实际运行时取消；官方 interrupted 后清理 1 个后台命令；操作系统只读核对父 shell 和 sleep 均退出 | `native.interrupt.cleanupConfirmed`，2026-10-23T05:44:06Z，terminatedCount=1，轮次 `01a16748-9dbd-7462-be66-8d4564cfdaa1` |
| 已结束轮次的后台停止 | 模型已 completed，shell/sleep 仍运行；点击“停止后台命令”，确认终止 1 个并读回为空 | `native.backgroundStop.confirmed`，2026-10-23T05:46:32Z；官方命令 item 完成事件 exitCode=137 |
| 延迟副作用 | 在原定 90 秒期限后再次检查，两个新中断标记仍不存在；已批准文件内容及 mtime 没有变化 | `build39-interrupt-marker.txt`、`build39-background-marker.txt` 均不存在；mtime_ns `1792725679438477715` |
| 最终重启恢复 | 正常退出 build 39、安装并启动 build 40，恢复同一 thread；登录保留、后台计数 0，未重新执行旧写文件任务 | 官方 thread 始终为 `01a16691-14b4-7711-82e3-00386ccf538e` |
| 恢复后继续 | 在最终版本发送无工具追问，得到“原会话恢复已确认，build 40 验收完成。”；界面仅一条最终助手回复，官方 completed | 轮次 `01a16755-c7c6-71c0-aad2-f19365dbd0d3`，2026-10-23T05:57:21Z |
| 加密审计 | 最后读取时现存 255 条、207 KB、到期清理 0；已读回取消意图、后台清理和官方终态，原记录保留 | 取消卡片的 `native.approval.cancelRequested` 与 `native.interrupt.cleanupConfirmed`（terminatedCount=0）均可查看 |
| 旧入口兼容 | 最终版本“添加”仍有本机 Codex 与 ACP Docker；原有 ACP 发现面板可打开，未选镜像时保存禁用，取消后仍 1 实例、1 任务 | 本次只检查界面，没有创建容器或保存新实例 |

产品 task ID 为 `3DE87B6B-3BDD-4B78-838A-FB808C328C57`。正式工作台、审批卡片和最终对话均进行了截图/可访问性验收，按钮与内容可操作。原授权写文件的摘要与 mtime 在安装、恢复及最终追问之后仍保持一致。

## 安装与数据保护

- 正式位置：`/Users/nebulae/Applications/Travel Cat.app`，1.4.1 build 40。运行进程来自正式路径，深度严格签名有效，安装前后完整包体逐文件一致；sidecar.py、codex_native.py、codex_native_transport.py 与源码逐字节一致。
- 主程序 SHA-256：`5238b6c365bfecfb9da636a5ff752df720d5ede940b84246ce8f39fe682c2d6a`。
- 安装器保留旧 build 39：`/Users/nebulae/Applications/.Travel Cat.app.backup.20261023T055258Z.53758`；安装日志 `/tmp/travelcat-build40-install.log`。
- build 39、build 40 各自正常退出后捕获旅行文件基线；每次安装前后 TravelPetData 的 76 个文件摘要完全一致。最终文件复核与 build 40 安装前基线也完全一致；没有手工改写、清空、移动或暂存旅行数据。
- 与凌晨更早基线相比，应用正常运行曾更新 `state/automatic-travel.json`；不把自然运行状态变化归因于安装。Assets、Fixtures、Tests/Fixtures、Sources/TravelUI/Resources 基线的 41 个文件均未变化。
- 原加密记录、官方登录与实例没有重置。未提交、推送或发布，未创建持续自动化。临时 dist 已清理。

## 本次发现并修复的问题

1. build 36 读取提示隐藏了具体错误。新增安全错误类型/系统状态码详情，并继续禁止读取失败时覆盖。build 37 重启后原 8 条审计读回成功；旧失败没有错误码，不能断言为钥匙串损坏或锁屏导致。
2. 实际工具审批包含 `environmentId: "local"`，旧逻辑误拒绝所有非空标记。修正为只接受省略或明确 local，继续拒绝未知/远程环境，不展示永久执行策略授权。
3. build 38 单独 turn/interrupt 会留下后台 shell，曾实际写出 `interrupt-finished.txt` 和 `interrupted-should-not-exist.txt`。保留这两个旧标记作为失败证据；build 39 增加官方后台终端停止和读回，在不同新文件名上通过验收。
4. 控制回调与恢复、新审批、断开之间的竞争可能覆盖新操作或残留取消状态。以操作 ID 核验回调，并对冲突入口互斥，回归已覆盖成功与失败回包交错。
5. 上轮停止提示在新轮次中残留。build 40 清除该提示，客户端已核对新轮次不会继续显示旧停止结论。

Codex 0.158.0 的 Unix socket 使用 WebSocket；stdio proxy 仅转发字节。当前版本拒绝 TOML 内 untrusted，但显式 thread 参数中的 untrusted/user 受支持且读回核验，未降低权限。空 thread 无 rollout 的失败不计入恢复通过；上表为实际登录任务的客户端证据。
