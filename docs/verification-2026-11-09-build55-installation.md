# AgentX A+B 正式客户端更新记录

用户明确授权：继续打包并安装正式客户端，保留全部现有数据，安装后验收；暂不提交、推送。

## 已核验准备

- 工作树：`/Users/nebulae/Source/Codex/.worktrees/TheJourneyOfAFrog/agentx-manager-install`，分支 `codex/agentx-manager-install`。
- 现场正式安装：`~/Applications/Travel Cat.app`，1.6.0/build 54，bundle ID `com.nebulae.travelcat`。本次保持版本号并递增为 build 55，区分 A 交互收敛与 B 停止治理增量。
- 私有证据目录：`/private/tmp/agentx-install-20261109`。AgentXManager、AgentXHost、TravelCat、TravelCatAgents 和 TravelPetData 候选/定位路径，共 7 个根、7,554 个文件初始 SHA-256 清单已保存。清单不放入仓库。
- 旧客户端备份：该证据目录 `Travel Cat.build54.backup.app`，严格签名校验通过；10,919 文件的内容与权限清单和原安装一致，树摘要 `02c4bb47e5546d4374d03bc45e4bd42406deaaa5ac9c2bef69132ddf3800074c`。
- 打包采用 `Scripts/package-app.sh`；安装采用现有 `Scripts/install-travel-cat-app.sh`，该脚本校验签名、保留数据位置与旧 bundle，失败回滚。

## 当前状态

正式候选已构建完成：`dist/Travel Cat.app`，1.6.0/build 55，严格深度签名验证通过；10,919 文件树摘要 `e308a6fdde4f70539a52a4c0e1acc8a919fe71abfee91910b1552acb86cc13c4`。包内 Node v22.22.2，Pi 本机 SSE 多模型历史与取消集成验证通过；打包/版本 XCTest 共 30 项、Pi Swift Testing 9 项通过，日志为私有证据目录 `package-tests.log`。

打包完成后再次核对数据：7,554 个文件与初始清单一致，修改/新增/删除均为 0。

正式客户端 CUA 两次读取报告 `screen capture failed -10005`，尚无法确认活动状态与正常退出；安装暂未执行，没有终止正式进程。等待用户将正式 Travel Cat 置前台并完成正常退出后继续。隔离本机替身验收不等于正式客户端验收。

## 正式安装完成

用户解锁并将正式客户端置前台后，主线程确认旅行等待随机出发、BlackCat 本地运行 0，并通过 CmdQ 正常退出。安装前独立进程检查未发现正式客户端或所属运行器残留。

- 现有安装脚本执行成功，正式路径仍为 `~/Applications/Travel Cat.app`，1.6.0/build 55。
- 启动前数据再次核对：7,554 文件与安装前完全一致，修改/新增/删除均为 0；数据未迁移或重设。
- 已安装 10,919 文件内容/权限清单与候选完全一致，树摘要 `e308a6fdde4f70539a52a4c0e1acc8a919fe71abfee91910b1552acb86cc13c4`；严格深度签名验证通过。
- 安装脚本保留旧 bundle；安装过程日志位于私有证据目录 `install.log`。
- 尚待主线程正式启动与原生验收；没有提交或推送。

## 正式客户端原生验收

主线程实际验收通过：桌宠启动；从菜单进入平台、前后台往返正常；治理详情在没有停止操作时显示未检查/无记录；CmdK 原三应用保留。Pi 验收助手旧历史回复、当前 deepseek-v4.1-flash 会话选择均保留，旧历史明确标注未保存配置快照。退出重启后再次进入平台，恢复原 Pi 应用、模型及历史。未发送新推理、未停用正式应用、未新建正式测试数据。

回读确认唯一正式实例 PID 43960，执行路径 ~/Applications/Travel Cat.app/Contents/MacOS/TravelCatApp，1.6.0/build 55；严格签名仍通过。

验收后仍为 7,554 文件，新增/删除均 0，仅 AgentXManager 的 agentx.yaml 与一条既有历史运行 JSON 字节摘要变化。该记录仍为 completed、保留响应、未读标志 false、无旧配置快照。保存平台选择会重编码运行记录，与本次操作相符；但初始仅有哈希，不能断言具体字段差异。未输出正文，其余受保护文件内容不变。

备份与私有清单保留；临时 dist 已按规则清理。未提交或推送。
