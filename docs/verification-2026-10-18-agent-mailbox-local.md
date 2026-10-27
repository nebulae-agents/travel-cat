# Agent 邮筒本机安装验收（2026-10-18）

本地集成以公开版 `df9ae3a157c8cc7fead078e646be74e30f2a6747` 为基线，将 Agent 工作台、独立邮筒、统一明信片入口及相关资源接入现有 `DesktopPetController`。源码保存在本地分支 `codex/agent-mailbox-install`；公开版 `main` 未修改，未提交或推送。

安装包为 `com.nebulae.travelcat` 1.4.1 build 32，经过 `codesign --verify --deep --strict`。安装前，包内 `TravelCatApp` 的 SHA-256 为 `527ee058933e9ab8f2b50eecb140880b2f87e8a5d6c5f9900167909ffc6219a0`，邮筒资源为 `22fcc2449118a0f0b85aa77d7b8dccf825c3bb5ee8a80b306dd64f888a3a15ae`。安装后的两个文件哈希一致，整个安装包与 `/Users/nebulae/Applications/Travel Cat.app` 的目录比较一致；旧应用保留在 `/Users/nebulae/Applications/.Travel Cat.app.backup.20261018T113857Z.81361`。当前运行进程来自正式安装路径。安装验证后已移除临时 `dist`。

集成候选执行完整 Swift 测试：1340 项 XCTest、16 项跳过、0 失败，另有 36 项 Swift Testing 通过；Agent Runtime Python 测试 74/74 通过。调整 macOS bundle 的 `Contents/Resources` 检查后，打包合同测试 23/23 通过。打包、签名验证、上传审计与 `git diff --check` 通过。独立公开版工作区的 49 个变更源文件与测试候选逐字节一致，审计状态为 `ok`。

安装前后，旅行数据目录的 76 个文件及位置偏好哈希一致。首次启动后这 76 个文件仍完全一致，位置偏好仍一致；应用自身的 `com.nebulae.travelcat.plist` 在启动后发生常规偏好写入。正式应用已打开原有旅程，小屋与旅程窗口工作正常，且没有打开未读明信片或启动 Agent 任务。

正式版和离线预览一度同时运行，用户无法区分两个桌宠。随后通过离线预览自己的“退出预览”菜单关闭预览，并核对进程：只剩 `/Users/nebulae/Applications/Travel Cat.app/Contents/MacOS/TravelCatApp`。正式版小屋仍可见；用户随后确认“看得到且能展开”小屋旁的邮筒，并从邮筒列表打开“Agent 工作台”。桌面验收工具也读到了正式应用的“Agent 工作台”窗口、新任务输入区、添加实例入口和待确认 0 的空状态；截图显示奶油色的小屋风格界面。未发起任务、修改模型权限或打开未读明信片。工作台打开后再次核对，76 个既有旅行数据文件及数据位置偏好仍与安装前一致，且仍只有一个正式版桌宠进程。

离线预览中的邮筒拖动、展开列表及明信片从 3 条变为 2 条已单独验收；它不能替代本机安装版其余交互结论。安装版已验收小屋、邮筒展开及工作台入口；真实 Agent Runtime、安装版的未读明信片、跨屏移动和远端发布均不在本次证据内。

续验收：只读核对正式 `journal/events.jsonl` 与当前数据根作用域的已读偏好，抵达事件中未读明信片数量为 0。因此没有通过生成新旅程或改写已读状态来制造安装版邮筒提示。改从旅行册打开一张明确标为“已读”的历史明信片；正式安装版显示完整风景图片，翻到文字面后返回旅行册。随后 76 个旅行数据文件与数据位置偏好仍逐文件一致。此项证明历史图片资源和翻面流程正常，不证明安装版“未读提示→阅读后消失”。

安装版邮筒拖动续验：用户在正式应用中将邮筒图标拖至小屋另一侧，随后移动小屋，确认邮筒随小屋移动且保留相对位置。拖动前后同一正式应用进程持续运行；相对位置偏好由 `[-27.5859375, 51.74609375]` 更新为 `[146.46484375, 61.21875]`。复核旅行数据目录的 76 个文件和数据位置偏好，均与安装前一致。此项为本机手动交互反馈加偏好读回，不等同于跨屏边界验收。

首次真实环境只读预检时，本机有 Codex CLI 0.158.0、Claude Code 2.1.205、Colima 0.10.1 与 Lima；Docker CLI 存在，但服务端未运行，Colima 没有现成 profile。项目原有 Dockerfile 只是基础配方，并非可直接运行的完整 Agent 镜像。该时点未创建容器 profile、拉取镜像、登录服务或提交实际任务；后续隔离续验见下节。

## Colima 本机隔离续验（同日）

用户选择本机 Colima 独立环境后，创建 `travelcat-agent` profile（2 CPU、2 GiB 内存、8 GiB 磁盘、不挂载宿主目录、不激活为默认 context）。`docker context ls` 仍显示 `default` 为当前 context；显式使用 `colima-travelcat-agent` 可访问 Docker 29.2.1，初始镜像列表为空。用官方 Python arm64 镜像摘要 `sha256:a4ccdf11e73bd3f74e07f95e63f1b003467bb16cb77e942ddf45476c2cb8467c` 的测试 ACP 实现完成真实容器握手、单回合及清理；`docker inspect` 读回非 root、只读根、禁网、无宿主挂载、丢弃全部 capabilities、禁止提权、1 GiB 内存和 128 进程限制。此测试实现只验证运行器，不代表正式 Agent 兼容。

随后按[官方 Codex ACP 项目](https://github.com/agentclientprotocol/codex-acp)的 2.2.2 版本构建独立镜像；Node arm64 基础镜像使用 `sha256:b20fe038d9592822dd534600a1ddf467e985178aa3fed60ec441a056c2cc45bd`，npm lockfile 固定依赖，镜像内 Python 为 3.11.2。最终仅本机回环仓库的镜像引用为 `localhost:5000/travelcat-codex-acp@sha256:9e1ac8187c77450bb885f269cf82464aea77fff820fd798a6b1bd8012b838bce`；配方与 lockfile 保存于 `packaging/agent-runtime/codex-acp`。镜像显式使用容器回环中继、占位 API key，按[Codex 配置说明](https://learn.chatgpt.com/docs/config-file/config-reference)关闭托管网页搜索；没有打包或使用真实模型凭据。

正式适配器在产品原运行器里完成 ACP `initialize`、`session/new` 与本地 `/status` 回合。普通模型提示曾在许可门前被拒绝：运行器把 Codex 函数工具**参数 JSON Schema**里的 `audio_url`、`image_url` 字段名误认作实际外部内容引用。新增针对性测试先复现失败，再只跳过顶层 `tools` 声明中的 `parameters` schema；实际 `input` 中的外部链接（包括嵌在 `parameters` 内）及托管网页搜索仍被拒绝。Agent Runtime 完整 Python 测试现为 75/75 通过。

修复后，以官方适配器发起普通提示，测试宿主只记录安全类别并在模型许可门明确拒绝：观察到 `model.request → model.decision → model.failed`，许可事件 `modelApproval` 到达，容器被确认清理。测试的上游函数硬性禁止网络提交，未调用真实模型；本机内存审计替身不能替代正式加密审计写入。正式模型响应、付费调用、安装版真实任务及容器重启恢复仍未验收。

已打包签名 1.4.1 build 33，包内 `sidecar.py` 与修复后源文件逐字节一致，邮筒素材也一致；打包合同专项 23/23 通过。临时回环 Registry 容器已停止并删除；关闭后原运行器仍能按最终摘要启动本地镜像，完成 ACP 握手和 `/status`，并确认清理。安装与桌面复验需先退出正在运行的 build 32；Mac 锁屏期间未替换运行中的应用。原记录中的 build 32 安装验收仍有效，但不包含这次运行器修复。

进一步从 build 33 安装包内的原样 `sidecar.py` 启动完整控制协议，测试宿主将每条审计记录写入仅测试使用的本机文件并 `fsync` 后才回执。固定摘要 Codex ACP 容器成功启动，模型请求产生一次审批；测试宿主拒绝，审计顺序为 `operation.start → model.request → model.decision → model.failed → operation.stop`，回合返回且 `stop` 确认清理。提供方地址设为 `https://127.0.0.1/v1`，密钥为无效占位值，所以没有任何外部模型提交。此测试覆盖包内 Python 审计回执协议与真实容器，不覆盖正式 Swift 加密审计存储或正式客户端 UI。

## build 33 本机安装续验（2026-10-19）

解锁后再次核对待安装包时，严格签名验证发现 `AgentRuntime/__pycache__` 中 3 个 `.pyc` 与签名封存值不符。原因是此前直接从已签名包运行 Python 离线检查，导入模块时写回了字节码缓存；不涉及正式应用或旅行数据。打包脚本现于签名前清理暂存 `AgentRuntime` 的 `.pyc` 和空缓存目录，源码中的生成缓存也已清除。打包合同测试 23/23 通过；重新打出的包无 `.pyc`，严格签名验证通过。以后对签名包运行 Python 验证须使用 `-B` 或 `PYTHONDONTWRITEBYTECODE=1`；正式 Swift 子进程原本已使用 `-B`。

通过正式应用菜单正常退出 build 32，确认原进程消失后，用仓库安装器安装签名的 build 33。旧应用保留在 `/Users/nebulae/Applications/.Travel Cat.app.backup.20261019T020149Z.12894`。安装版为 `com.nebulae.travelcat` 1.4.1 build 33，主程序 SHA-256 为 `920e5bdb7bc65b951f8b6d2d239c862f3c93eae39a572e2110cac8475eb4d478`；安装包与正式路径逐文件比较一致，安装后签名复核有效。安装前后当前旅行数据 76 个文件、6 项偏好快照完全一致。相较前一天的旧基线，`automatic-travel.json` 曾由应用正常后台旅程更新；因此本次以安装前的即时快照比较，未把自然推进误判为安装改动。

桌面验收工具启动正式版后读到小屋和旅程状态窗口；正式进程来自 `/Users/nebulae/Applications/Travel Cat.app/Contents/MacOS/TravelCatApp`，运行一分钟后签名和包体仍一致。启动后的 76 个旅行数据文件及 6 项偏好仍与安装前即时快照一致。未打开未读明信片、发起 Agent 任务或输入真实模型凭据。本机独立 Colima profile 仍在运行。用户在正式 build 33 桌面确认小屋旁邮筒可见且点击能展开；此项是本机人工交互反馈。用户又从已展开邮筒进入 build 33 的“Agent 工作台”；桌面验收工具在正式进程中读到“新任务”、实例列表、待确认 0、输入框和数据审计入口。由工作台的运行环境页输入 `colima-travelcat-agent` 后执行只读发现，正式 UI 回显“Docker available; images require adapter compatibility checks”及本机固定摘要的 `travelcat-codex-acp` 镜像。未创建实例、提交任务或输入真实凭据。安装包比对完成后已按仓库规则移除临时 `dist`，最终上传审计 `status=ok`、`git diff --check` 通过。

运行数分钟后，正式应用主程序仍来自安装路径，严格签名复核有效。安装前即时基线与刚启动后快照的 76 个旅行文件、6 项偏好完全一致；此后在桌面验收期间，只有 `automatic-travel.json` 随后台旅程自然推进，其他 75 个旅行文件及全部 6 项偏好不变。当前不把这种应用正常运行造成的写入归因于安装器。安装版的真实 Agent 模型提交、正式加密审计回执及未读明信片提示消失仍未验收。
