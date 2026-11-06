# AllDayRecording 维护性收尾 Phase N1 队列恢复加固

日期：2026-08-30

基线提交：`576e31c`

状态：已完成。自动同步队列现在会在访问候选录音文件前完整校验清单和每个元素；结构无效
返回 `invalid`，不可解析 JSON 或 `null` 文档返回 `damaged`，不会再把异常传播到 Watch
Sender 启动流程。

## 1. 修改边界

本阶段只修改：

- `common/src/main/ets/sync/watch/AutomaticSyncQueue.ets`
- `entry/src/test/AutomaticQueueAndSyncState.test.ets`
- 当前架构、下一步计划与本证据文档

没有修改 Transport、wire JSON、requestId、ACK、批量大小、同步目录、WAV、录音源文件保留
策略、签名、bundleName 或 API 23/26 边界。没有安装 HAP、连接设备或故意损坏真实队列清单。

## 2. 恢复规则

清单级校验现在要求：

- 文档是非空对象，version 仍严格为 1；
- `updatedAt` 是有限非负数；
- `completedCount` 是有限非负整数；
- `files` 是数组，且每个元素都先通过完整校验。

元素级校验现在要求：

- 元素是非空且非数组的对象；
- `relativePath` 与 `fileName` 是非空字符串；
- 相对路径不以 `/` 开头且不含 `..`；
- `size` 是不超过既有 10 MiB 上限的有限正数；
- `durationMs` 是有限非负数；
- 相对路径与文件名都以 `.wav` 或 `.m4a` 结尾，`.part` 和其他类型被拒绝。

整份结构清单在文件恢复循环前校验，因此非法路径不会触发候选文件 `exists/stat`，无效清单
也不会被重写。合法清单中的缺失文件仍按原行为过滤，并把剩余有效条目持久化；测试同时
确认对应源文件仍存在。schema version 和合法生产清单的恢复结果未变。

## 3. 失败基线与新增测试

先只加入 7 项结构损坏测试，未修改生产实现。真实 Watch 报告为：

```text
Tests run: 50, Failure: 5, Error: 2, Pass: 43, Ignore: 0
```

其中 `files: [null]` 与缺字段元素直接抛出属性读取异常；非法大小、时长、路径、文件类型和
清单计数字段被错误地恢复。N0 的 `hostTest` 正确将底层 Hvigor 的 `BUILD SUCCESSFUL`
转换为门禁失败，Phone 测试没有继续执行。

新增测试覆盖：

- `null` 元素以及缺少/空的 `relativePath`、`fileName`；
- 字符串、0、负数和超过 10 MiB 的 size；
- 字符串、负数和 null duration；
- 绝对路径与 `..` 路径，且不访问目标文件；
- `.part` 与非音频类型；
- 非对象文档、错误 version/updatedAt/completedCount/files 类型和值；
- 合法旧清单中缺失文件的过滤、剩余项持久化和源文件保留。

## 4. 最终测试报告

最终 `hvigorw --no-daemon hostTest` 结果：

| 模块 | 结果 | 门禁计时 | 文本报告 |
| --- | --- | ---: | --- |
| Watch `entry@default` | 50/50，Failure 0，Error 0，Ignore 0 | 5,097 ms | `entry/.test/default/intermediates/test/coverage_data/test_result.txt` |
| Phone `phone@default` | 3/3，Failure 0，Error 0，Ignore 0 | 3,937 ms | `phone/.test/default/intermediates/test/coverage_data/test_result.txt` |
| 合计 | 53/53 | 9,038 ms | Darwin 27.0.0 arm64 |

相较 N0 的 46 项，新增 7 项全部属于本阶段的队列结构恢复测试。

## 5. 统一验证矩阵

| 门禁 | 结果 |
| --- | --- |
| Code Linter | PASS，0 defects，SDK 26.0.0 / API 26；5.857 秒 |
| `entry@ohosTest` Debug 测试 HAP | 构建成功，4.280 秒；只保留既有测试资源重复声明提示 |
| 独立 clean Debug `assembleApp` | 构建成功，7.298 秒 |
| 独立 clean Release `assembleApp` | 构建成功，7.485 秒 |
| Release `.app` | 358,308 bytes，SHA-256 `23dffac73fba4d8941252ed64ef3ddc5e5f09d081e225acc6514df57a74438b3` |
| Release 交付边界 | 恰好两个 HAP：`AllDayRecording-watch.hap` 与 `AllDayRecording-phone.hap` |
| 模块/API 边界 | Watch `entry` 仅 wearable，Phone `phone` 仅 phone；compatible 23、target 26 |

`ohosTest` 和本地构建没有冒充设备执行或跨设备传输验收。由于本阶段没有安装到 Watch，
不需要触发设备备份门槛，也没有对真实队列或录音文件进行破坏性测试。

## 6. 工作区与后续边界

Debug、Release 和 Host 测试仍会改写被跟踪的 `common/BuildProfile.ets`。每轮验证后都只把
该文件恢复为基线内容，最终 `git diff --exit-code -- common/BuildProfile.ets` 通过。永久
消除此构建污染仍属于 Phase N2，本阶段没有提前调整生成路径或 `.gitignore`。

Phone 的“先持久化再 ACK”和 Watch 源 WAV 保留逻辑不在本次 diff 中。Phase 7 内容摘要
协议也没有获得授权或被混入。
