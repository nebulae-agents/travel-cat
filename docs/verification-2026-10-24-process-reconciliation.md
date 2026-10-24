# 历史执行状态核对：本机验证记录

日期：2026-10-24。范围为原生 Codex 会话的过程证据与显示，本记录不代表远端发布或客户端交互验收。

## 行为与证据

- 新增 `native_reconcile {taskId}`，只读取已绑定官方会话的 `thread/turns/list` 与 `thread/items/list`；不接受任意 thread，不调用 `thread/resume`，不重放控制、审批或助手消息。
- 与后台状态查询共用非排队读取槽；控制忙时立即跳过。所有页、范围锁、写入等待与响应共用 5 秒总期限，Swift 端为 15 秒。每页前后核对任务对象、实例、连接 generation、thread 和当前 turn；每类列表最多 40 页、4,000 项，两个列表共用 8 MiB 响应预算，游标最长 4,096 字符。
- 完成、恢复、停止后台命令后做有界核对，详情中提供“核对执行记录”。现有 5 秒后台轮询只查当前后台列表，不扫描历史。
- 查询只为已观察到且 item/turn/type 一致的过程写入 `reconciledStatus`、`completionObserved` 和回合状态证据；完整且绑定有效的读取同时更新有界运行时终局证明缓存，不改当前 turn 或控制原字段。保留原 `status`、过程正文、助手正文、消息顺序与原审计；查询失败或绑定过期不改变任务终局。
- 只有官方类型对应的终局状态或有效完成证据才显示终局。回合已结束而项目只有开始记录时显示“待核对（最后记录：执行中）”；新鲜且绑定有效的后台列表命中同一 item 时，优先显示“后台运行”，即使已有历史终局；原终局证据仍保留。后台 0 项、未知或过期不改写已确认终局，也不能推断缺证据项目的成功或取消。
- 已确认终态不被 started、delta 或旧快照降级。查询取得终态后，仍允许同 item/turn/type 且终态一致的真实 item/completed 事件补全一次过程正文，以可选 `liveCompletionObserved` 标明；随后重复完成、旧 started/delta 或快照不得截短正文。新回合期间，只接受已知过程 item、原 turn/type 完全一致的晚完成；未知旧 item、错误旧 turn 和旧审批仍拒绝。非法 turn/completed 状态保留原通知审计，在审批、pending operation、中断缓冲或后台核对副作用之前拒绝。运行时已确认终局缓存最多保留 4,000 回合，原始晚通知仍可观察。
- 审批接收与回应边界同时读取终局证明：官方历史已证明结束的回合，不再产生新审批权限，遗留审批的 accept / decline / cancel 均不能发送。查询本身保留原审批卡、任务状态、pending operation、消息和审计；新活动回合的审批仍正常。

## 官方协议来源与兼容

本机 `codex-cli 0.158.0` 的 `codex app-server generate-json-schema` 生成器。核对源为生成的 `v2/ThreadItemsListResponse.json`、`v2/ThreadTurnsListResponse.json`，未提交生成物。

- CommandExecutionStatus / PatchApplyStatus：`inProgress`, `completed`, `failed`, `declined`。
- MCP / Dynamic tool 状态：`inProgress`, `completed`, `failed`；Collab tool 另有 `interrupted`。
- TurnStatus：`inProgress`, `completed`, `failed`, `interrupted`。
- ThreadItemEntry 提供可选 `completedAtMs`。只接受非布尔、有限、非负、整数且不晚于当前时间的毫秒数；不为缺少合法状态的命令虚构成功。NaN / Infinity 在 JSON 序列化前拒绝。

旧密文缺少新证据字段仍可读取。旧版本曾对缺少 status 的项目默认写入 completed，因此原值保留，但其展示为“待核对（最后记录：已完成）”，直到取得有效官方证据；不会以旧默认值锁定终态。

## 本机验证

TDD 先观察行为失败再实现：首组 Swift 3 用例有 4 处预期断言失败（晚完成被丢弃、终态回退、缺状态误判成功）；后续又复现原字段被历史覆盖、新提交空隙被旧 started 抢占、空恢复误判成功和时间证据边界。Python 先复现缺少只读 RPC、分页预算缺口及旧 started 复活控制状态。

展示优先级追加回归：1 个用例分别覆盖 completed / failed 终局与同 item 新鲜后台记录冲突，先观察到 2 处预期失败，再通过调整展示条件顺序转绿。用例同时验证后台 0 项、未知、过期及不同绑定不覆盖原终局，证据字段字节对应值保持不变。

规格复核收尾：2 个 Swift 用例先观察到 16 处预期断言失败（非法完成清除审批、query 证明阻止完整 live 输出），1 个 runtime 用例先复现读取终局后旧 started 复活当前控制回合；实现后均通过。另覆盖读取失败 / 绑定过期不能写证明、证明缓存界限及 query→live 升级后的重复通知保护。

质量复核追加：Swift 2 个用例先观察到 8 处预期断言失败，Python 2 个用例先观察到 3 处预期失败，复现查询已证明终局后晚到 / 遗留审批仍可发送 accept。只在两端既有审批接收、回应边界检查证明后转绿，同时验证查询不删除原卡片、不改原控制状态，以及新活动回合仍可正常批准。

最终检查：

| 检查 | 结果 |
| --- | --- |
| 完整 `Tests/AgentRuntimeTests` | 180 tests，0 failures / errors |
| NativeAgentModelTests | 54 tests，0 failures |
| NativeAgentDataTests | 7 tests，0 failures |
| NativeProviderConnectionTests | 4 tests，0 failures |
| AgentWorkbenchPresentationTests | 9 tests，0 failures |
| AgentWorkbenchRecoveryTests | 11 tests，0 failures |
| Swift 合计 | 85 tests，0 failures |
| `git diff --check` | 通过 |

Runtime 测试使用虚构服务端与临时回环 / Unix socket，验证实际 transport 的期限、迟到响应、作用域与控制契约，不会调用真实模型。首次受沙箱 socket 权限限制，使用原生额外权限重跑后完整通过。时间边界测试曾触发本机 Foundation 对非法 NaN 序列化的进程中止；增加 JSON 合法性前置检查后，非法输入被正常拒绝且已有证据不变。

## 待验收与边界

Mac 锁定，原生客户端交互和布局仍待验收。离线预览源列表已补新文件，夹具提供旧 completed 与缺最终状态的命令以供后续验证；本次未启动预览、未完成真实官方会话端到端验收、未重新安装正式应用、未合并或发布。

未改动 TravelPetData、私有部署配置或原始资源。
