# B：停止治理实现与验收记录

日期：2026-11-09。用户已确认 B 设计并授权实现；未提交、推送或替换正式安装。C 继续暂缓。

## 已实现

- 停止意图先落盘，再禁止新工作并请求取消；逐项结果与操作历史存于宿主管理区。
- 默认 30 秒界面等待期限，单调时钟计时、可注入测试期限；到期保留后台等待，不新增强杀。
- 同一活跃操作重试复用 ID；每个宿主任务独立收集结束证据，成功结果优先于后到取消。
- 外部运行器注册代次和最终静默状态均须核对；缺失适配器保持未知。
- 重启后保守阻断。HTTP 以宿主身份退出证据核对；Pi 使用宿主身份、run ID 与子进程回收凭据，无法取证不自动放行。
- 详情可查看逐项原因、时间、范围、重试与安全诊断；标题明确是最近停止记录，不声称引擎实时在线。

协调逻辑保留在现有 Controller 生命周期内，独立模型/持久化与 Pi 账本负责证据，避免另增一个与现有任务表并行的所有者。

## 自动验证与审查

- 基线：32 项通过。
- 修复后专项：49 项通过、0 失败；日志 `/private/tmp/agentx-stop-review-green2.log`。
- 规格复审和 Pi/存储质量复审已通过。修复了运行器更换竞争、成功与取消竞争、逐项串行等待、跨应用持久化错误污染、原因不明确，以及快速进程退出和回收凭据问题。
- 完整回归：TravelUI 489 项（跳过 9）、TravelStorage 401 项（跳过 1）、TravelCore 42 项均无失败；TravelCatApp XCTest 963 项（跳过 7）唯一失败为新增渲染样例的内建类型/ID不匹配，已修复。Swift Testing 88 项通过（远端/打包 Pi 集成样例因缺指定环境跳过）。日志 `/private/tmp/agentx-runtime-full.log`。
- 修复样例后定向补跑：6 项 XCTest 与 9 项 Pi Swift Testing 通过，退出码 0。实际 shell 子进程连续完成、凭据归属隔离与回收验证通过；日志 `/private/tmp/agentx-runtime-render-pi.log`。
- 停止详情四张 960/1280 明暗外观截图已逐张检查，原因、操作 ID、关闭/诊断/重试按钮均完整，无裁剪；`/private/tmp/agentx-runtime-native/renders/stop-*.png`。
- `git diff --check`、`github_preflight.py` 与上传审计通过；未暂存文件。

## 原生交互

隔离入口与源码：`/private/tmp/agentx-runtime-native`。预览 bundle `/private/tmp/agentx-runtime-native/AgentXRuntimePreview.app` 已构建，签名校验通过；构建日志 `build.log`。使用独立 data 目录和可控本机运行器，保留真实 30 秒等待期限。验收步骤见该目录 `ACCEPTANCE.md`。

最初两次点击因 Stage Manager 前台变化未触发操作；用户置前台后，主线程原生验收确认：

- 操作 `E0E413EC-EC85-4F72-975F-833061E6E861` 等待超过真实 30 秒后进入未确认；重试保持同 ID；释放本机运行器后后台更新为已确认，重新启用成功。
- 第二操作 `4F626AE3-F3F1-4F4A-8566-6997FEEAB6FD` 停止期间退出并重启后仍禁用，运行器代次更换使旧证据失效并继续检查；释放后同 ID 收敛。
- 本次回读隔离 `manager/stop-history` 和 `stop-operations.json`，上述两操作均为 stopped，runtime 项 confirmed。
- 原生发现管理行旧超时错误残留：原因是本地 error 状态在停止完成后重新显露。已按对应操作 ID 和可靠完成状态投影消除，详情重试同修；34 项定向回归通过（`/private/tmp/agentx-stop-stale-green.log`）。修正版原生复验通过。

最终修正版包 `AgentXRuntimePreviewFixed.app`（临时验收包 build 2）原生复验通过：重新启用、撤回释放信号再停用，31 秒后显示未确认且仅提供重试停止，没有启用入口；请求卸载并确认后又等待约 30 秒，明确超时且应用保留。关闭卸载窗口并释放本机运行器后，后台更新为已确认停止，管理行旧超时错误消失，启用按钮恢复。

最终回读：操作 `A3317BE7-4181-4210-892E-37A4820E6694` 为 stopped，runtime 项 confirmed；`apps/stop-preview` 目录和 `app.yaml` 仍存在，佐证未确认时卸载未执行。上述为主线程实际点击与界面观察，辅以本次数据回读，不以静态渲染替代。

## 边界

没有验证远端 daemon，不把本机替身成功外推为远端验收。旧 Pi 任务若没有所属进程凭据、部分启动记录无法证明退出，继续显示未确认；不根据 PID 或不存在的记录猜测成功。不操作 TravelPetData。
