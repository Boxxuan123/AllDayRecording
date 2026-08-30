# AllDayRecording 维护性收尾 Phase N0 测试门禁

日期：2026-08-30

基线提交：`f4bf48e4791e8a118fc8447ab7b7b25bb678720c`

状态：已完成。Watch 与 Phone 宿主机测试均生成当前源码对应的真实 Hypium 报告，合计
46/46 通过；底层 `test` 任务的错误退出语义和 Darwin runner 的无界等待已由项目门禁补齐。

## 1. 范围与结论

本阶段只修改测试 mock、测试门禁和文档，没有修改 `entry`、`phone` 或 `common` 的生产
实现。没有安装 HAP、连接设备或读写 Phone/WATCH 5 沙箱。

Phase 6 将 Phone 测试迁入独立 HAP 后遗漏了 `@ohos.util` 的宿主机 mock。Phone 的测试文件
写入了正确的 UTF-8 JSON，但 Darwin Previewer 的 `TextDecoder` 返回空文本，导致有效清单
退化为目录扫描，损坏清单修复结果也无法被测试回读。补齐与 Watch 模块相同的 UTF-8
mock 后，原有三项 Phone 生产行为测试全部通过。

同时确认 Hvigor 的底层 `test` 任务在 Hypium 报告含失败时仍可能显示 `BUILD SUCCESSFUL`
并退出 0。因此新增根任务 `hostTest`：它依次执行两端测试，并校验报告由当前运行生成、
报告测试数与源码 `it(...)` 数一致、`Failure/Error/Ignore` 均为 0、`Pass` 等于总数。
每个模块默认最多等待 60 秒，避免 runner 在 `Darwin` 后无限停滞。

## 2. 工具链快照

| 项目 | 当前值 |
| --- | --- |
| macOS | 27.0（Build `26A5421a`） |
| 测试目标 | Darwin 27.0.0 arm64 |
| DevEco Studio | 26.0.0（Build `DS-261.23567.138.36.2600621`） |
| HarmonyOS SDK | 26.0.0.32，API 26，Beta2 |
| DevEco Node | v24.14.1 |
| Hvigor | 6.26.2 |
| Hypium | 1.0.25 |

## 3. 复现与诊断证据

在受限环境直接运行 Watch `test` 时，ArkTS 编译完成后输出 `Darwin`，30 秒内没有结果
文件；该进程被有界终止，不能计为测试通过。在允许本地 socket 的同一主机环境运行同一
命令后，报告约 4 秒生成。这确认停滞来自 Darwin runner 的本地 socket 环境边界，不是
测试源码或 Hvigor 模块选择错误。

首次真实运行 Phone 测试得到：

```text
Tests run: 3, Failure: 1, Error: 1, Pass: 1, Ignore: 0
```

失败分别是有效清单被当作历史扫描记录，以及修复后的清单回读为空。两者都由 Phone
缺少 UTF-8 mock 导致；生产代码未改。

## 4. 最终测试报告

最终命令：

```sh
PATH=/Applications/DevEco-Studio.app/Contents/tools/node/bin:/usr/bin:/bin:/usr/sbin:/sbin \
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  --no-daemon hostTest
```

| 模块 | 源码测试数 | 报告结果 | 门禁计时 | 文本报告 |
| --- | ---: | --- | ---: | --- |
| Watch `entry@default` | 43 | 43/43，Failure 0，Error 0，Ignore 0 | 5,074 ms | `entry/.test/default/intermediates/test/coverage_data/test_result.txt` |
| Phone `phone@default` | 3 | 3/3，Failure 0，Error 0，Ignore 0 | 4,070 ms | `phone/.test/default/intermediates/test/coverage_data/test_result.txt` |
| 合计 | 46 | 46/46 | 9,147 ms | Darwin 27.0.0 arm64 |

HTML 覆盖率报告分别位于两模块的
`.test/default/outputs/test/reports/index.html`。`.test` 是忽略的生成目录，`clean` 会删除报告；
需要证据时必须重新执行 `hostTest`，不得引用已被清理前的旧报告。

## 5. 统一验证矩阵

| 门禁 | 结果 |
| --- | --- |
| Code Linter | PASS，0 defects，SDK 26.0.0 / API 26 |
| `entry@ohosTest` Debug 测试 HAP | 构建成功，4.641 秒；只保留既有的测试资源重复声明提示 |
| 独立 clean Debug `assembleApp` | 构建成功，7.773 秒 |
| 独立 clean Release `assembleApp` | 构建成功，8.130 秒 |
| Release `.app` | 357,122 bytes，SHA-256 `4eddb20c55587a9899e0068bfd5e7b6f763cd2487b5d3b4a4f6461f524ef3b4b` |
| Release 交付边界 | 恰好两个 HAP：`AllDayRecording-watch.hap` 与 `AllDayRecording-phone.hap` |
| 模块/API 边界 | Watch `entry` 仅 wearable，Phone `phone` 仅 phone；compatible 23、target 26 |

`entry@ohosTest` 在本阶段只验证测试 HAP 能编译打包，没有冒充设备执行结果。Debug/Release
构建也没有替代真机录音、恢复、同步或播放验收。

## 6. 工作区与后续边界

Host 测试和 Debug/Release 构建都会改写被跟踪的 `common/BuildProfile.ets`；本阶段记录了
Debug/Release 常量及尾随空格/末尾换行的精确 diff，并在每轮验证后把该文件恢复为基线
内容。最终 `git diff --exit-code -- common/BuildProfile.ets` 通过。永久消除该污染仍属于
Phase N2，本阶段没有提前改变生成路径或忽略规则。

Phase N0 的文件范围只包含 Phone 测试 mock、Host 测试门禁、README、本报告和计划状态；
没有混入自动同步队列、wire、路径、签名、API 23、录音或 Phase 7 内容完整性协议改动。
