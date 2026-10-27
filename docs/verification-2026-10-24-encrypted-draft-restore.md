# 未发送草稿跨重启加密恢复：本机核验

日期：2026-10-24。范围：本次独立代码变更及本机自动核验；未合并、未正式安装，未操作真实账号、凭据或用户数据。

## 实际行为与保存范围

- 草稿由 `AgentWorkbenchModel` 持有，作为 schema 1 的可选 `WorkbenchSnapshot.drafts` 字段保存，复用既有 `workbench.sealed` AES-GCM、原存储密钥与原子密文写入机制。没有新增 UserDefaults、明文草稿文件、明文临时备份或替代密钥。
- 每个 Agent 的新会话、每个任务的追问以及未选择 Agent 的新会话分别拥有独立目标。保存正文、原始 base64 文件内容、父任务 ID 与 revision。不会保存或恢复模型上传同意、审批状态或自动发送意图。
- 界面只通过模型读取与修改草稿。切换任务或重新创建界面对象不会新建第二份草稿来源；新会话的 Agent 选择器提供“未选择 Agent · 独立草稿”入口，原先未选择 Agent 时输入的内容不会被隐式迁移。
- 草稿修改使用独立 250 ms 防抖，不会被连续运行事件重置计时。正常 `shutdown()` 在存储关闭标记之前同步保存最新状态；之后的授权结果与运行事件不能再覆盖存储。
- 保存失败时，当前内存草稿保留，并显示本次运行尚未保存的提示与“重试保存”。输入无效、密钥校验失败、无效历史内容等失败路径不替换旧密文。修正内容或恢复可用存储后可重试。
- Agent 尚有非空新会话草稿时，删除入口会拒绝删除并说明原因。交接资料也使用同一模型草稿来源。承接关系显示为可见来源标记及“移除承接来源”按钮；该按钮只清除 parentTaskID，保留原正文与文件并更新 revision。清空正文和文件后可显式移除来源，解除删除阻塞；不会静默丢弃来源元数据。

## 提交与清理口径

- ACP 的 `start` 返回有效 session ID 仅确认会话建立，不能清理草稿；必须等现有 `prompt` 请求成功返回。这一接口目前在整轮调用返回时才提供确认，所以草稿等待时间可能覆盖整轮回复。
- 原生 Codex 在 `native_prompt` 返回有效非空白 turn ID 后确认接收，无需等待模型回答结束。空缺或空白回执、传输失败及未知状态都保留草稿，不自动重发。
- 只有原目标的已提交 revision 可以被清除；等待期间编辑，甚至将正文改回旧值，也保留新 revision。正在确认的同一目标、同一 revision 不能重复提交；另一个目标和新 revision 独立保留。
- 追问当前不上传输入文件。若恢复出的追问草稿含文件，会明确拒绝提交并保留附件，避免只发正文后清掉未上传的文件。所有草稿的文件菜单均可显示和清除已选文件。

## 严格验证

保存和加载均验证：正文不超过 100,000 个 Swift 字符且 UTF-8 不超过 512 KiB；最多 32 个文件，每个解码后不超过 1 MiB、合计不超过 4 MiB；严格 base64；文件名不超过 200 UTF-8 字节，拒绝空名称、路径、NUL/控制字符、重复名称与既有 runtime 禁止的隐藏名、凭据类名称和扩展名；单 snapshot 仍不超过 64 MiB。

不截断正文、不清空非法附件、不静默去重。重复目标、未知目标类型、缺少任务目标 ID、非法旧明文草稿及经有效密钥认证但内容非法的密文都会阻止加载和覆盖。旧 schema 1 且不含 drafts 字段的文件继续兼容。原历史消息、原任务身份与附件字节不因草稿恢复而被改写。

## RED / GREEN 记录

| 阶段 | 命令筛选 | 实际结果 |
| --- | --- | --- |
| 存储 RED | `AgentDraftStorageTests` | 5 tests，38 failures；其中 1 个 unexpected 是旧实现迁移并删除非法原文件后，测试读取受保护原文件失败。确认了缺失草稿字段、非法输入未拒绝和原文件被迁移的问题。 |
| 存储 GREEN | `AgentDraftStorageTests` | 5 tests，0 failures。 |
| 提交确认 RED | `AgentWorkbenchSubmissionTests.test(Acknowledgement\|PromptTransport)` | 2 tests，2 failures，0 unexpected；会话确认时过早清理及 prompt 失败仍确认均复现。 |
| 自审边界 RED | `testFollowUpCannotSilently\|testUnknownNativeTurn` | 2 tests，5 failures，0 unexpected；未上传附件被清理及空白 turn 回执误确认均复现。 |
| 承接来源入口 RED | `testHandoffSourceHasVisibleExplicitRemovalControl` | 1 test，3 failures，0 unexpected；先复现缺少可见来源及移除入口。 |
| 承接来源生命周期 RED | `testClearedHandoff\|testRemovingHandoff` | 为新动作提供空实现以编译测试，2 tests，11 failures，0 unexpected；复现清空后仍阻止删除、加密重开仍有来源，以及旧 revision 可误清后续内容。 |
| 最终相关 Swift | 下列完整筛选 | 178 tests，0 failures，0 unexpected，退出码 0。 |
| runtime 文件规则 | `test_workspace.py` | 5 tests，OK，退出码 0。 |

最终 Swift：

```sh
Scripts/travel-cat-swift.sh test --filter 'AgentDraft|AgentWorkbench|EncryptedWorkbenchStoreTests|AgentSecureStorageModelTests|NativeAgentModelTests|TravelCatAppSourceContractTests'
```

其中包括草稿恢复 16 项、草稿存储 7 项、既有安全存储 5 项、工作台导航 7 项、界面状态组织 9 项、授权恢复 11 项、提交 13 项、加密存储 9 项、原生模型 56 项、工作台基础 11 项、应用源契约 34 项。测试包含已知测试密钥加密重开、多个独立目标及原文件字节、立即退出、运行事件期间防抖、失败保存保留旧密文、恢复前编辑阻断、成功/未知提交及新 revision 保护。承接来源修复另覆盖清空正文/文件后显式移除、加密重开后删除成功且再次重开无幽灵草稿、原来源消息保留，以及非空正文或文件仍保护删除和旧回执不能清新 revision。源码契约测试只检查可见操作接线，不代表实际界面已验收。所有测试均使用隔离临时目录和测试凭据。

文件规则：

```sh
PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 -m unittest discover -s Tests/AgentRuntimeTests -p test_workspace.py
```

## 限制与待验收

- 强制结束进程、崩溃或断电发生在 250 ms 防抖落盘之前时，最近修改不保证恢复。正常退出同步保存只有在存储操作成功时才能提供恢复；磁盘不可写、密钥不可用、内容无效等错误不保证跨重启恢复本次内存内容。
- 接收确认与清除草稿是两个操作。进程在运行时已接收、草稿清理尚未落盘之间异常退出时，重开后可能仍看见旧草稿；恢复绝不自动重发，用户应先核对原会话。
- 本次未注入磁盘 rename 之后目录同步失败等系统级故障；旧密文不变的验证覆盖了输入验证失败、临时目录不可写、错误密钥校验与非法现有密文阻止保存的路径，不能扩展为任意硬件故障的事务保证。
- 本机屏幕锁定，未使用 UI 自动化。真实窗口中的新建/追问、切换 Agent 与任务、未选择 Agent 草稿入口、交接、承接来源标记与移除按钮、关闭重开、保存失败提示及重试仍待界面验收。应用源码已通过编译，显式预览源列表已补齐并静态校验，但本项没有启动预览窗口，也没有正式安装。
