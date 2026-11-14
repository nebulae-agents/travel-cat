# build56 正式安装与历史保存优化验收

日期：2026-11-09。用户明确授权打包安装、保留现有数据、安装后验收；不提交或推送。

## 安装结果

正式路径：`/Users/nebulae/Applications/Travel Cat.app`，版本 **1.6.0 / build56**。包含 AgentXRepository 未变化历史运行记录不重写的优化。

- 30 项历史存储、基础 AgentX 与打包相关 XCTest 通过。
- 使用项目包装脚本构建，候选与正式安装均通过严格深度签名检查。
- 10,919 个文件的内容及权限清单与候选包完全一致。树摘要：`092cb649df357c8026e5f346119da14ed4736633e108b0c5d9c5ef27c84329bc`。
- 真实打包应用在隔离离线环境通过资源复制、pending→ready、图片回读；6 项缺资源拒绝、3 项错误参数拒绝及脱离应用包拒绝通过。该项使用离线生成替身，不冒称新一次付费生成验收。
- 旧正式应用保留在 `/Users/nebulae/Applications/.Travel Cat.app.backup.20261109T054924Z.97525`。

## 数据保护

旧客户端正常退出后，对 7 个受保护根目录的 7,554 个文件建立内容与修改时间清单，并完成逐文件 SHA-256 核对的数据备份。备份和清单位于 `/private/tmp/agentx-install-build56`，不放入仓库。

安装后、启动前：内容、修改时间、新增、删除均为 **0 变化**。

正式交互与重启验收后：

- 7,554 文件内容全部不变；新增、删除均为 0。
- 唯一既有 AgentX 历史运行文件的原始字节、修改时间、JSON 解码内容全部不变。
- 10 个非运行记录文件修改时间刷新，内容未变：7 个 YAML、2 个定义 Markdown、1 个旅行调度状态 JSON。此次优化只减少无关历史 run 重写，不宣称其他配置完全不再写入。

## 正式客户端验收

实际启动并观察 build56 的桌宠与 AgentX 窗口；已有 BlackCat、工作台、Pi 连接验收三应用保留。

- Pi 原历史回复仍可见，历史模型 openai/gpt-4o-mini 与当前会话 deepseek/deepseek-v4.1-flash 保留；旧记录无配置快照的说明保持准确。
- 前后台往返正常；CmdK 应用切换、切至工作台后读取原只读历史、返回 Pi 正常。
- 已检查正式窗口截图，内容与布局正常。
- CmdQ 正常退出，再启动并打开平台，恢复 Pi 应用及同一模型、历史内容。
- 回读正式进程 PID 98777，执行路径指向已安装应用；没有启动新的正式推理、停用或卸载应用。

屏幕读取最初失败，后恢复正常并完成上述原生交互；不将最初失败当作完成证据。

## 证据与边界

私有证据目录包含 tests.log、package.log、packaged-acceptance.json、install.log、candidate.json、installed.json、before.json、after-install.json、after-navigation.json、after-restart.json、final-data-summary.json 与完整数据备份。历史文件已分别在页面切换后和重启后验证不变。

此前真实外部运行器及认证旅行生成见对应验收记录；本次正式升级未重复付费推理。一次安装回归不外推长期稳定性。

临时 dist 在安装验证后清理。未暂存、提交或推送。
