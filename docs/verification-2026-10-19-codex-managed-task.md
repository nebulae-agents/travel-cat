# Codex 受管任务端到端预检（2026-10-19）

目标是从 Travel Cat 正式工作台创建一个真实 Codex ACP 受管实例并提交任务。本次先在临时数据根完成客户端、侧车、容器、审批和加密审计的联调；正式应用仍是已安装的 build 35，尚未保存实例或使用用户模型凭据。

## 已验证

- 新增需显式启用的 `AgentCodexLiveIntegrationTests`，调用生产的 `AgentWorkbenchModel` 和 `AgentSidecarClient`，使用独立的临时加密内容与审计目录、测试假凭据，以及本机 `colima-travelcat-agent` 中已固定摘要的 Codex ACP 镜像。容器完成 ACP 初始化、创建会话，普通任务提示产生模型请求和审批。
- 测试宿主在 `modelApproval` 处拒绝请求。正式加密审计读回 `model.request`、`model.decision`、`model.failed`，没有 `model.completed`；任务结束后的 `operation.stop` 可读回，`workbench.sealed` 不含明文提示。拒绝后侧车确认容器清理，Docker `ps -a` 为空；固定摘要镜像仍在。
- 模型地址为容器不能直连的 `https://127.0.0.1/v1`，API Key 为测试假值，且审批明确拒绝，因此没有向外部模型服务提交任务。端到端测试日志 `/tmp/travelcat-codex-live-swift-rerun.log`：1 项通过、0 失败；Python AgentRuntime 全套 `/tmp/travelcat-codex-denial-reverted-python.log`：86/86 通过。
- 审批拒绝立即返回，但官方 Codex ACP 适配器对应的 `session/prompt` 约 120 秒后才结束。曾尝试在持久审计拒绝后发送取消和清理，真实容器复测仍约 121 秒；已撤回这项无效改动，没有把测试通过说成响应时间问题已解决。对照与复测日志为 `/tmp/travelcat-codex-live-cancel.log`、`/tmp/travelcat-codex-live-stop.log`。

## 正式界面验收与本次边界

用户解锁并打开已安装 build 35 的 Agent 工作台后，正式界面显示 0 个实例及 0 个任务。点“添加”发现本机 `colima-travelcat-agent` 与固定摘要 Codex ACP 镜像；重新点击“检查 ACP 兼容性”后，界面显示“ACP 握手与容器清理均已确认”。随后的 Docker `ps -a` 为空。新实例表单已填写非敏感字段：名称“Codex 本机”、Responses、`https://api.openai.com/v1`、`gpt-6-luna`。用户选择的首次任务是仅发送“请回复 Travel Cat Agent 已连接”，不附本地文件，保持逐次模型审批。

用户确认当前没有可用的 OpenAI API Key，并明确选择“暂不创建，停在本机验收”。本次未在正式应用保存新实例或发起模型请求；复查时工作台窗口已不显示，未执行保存动作。正式界面在打开“添加”前显示 0 个实例、0 个任务，此后仅填写了未提交表单。后续若用户另行决定启用真实模型任务，需由本人创建适用的 API Key，按账号情况处理与 ChatGPT 订阅分离的 API 计费，在正式 UI 输入并保存凭据、发起任务、处理逐次模型审批，再核对加密审计、容器清理及实际模型结果。不得从 Codex CLI 会话或现有钥匙串提取替代。本次临时根测试不等同于正式应用任务或外部模型调用验收。

源码仍在 `codex/agent-mailbox-install` 的公共仓库关联工作树中，未提交、推送、替换已安装应用或改写正式 `TravelPetData`。
