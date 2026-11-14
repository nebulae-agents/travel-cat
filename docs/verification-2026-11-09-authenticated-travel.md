# 隔离登录后的真实旅行生成验收

日期：2026-11-09。用户选择隔离登录并亲自完成官方授权；保留正式数据，不提交或推送。正式客户端没有替换，仍为 build55。

## 实际执行

使用本次新建临时登录环境，通过生产 `CodexTravelExecutor`、`CodexTravelContentGenerator`、`AutomaticTravelWorker` 和 `TravelRepository` 完成真实生成。未注入文字或图片替身，未使用正式旅行数据。测试时钟加速行程安排，但生成请求、图片文件及存储操作为真实执行。

XCTest `testRealNarrativePostcardPersistenceAndCancellation` 通过，耗时 376.118 秒：

- 4 次真实文字生成，形成 preparing、transit、exploring、postcardReady 四条事件。
- 1 次真实图片生成，同一明信片由 pendingImage 变为 ready，文字内容保持。
- 重新打开仓库后事件一致；读取图片并解码缩略图成功。
- 正常完成后 executor 停止确认；恢复不自动发起工作。
- 另发起受控长输出请求，2 秒后取消，返回 CancellationError；所属进程回收、shutdown 及停止确认通过。此项证明旅行 CLI 取消回收；官方活跃 turn 中断的独立证据见原生运行器报告。

日志及私有证据根：`/private/tmp/agentx-authenticated-jidovuzf`。日志 `travel-acceptance.log`；数据目录 `travel-data-6349B4E1-9194-4664-88A2-422102151E35`；结果 `acceptance-report.json`。登录凭据仅保存在本次临时配置及专用钥匙串记录，不写入仓库或报告。

## 独立回读与画面检查

另一次只读检查确认 4 条事件、1 条 ready 明信片，图片路径位于本次独立数据根。PNG 为 1536 × 1024，SHA-256：

`cd0f18f737694f0f3bbf498b0a8ce3573fcd86d76b992989c0daa1847e7a8d0b`

已实际查看生成画面：黑猫、紫色项圈和金色铃铛位于园林窗边，背景为水面与亭廊，无破图。回读报告 `travel-readback.json` 位于同一私有证据根。

## 验收工具修正与边界

复核发现原测试的 XCTest 断言失败后仍可能写出布尔值为 true 的报告，因此收紧为关键检查失败即抛错、停止写成功报告。本次真实运行本身 XCTest 整体为绿色；结论同时依赖完整测试结果和独立文件回读，不独立信任旧报告布尔值。

收紧后的测试已重新编译；未重复发送生成请求，认证 opt-in 项因此跳过，12 项历史存储回归通过，0 失败。日志 `final-checks.log`。不能将这次跳过描述为第二次真实生成通过。

本次覆盖一次从出发到明信片就绪的真实生成链路，不外推多轮稳定性、完整返家周期或正式客户端 UI 验收。原生 Codex 活跃 turn/重启恢复见[外部运行器记录](verification-2026-11-09-external-runners.md)。

正式受保护数据与上一轮基线核对：7 个根、7,554 文件，修改/新增/删除均为 0。没有暂存、提交、推送，也没有重新安装正式客户端。
