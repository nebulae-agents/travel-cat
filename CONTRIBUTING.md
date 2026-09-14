# 贡献说明

代码、文档和自有项目素材使用 [Apache-2.0](LICENSE)。请仅提交你有权贡献的内容；有意提交并纳入项目的贡献适用该许可证，除非另有明确约定。第三方字体继续遵守原有 OFL，请保留其版权和许可声明。

## 开发与检查

使用 macOS 14+、支持 Swift 6.2 的工具链、Python 3.9+ 和 Node.js。Swift 构建缓存必须位于仓库外，使用项目包装入口：

```sh
Scripts/travel-cat-swift.sh test
python3 -m unittest discover -s Scripts/tests -p '*_tests.py'
Scripts/tests/project-upload-tools-tests.sh
Scripts/verify-travel-cat-plugin.sh
Scripts/verify-travel-cat-skill.sh
Scripts/verify-agent-contract.sh
Scripts/audit-project-upload.sh
```

Swift 相关命令依次运行，不要让多个进程争用同一缓存。新行为应有失败回归和修复后的通过证据；注明未执行的原生界面、权限、联网或真实生成验收，不能以模拟测试替代。

## 保留数据与原始资源

- `TravelPetData` 是用户状态，不删除、重置、移动或暂存；测试使用临时夹具。
- `.local/` 保存个人配置和部署备份，禁止提交。仓库只保留中性的 demo；不要填写作者路径或凭据。
- 保留 `Assets`、`Fixtures`、`Tests/Fixtures` 与 `Sources/TravelUI/Resources`。其中的 `.log`、`.out`、`.err` 可能是正式夹具，不能当作垃圾删除。
- 素材压缩、替换或重新授权需要单独验收，不借工程整理改变批准的视觉素材。字体 OFL 文件保持原始字节。
- `dist` 是可重建打包输出；安装验证后清理本次生成的输出，再执行最终上传审计。不要宽泛删除其他目录或旧交付包。

提交前检查差异并运行上传审计。大素材只接受[公开源码策略](docs/public-source-policy.md)中的明确路径、大小和摘要例外，不全局提高限制。工作树有无关修改时保留它们，不重置他人的工作。

## 提交与发布边界

使用独立分支，说明修改目的、验证结果和剩余限制。未提交修改不会被发布入口自动保存；先复核并提交，再运行 `Publish to GitHub.command`。发布入口只面向 github.com，拒绝异常远端、浅历史与已知私有历史路径；它不是替代人工复核的完整秘密扫描器。

本地部署从同一明确提交构建，不从旧开发副本复制产物。部署入口不负责插件缓存刷新，也不自动上传。禁止在 CI 中运行真实旅行生成、读取个人相册或安装到真实用户目录。
