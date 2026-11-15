# agentxd 服务端审计

2026-11-15 本地实现。服务的 run 生命周期通过受限 Swift helper 复用 `AgentAuditStore` 的加密记录和哈希链；密钥留在既有 Keychain 服务，Python 不读取或导出密钥。目录锁串行化参与此协议的进程，密钥创建使用独立锁。此机制不抵御控制同一账户或宿主的攻击者，不宣称不可篡改。

## 启动和查询

在隔离试点根使用已有启动命令；`--pi-bundle` 默认选用该包 `CFBundleExecutable` 对应的可执行文件作为 helper。包必须包含本轮 helper，否则新运行以 `audit_unavailable` 拒绝。开发构建可用 `--audit-helper /absolute/path/to/TravelCatApp` 指定已构建的新版 Swift 可执行文件，仍使用原 Pi bundle 的运行时。helper 路径须为无软链接、当前用户或 root 所有、非组/其他用户可写的普通可执行文件。

```sh
python3 Runtime/agentxd.py --root /absolute/private/pilot-root --pi-bundle /absolute/TravelCat.app --audit-helper /absolute/TravelCatApp
Scripts/agentx --root /absolute/private/pilot-root run audit --app pilot --run RUN_UUID
```

认证接口：`GET /v1/apps/<app>/runs/<run>/audit`。返回同一 run 的元数据、`auditStatus`、`verified` 和当前保留链的记录数。无认证为 401，桥接或链校验失败为 503。`verified` 仅表示当前链校验通过；`pending` 仍表示有事件尚未确认，不能解释为完整审计。历史没有本轮 outbox 时为 `legacy`，不补造历史事件。正常保留策略可清理旧记录，查询不是永久历史保证。

## 写入与恢复

1. 创建时保存 run 及不可变的开始事件，事件身份由 run UUID 和生命周期阶段确定；仅包含 app/instance/provider/model、时间、状态、请求/回复字节数，不包含正文、凭据或异常原文。
2. Swift 幂等追加并校验链后，run 保存确认位置及新修订（`auditConfirmed`）。若追加成功、确认写入失败，重启重试相同事件；不同内容的相同 ID 被拒绝。已确认事件不会因后续追加重新插回，避免绕过正常保留策略。
3. 开始审计失败时不启动 Pi，保存 failed 和 pending；存在待补写事件时禁止新运行。重启或尝试创建新运行时重试待写事件；不自动重发模型请求。
4. 取消先尝试保存意图，在 finally 发出停止信号，再尝试审计桥接。即使 run 文件写入失败，停止信号仍发出，但调用报错，不伪造持久化成功。
5. 终态先保存结果和审计 outbox，再尝试写链。失败时保留真实终态及 `auditFailure`，供现有桌面告警和 CLI 读取；不把已完成模型结果改成成功审计。若 run 文件本身无法持久化，现有恢复路径仍只能报告进程退出未确认，不保证恢复内存中尚未落盘的结果。

run 文件通过文件 fsync、原子替换和目录 fsync 写入；与审计链是两份存储，通过 outbox 协调，不宣称跨文件事务。helper stdin 上限 16 KiB、stdout 上限 4 MiB；Swift 输入等待上限 10 秒，Python 单次调用上限 12 秒，错误统一脱敏。一次恢复可能涉及多条记录，仍需后续规模基准。

## 验证范围

- Python：生命周期、重复提交、开始失败门禁、取消时日志/磁盘失败、终态待补写、追加成功后确认失败、恢复去重、保留策略、HTTP 认证与 CLI 同一运行回读、桥接超时与输出上限。
- Swift：临时 root + 内存凭据，验证加密、元数据白名单、字段类型、身份/路径拒绝、重复冲突、链损坏及跨 store 锁竞争；原审计生命周期/模型测试回归。
- 本轮没有访问真实模型，没有安装或启动原生 GUI，没有真实 Keychain 的 Python→Swift 组合验收；自动测试结果不能替代这些验收。原有真实 Pi/桌面验收仅作为历史基线，不代表本轮新版已验收。

阶段计划见 [v1 里程碑](agentx-v1-milestones.md)。

## 本轮自动验证结果

2026-11-15，基线 `cec786738e304ba21906c2a195a27b94e45d8546` 加本地未提交改动：Python 3.13 + websockets 15.0.1 的完整 Runtime 测试 272 项通过；CLI 测试 3 项通过；Swift 审计相关 XCTest 23 项通过。独立静态审查发现的幂等重试缺少目录同步确认已用故障注入测试复现并修复，复核通过。`git diff --check` 与上传审计通过。

早期系统 Python 3.9 执行因项目要求 3.11 以上而失败；便携 Python 3.12 缺依赖且 venv 创建异常。最终使用临时 Python 3.13 虚拟环境完成验证，未修改系统 Python。该结果不等于全量 Swift、真实 Keychain 或客户端组合验收。
