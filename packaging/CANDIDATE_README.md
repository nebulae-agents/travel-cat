# Travel Cat App-only 开发候选包

这是供受控验收使用的桌面候选，不是正式迁移或公开发行声明。

## 内容

- `Travel Cat.app`：自有桌面小猫、相册、设置、测试和原始角色资源；临时签名，尚未 Apple 公证。
- `INSTALLATION.md`、许可证及第三方声明：安装边界和许可状态。

不附带外置 Codex 插件、默认宠物目录或宠物安装脚本。

源码提交：`{source_commit}`

实际可执行文件信息：`{architecture}`

## 安全与未完成项

先阅读 `INSTALLATION.md`。不要覆盖已有应用、移动相册、关闭 Gatekeeper、移除 quarantine 或重置系统权限。旧部署向导仍会管理 Codex 宠物，不用于本轮候选。

桌面和已有相册独立于 Codex 窗口；生产内置调度、Runtime 切换和 ACP 尚未完成。真实生成测试仍需要已授权的 CLI，不代表正式后台旅行已迁移。

本包不声称通过另一账户安装、完整生产生成迁移、Apple 公证或正式二进制发行验收。旧插件与 heartbeat 不会自动停用。代码、文档和自有项目素材使用 Apache-2.0，见 LICENSE 与 NOTICE；第三方字体保留 OFL 许可。
