# 交付状态（2026-10-14）

截至本页检查时，PR #2–#6 已合入公开主干，本机已按用户授权更新到同一公开源码的 1.4.1/build 31。源码、自动测试和安装证据分别列出；原生界面、真实提供方与完整旅程仍有独立验收项。

## 公开源码与 GitHub 检查

- 公开主干：[87d9cca5586715c9c13f7eddab9ce74c32872b40](https://github.com/nebulae-agents/travel-cat/commit/87d9cca5586715c9c13f7eddab9ce74c32872b40)。[PR #2](https://github.com/nebulae-agents/travel-cat/pull/2)、[PR #3](https://github.com/nebulae-agents/travel-cat/pull/3)、[PR #4](https://github.com/nebulae-agents/travel-cat/pull/4)、[PR #5](https://github.com/nebulae-agents/travel-cat/pull/5)、[PR #6](https://github.com/nebulae-agents/travel-cat/pull/6) 均已合并。
- 五次合并后实际 main CI 均成功；最近一次是 [Source checks #38539450265](https://github.com/nebulae-agents/travel-cat/actions/runs/38539450265)，对应上述主干提交。该次完整检查为 1,271 项 XCTest（16 项跳过、0 失败）、36 项 Swift Testing 和 152 项 Python 源契约通过。
- [PR #7](https://github.com/nebulae-agents/travel-cat/pull/7) 是版本显示与 build 32 候选；检查时为开放待审阅，当前 GitHub Checks 均成功，但尚未合并或安装。本机已安装版本仍为 build 31。

CI 配置见[源码检查工作流](../.github/workflows/ci.yml)。离线检查清除真实生成、原生准备及其他显式验收开关；跳过项和测试结果不能解释为真实模型、所有系统权限或全部客户端流程已验收。

## 本机授权更新

本次更新从上述已提交的公开主干构建，安装版本为 **1.4.1/build 31**。部署检查已核对源码标识、严格 ad-hoc 签名、运行进程对应的已安装应用、签名辅助程序的只读 `journal` 返回、旧应用备份及部署收据。操作契约见[本地部署说明](local-deployment.md)。

更新前后对照时，**73 个正式数据文件、10 项相关只读偏好及数据位置保持不变**。这是该次更新检查的时点证据，后续正常运行仍可能写入旅行状态；不能据此保证未来数据永远不变。安装核对也不代替可见窗口操作或完整旅行验收。

## 已有源码能力

| 能力 | 支持范围与源码位置 |
| --- | --- |
| 自动旅行与图片任务调度 | 默认黑猫已有应用内控制器和工作器；开启自动旅行、完成服务配置，且已选择及当前旅程角色均为默认黑猫时启动。[应用接线](../Sources/TravelCatApp/TravelCatApp.swift)、[调度控制器](../Sources/TravelCatApp/AutomaticTravelController.swift)、[旅行工作器](../Sources/TravelCatApp/AutomaticTravelWorker.swift) |
| 文本与图片生成配置 | 可分别选择 Codex CLI 或 OpenAI-compatible 服务；相关密钥保存在系统钥匙串。[服务配置](../Sources/TravelCatApp/ServiceConfiguration.swift)、[配置控制器](../Sources/TravelCatApp/GenerationServiceController.swift)、[模型与连接界面](../Sources/TravelCatApp/GenerationSetupView.swift) |
| 角色导入与旅程冻结 | 已有角色存储、设置选择、旅程身份冻结与测试生成传递；本机已安装源码包含这些代码。[角色存储](../Sources/TravelStorage/CharacterProfileStore.swift)、[角色设置](../Sources/TravelCatApp/TravelCatSettingsView.swift)、[角色说明](characters.md) |

自定义角色的自动旅行暂未启用，自动图片处理限定默认黑猫；通用 Runtime 与 ACP 切换仍未完成。旧插件兼容代码仍保留，但旧 heartbeat 的实时启停、是否存在双执行者及调度迁移是否全部完成，本次均未核实。

## 验收边界

| 层面 | 2026-10-14 的证据与缺口 |
| --- | --- |
| 源码交付 | PR #2–#6 已合入上述公开主干；PR #7 仍为未合并候选。 |
| 自动测试 | 最近 main CI 的完整 Swift 与 Python 检查通过，保留 16 项 XCTest 跳过；历史失败与修复记录见[合并前记录](merge-readiness.md)。 |
| 本机安装 | 公开主干的 1.4.1/build 31 已授权更新，并完成上述部署核对。 |
| 原生客户端 | 合并前既有安装版的一张已读卡有卡面/按钮双向切换、busy 和结束画面证据；配置取消、保存重开、恢复副本及一次失败重试，翻面中点像素与系统“减少动态效果”仍待可见窗口验收。[交互验收记录](interaction-acceptance.md) |
| 真实提供方与角色生成 | 本次未以真实额度调用验收所有提供方；可见角色导入与自定义角色真实图片效果仍未验收。 |
| 多趟与长期运行 | 默认黑猫连续多趟旅行、睡眠唤醒及长期调度稳定性仍需真实运行证据。 |
| 跨账户 | 另一账户下的实际安装、兼容插件链路和真实生成仍未验收。 |
| 公开二进制发行 | 当前为临时签名开发版，尚无 Developer ID 签名或 Apple 公证；干净环境安装与完整发行验收仍未完成。[候选版发行记录](release-status.md) |

[1.3.0 历史记录](release-status.md)、[合并前工程记录](merge-readiness.md)和[原始结构化交互记录](interaction-acceptance.json)继续保留各自时点的测试、失败和未安装状态；它们不覆盖本页所记录的后续合并与授权更新。
