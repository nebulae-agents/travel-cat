# Codex ACP 本机隔离镜像配方

此目录只包含构建配方，不随 `.app` 打包。基础 Node arm64 镜像固定为 Docker Hub 摘要，`@agentclientprotocol/codex-acp` 固定为 2.2.2，npm 依赖由 `package-lock.json` 的完整性校验约束。Python 3.11 由 Debian 仓库在构建时安装，因此重建结果还取决于当时的 Debian 包版本；运行时必须使用构建后核对的**最终镜像摘要**，不能直接填可变标签。

镜像把 `HOME`、`CODEX_HOME` 放在每任务独立的 `/tmp` tmpfs，使用容器内占位 API key 自动完成 ACP 认证，并将 Codex 模型提供方指向容器回环的 Travel Cat 中继。`web_search` 被禁用，以免出现未经过宿主审计和许可的托管工具。镜像里没有真实凭据；真实提供方配置和密钥只在应用本机配置界面管理。运行器仍强制禁网、非 root、只读根、无宿主挂载和固定摘要。

在已启用的独立 Docker context 中，从仓库根目录构建：

```sh
docker --context colima-travelcat-agent build --pull=false -t localhost:5000/travelcat-codex-acp:2.2.2 packaging/agent-runtime/codex-acp
```

首次构建需能访问 Debian 与 npm 仓库。本机验收使用仅绑定回环地址的临时 Docker Registry，推送后读回 `localhost:5000/travelcat-codex-acp@sha256:…`，再将**该摘要**、命令 `/opt/travelcat-acp/node_modules/.bin/codex-acp` 和 context `colima-travelcat-agent` 填入实例。容器启动使用 `--pull=never`，本地镜像必须仍在该 context 中。删除或重建 Colima profile 后必须重新核对摘要和镜像，不能沿用旧配置。

2026-10-18 的本地摘要及实际验收边界记录在 `docs/verification-2026-10-18-agent-mailbox-local.md`。本机握手、`/status` 与模型请求到许可门后拒绝已验证；真实模型上游响应、付费调用及正式 UI 任务仍未验收。
