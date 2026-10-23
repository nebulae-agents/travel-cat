# Agent 运行环境发现与快速创建：本机验收

2026-10-19。工作分支：`codex/agent-mailbox-install`，目录为关联的公共仓库工作树。代码未提交、未推送；原始私有仓库与 `TravelPetData` 未作为开发工作区使用。

## 交付行为

- “添加”先打开小屋风格的发现面板。Codex、Claude Code、DSH 只按固定可执行文件名和当前用户进程名扫描；展示安装位置、进程数或“未发现”，不执行 CLI，不读取配置、会话或凭据，不接管既有 CLI 会话。
- Docker context 只列出名称；只向 `unix:///` 本机端点发出有时限、总扫描期限和输出上限的 `info`、镜像和运行容器查询。远程 context 不自动连接。固定 `repository@sha256` 镜像与正在运行的容器分开显示；容器仅供识别，不接管或停止。
- 选择固定摘要镜像和 Codex、Claude、DSH ACP 命令预设后，由用户明确点“检查 ACP 兼容性”。侧车重查本机 context/镜像，用无网络、只读、非 root、无宿主挂载的容器和占位模型值完成 `initialize`、`session/new`，不发送任务提示词；只有容器移除得到确认，才签发绑定 context＋摘要＋argv 的本次检查结果。失败或清理未确认不能快捷保存，保留重试清理入口。
- 请求和结果通过现有加密管理审计记录；审计不可用时检查不启动。通过检查后，短表单只需名称、模型接口/HTTPS 地址、模型和 API Key；保存沿用实例校验、加密存储和本机钥匙串，不自动发起任务。高级手动配置保留。

## 实际验证

- TDD：扫描与 probe 均先出现目标行为失败，再实现。Python AgentRuntime 86/86 通过；Swift 全套在本功能主要代码完成后 1344 项、16 项跳过、0 失败，最终 UI/错误分支调整后又运行新功能聚焦测试 4/4，通过。完整测试日志分别为 `/tmp/travelcat-discovery-final-python-v3.log`、`/tmp/travelcat-runtime-discovery-full-swift.log`、`/tmp/travelcat-runtime-discovery-final-focused-swift.log`。
- 真实本机只读扫描：发现 Codex 命令且同用户进程 1、Claude 命令但进程 0、未发现 DSH；`colima-travelcat-agent` 本机 context 可用，`default` 不可用。发现固定摘要 `localhost:5000/travelcat-codex-acp@sha256:9e1ac8187c77450bb885f269cf82464aea77fff820fd798a6b1bd8012b838bce`。初次用短命令 `codex-acp` 检查失败且清理确认；依镜像配方改为 `/opt/travelcat-acp/node_modules/.bin/codex-acp` 后，真实 ACP 握手与清理确认通过，未留 `travelcat-agent-` 容器。未发送真实模型请求、未使用用户模型凭据。
- 离线原生预览（临时目录、假钥匙串/运行器）：点击“添加”可见工具、context、镜像、运行容器分类；远程 context 标为未连接；候选镜像初始不能保存，点击检查后出现简表单；空凭据保存被阻止；输入仅供测试的值后，新实例在列表中显示 `Docker · offline-colima` 且没有自动任务；“高级手动配置”仍打开原编辑器。预览与正式数据隔离。
- 34 号正式应用的邮筒浮窗和 Agent 工作台完成可见点击：点“添加”后看到 Codex 当前用户进程 1、Claude Code 已安装、DSH 未发现、本机 Colima 可用与固定摘要的 Codex ACP 镜像；未选镜像时“保存新实例”禁用。选择镜像并点击“检查 ACP 兼容性”后，正式界面显示“ACP 握手与容器清理均已确认”，再出现短表单；空 API Key 保存被拒，取消后工作台仍为 0 个实例、0 个任务。随后只读检查 Colima 无运行容器。没有执行 CLI、接管现有会话、发送模型请求或保存正式 API Key。
- 34 号安装包与安装位置逐文件一致；此前 33 号应用备份在 `/Users/nebulae/Applications/.Travel Cat.app.backup.20261019T030826Z.27531`。安装前后 `TravelPetData` 的 76 个文件及 `data-location.json` 与本次新基线完全一致。安装前新基线相对旧验收快照有一项现存的 `state/automatic-travel.json` 变化，未回退。
- 加入总扫描期限测试后重新构建签名 35 号安装包，本机安装时将 34 号备份在 `/Users/nebulae/Applications/.Travel Cat.app.backup.20261019T040338Z.42012`。35 号安装包与安装位置逐文件一致，签名有效；安装前后 `TravelPetData` 仍为相同的 76 个文件，`data-location.json` 字节未变。前后哈希清单为 `/tmp/travelcat-before-discovery-build35.json` 和 `/tmp/travelcat-after-discovery-build35.json`。

- 35 号从安装位置启动后，小屋截图正常；用户展开唯一邮筒，正式浮窗显示“暂无新消息”。从该浮窗进入 Agent 工作台，点“添加”实际显示 Codex 当前用户进程 1、已安装的 Claude Code、未发现 DSH、本机 Colima 可用、默认 Docker 不可用及固定摘要的 Codex ACP 候选。选择候选并点击兼容性检查后，正式界面显示 ACP 握手与容器清理确认，短表单出现；取消后仍为 0 个实例、0 个任务。只读 Docker `ps` 确认未留运行容器。
- 35 号运行进程指向 `/Users/nebulae/Applications/Travel Cat.app/Contents/MacOS/TravelCatApp`。安装时 76 个旅行数据文件及 `data-location.json` 字节未变；启动后只有 `state/automatic-travel.json` 随应用运行改变，未回退，其他文件与安装后快照一致。

## 验证边界

验收时旧的 `AgentWorkbenchPreview` 离线夹具曾造成第二个浮动邮筒及固定未读提示；用户退出预览后确认桌面只剩正式邮筒。`dist` 临时包装产物已按仓库要求移除；最终上传审计和 `git diff --check` 均通过。

这次兼容性检查仅证明选定镜像的 ACP 初始化、会话创建和容器清理；不证明现有 CLI 会话可接管、云端模型可调用、或 Claude/DSH 的具体镜像已兼容。正式界面没有保存用户 API Key，也未发起真实任务。未提交、推送或发布远端版本。
