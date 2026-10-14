# 隔离原生恢复验收夹具

此目录和 `NativeRecoveryAcceptanceFixtureTests` 只准备合成验收环境，不代表原生交互已经通过。常规测试跳过数据准备；主动运行必须使用全新的 `/tmp/travelcat-native-acceptance-*` 根目录。

1. 启动短生命周期回环服务，`--root` 必须为全新的 `/tmp/travelcat-native-http-*` 目录：

   ```sh
   python3 Tests/Fixtures/NativeRecoveryAcceptance/loopback_server.py --root /tmp/travelcat-native-http-example
   ```

   从该目录的 `ready.json` 读取随机端口。服务只监听 `127.0.0.1`，20 分钟后自行结束；记录请求元数据，不记录正文或凭据。

2. 将端口和新根目录传给夹具。若同时运行真实生成，可设置独立的 `TRAVEL_CAT_SCRATCH_ROOT`，避免 SwiftPM 缓存锁等待：

   ```sh
   TRAVEL_CAT_NATIVE_ACCEPTANCE_ROOT=/tmp/travelcat-native-acceptance-example \
   TRAVEL_CAT_NATIVE_ACCEPTANCE_PORT=上述端口 \
   Scripts/travel-cat-swift.sh test --filter NativeRecoveryAcceptanceFixtureTests
   ```

   夹具通过实际仓库创建历史日志、未来旅程快照、版本 4 待补卡、安全副本与旧租约，然后仅损坏临时根内的主补卡文件。配置使用本机 OpenAI 兼容服务、新凭据标识和手动虚构家乡；不填入密钥，不启用 IP 定位。

3. 复制当前安装应用到临时目录，只在副本中设置独立应用 ID（不要属于 `com.nebulae.travelcat` 家族）及 `TravelCatDataRoot`。`TRAVEL_CAT_DATA` 优先于 Info.plist：启动前必须确认变量为空或受控指定为已验证的隔离根，无法确认时不得启动验收副本。应用启动已运行恢复与自动旅行控制器，不能等按钮操作前才确认。重新签名并严格验证；比较主程序文件映射节内容，签名字节会更新。确认环境后通过原生工具启动副本，再核对实际隔离根及正式根基线。

   可使用 `acceptance_launcher.c` 编译测试副本的启动器。编译宏 `ACCEPTANCE_ROOT` 必须是规范化的 `/private/tmp/travelcat-native-acceptance-*` 根，`ACCEPTANCE_EXECUTABLE` 是副本中的应用可执行文件绝对路径。两个宏均为 C 字符串；用参数数组传给 clang，避免 shell 插值。将启动器设为副本的 `CFBundleExecutable` 后，启动器会在执行应用代码前强制覆盖环境变量，并拒绝链接、非目录、非当前用户或非 0700 的根。`launch-proof.jsonl` 使用非阻塞写入及链接、类型、权限、硬链接检查；无写入能力时拒绝启动。

   启动证明还需结合相同 PID 的实际执行路径，以及该进程实际打开的隔离数据文件核对。它单独不能证明应用已成功执行。若仅为工具选择而在副本中设置 `LSUIElement=false`，须记录呈现模式差异，不能把它等同于正式菜单栏模式的完整验收。

4. 在“模型与连接”中勾选两个“此服务无需密钥”。第一次文字请求等待响应，关闭窗口应产生 `cancelled-peer-closed`；重开后第二次文字请求应成功，再保存并重开核对配置。图片请求固定返回 503。

5. 在设置中点击安全副本恢复，检查自动旅行暂停、界面刷新、损坏字节保留及日志/快照保留。核对恢复后的 `activeAttemptToken`、`leaseExpiresAt` 均清空，恢复源仍保留原 token。若重放旧结果证明拒绝，须在保存的租约到期前执行；日常租约仅一小时，到期后的拒绝不计入恢复撤销证据。点击一次手动图片重试，确认收到失败后停止，且只有一条图片请求。

6. 结束验收副本；向本机服务 `POST /__stop` 可提前结束服务。核对正式数据及用户偏好仍与基线一致。

原生步骤的当前证据边界见 `docs/interaction-acceptance.md`。数据准备、回环请求及启动器验证与原生按钮验收分别记录；租约到期后应重新准备新夹具。
