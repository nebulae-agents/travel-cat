# AgentX 应用图标

2026-10-31 用户选择设计目录 `icon/AgentX-Icon-v3/A-deep-nebula` 的深色星云版。

- `AgentX.icns`：Finder / Dock 使用的正式 macOS 图标，由原始 PNG 尺寸直接封装，无重绘或裁剪。
- `agentx-icon.svg`：原始矢量素材副本。
- `preview.png`：原始 256px 预览副本。

生成方式：将原目录的 16、32、64、128、256、512、1024px PNG 按 Apple iconset 约定命名，使用系统 `iconutil --convert icns` 封装。iconset 点尺寸为 16、32、128、256、512，各包含 1x / 2x；重复像素尺寸复用同一原始 PNG。

`packaging/Info.plist` 的 `CFBundleIconFile` 指向 `AgentX.icns`；`scripts/package-app.sh` 在签名前将其复制到应用 `Contents/Resources/` 并验证存在。原设计目录未改动。此项只更换应用图标，保留现有应用名、标识、旅行角色素材和用户数据。
