# 旧卡图像提示历史基线

`historical-image-prompts.json` 保存 65 个合成事件的完整 API 图像提示、完整 Codex 图像工具提示，以及场景分类与构图。版本 1–3 每个版本覆盖七类场景和三种构图；另有无版本旧卡与未知版本 99 的回退样例。它是兼容性基线，不是模型照片质量样例，也不包含正式用户数据。

来源为已保存的 Git 历史：

| 提示版本 | 完整源提交 |
| --- | --- |
| 无版本、未知 99、版本 1 | `67b6db7b9b6e4809a59c1a5483918293cf81d521` |
| 版本 2、3 | `25c2258405e1f95324869aad2ac3b6d703404484` |

JSON 的 `baselines` 保存对应 `PostcardSceneStyle.swift`、`TravelGenerationPrompts.swift` 的 Git blob ID 和源码 SHA256。生成器从这些历史对象读取代码，在临时目录独立编译，只移除 `import TravelCore`，以只含图像函数实际读取字段的最小事件类型提供输入；不从当前生产代码生成期望。正式 XCTest 使用真实 `TripEvent` 和真实序列化。

普通测试只读固定文件，不访问 Git、网络、图片提供方，也不自动录制快照。运行：

```sh
Scripts/travel-cat-swift.sh test --filter TravelGenerationPromptSnapshotTests
```

需要核对来源时，在包含上述历史对象的 macOS/Xcode 工作区执行以下命令。重建器必须明确传入输出文件，且拒绝覆盖现存文件；临时输出路径若已经存在，应换用一个新的路径。

```sh
python3 Tests/Fixtures/TravelGenerationPrompts/generate.py --output /tmp/travelcat-historical-image-prompts.json
cmp Tests/Fixtures/TravelGenerationPrompts/historical-image-prompts.json /tmp/travelcat-historical-image-prompts.json
```

首次独立重建逐字节一致，文件 331,871 字节，SHA256 为 `fb34ad0698b940e4bb3fabd03510697e191256ece54793c0db6559175072d828`。

未来修改共用提示时，不应通过重录当前输出让兼容测试恢复通过。新卡需要新的生成方向时应沿用版本化入口，保留旧版本输出。如果发现基线提取本身有错误，需说明具体错误、历史来源和受影响样例，再只修正相应基线及来源记录。新增地点关键词、构图算法或共用工具包装也可能改变旧卡重试，此时应审查版本兼容性。

这些样例覆盖代表性分类及全部三种构图，没有穷尽所有地点、关键词或模型响应。当前版本 4 的地标规则继续由既有 `TravelGenerationPromptStyleTests` 检查，不冻结在这份旧卡基线中。
