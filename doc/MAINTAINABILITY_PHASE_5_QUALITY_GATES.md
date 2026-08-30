# Phase 5：质量门禁与当前文档

> 文档状态：`current`
> 当前结论：实现、本地验证和用户 Phone/WATCH 5 快速回归均已通过；代码提交为 `53e42a0`。

## 1. 实施结果

- 根 Hvigor 节点新增 `codeLinter` 任务，实际调用 DevEco Code Linter 并读取仓库 `code-linter.json5`。
- `tools/quality/run-code-linter.mjs` 从 SDK 元数据解析 API/platform 版本，解析 Code Linter JSON 行报告；任何 defect、检查不完整或工具非零退出都会令 Hvigor 失败。不能再以工具“有 defect 仍返回 0”误判通过。
- 两个 `export *` 性能告警改为显式导出，没有关闭或弱化规则。
- CoreFileKit、Preferences、AudioKit、后台任务、通知和 Wear Engine 的可抛异常在各自 adapter/服务边界捕获并传播。生产 Debug/Release 源码图的 `Function may throw exceptions` 从 Phase 4 的 69 个降为 0。
- 补齐根 `README.md` 与 `doc/CURRENT_ARCHITECTURE.md`，更新默认 package 描述，并为历史 Phase 文档标记 `superseded`/`experiment`。
- 旧文档中的“一次 100 个”“历史索引未持久化”“5 秒生产分片”已修正：当前手动请求最多 1 个缺失文件、库存键每页 24 个、Phone 索引持久化并可扫描重建、生产 WAV 为 60 秒而 5 秒仅是内存队列上限。
- 当前架构记录了 500 行/25 字段/跨三层复审阈值和现有例外。

本阶段没有改动录音参数、WAV/JSON schema、目录、wire JSON、requestId、超时/重试次数、ACK 顺序或 Watch 源文件保留策略。

## 2. Lint 与测试证据

实际执行 `hvigorw --no-daemon codeLinter`：

- Code Linter 完整识别 SDK 26.0.0 / API 26。
- 报告 `0 defects`，Hvigor `BUILD SUCCESSFUL`。

实际宿主机 Hypium 报告：

- `Tests run: 46, Failure: 0, Error: 0, Pass: 46, Ignore: 0`。
- 文本结果由 `entry/.test/default/intermediates/test/coverage_data/test_result.txt` 生成并逐项核对。
- HTML 报告由 `entry/.test/default/outputs/test/reports/index.html` 生成。
- DevEco Darwin runner 在沙箱内因本地 socket 不可用而悬挂；终止该次运行后，在允许本地 socket 的环境重跑得到上述实际报告。悬挂运行没有被计为通过。
- 测试源码图的未处理异常提示为 0；仅保留默认关闭的 AVRecorder 历史实验所产生的 4 个 Media 能力提示和 1 个麦克风权限静态提示。

`entry@ohosTest` Debug 测试 HAP 构建成功，仅有既存的 `start_window_background` 测试资源重复声明提示。该结果只证明设备测试 HAP 可打包，没有冒充设备执行通过。

## 3. 独立构建证据

Debug 与 Release 分别独立执行 `clean assembleHap`：

| 模式 | 结果 | signed HAP | SHA-256 | 未处理异常 | 已说明能力提示 |
| --- | --- | ---: | --- | ---: | ---: |
| Debug | 成功 | 808,616 bytes | `cd5fd83aa243ac15b451fc167545190df1933e481f4e1e6869903e52db82e2fa` | 0 | 28 个 wearable 目标提示 + 7 个系统能力提示 |
| Release | 成功 | 398,704 bytes | `f58c25cf47163aeae23187de302fd165db6db6896d1497be1219083bae761d01` | 0 | 28 个 wearable 目标提示 + 7 个系统能力提示 |

Release `pack.info` 继续确认同一 `entry` 模块、`phone` + `wearable`、compatible API 23、target API 26。Release 另保留 DevEco 的混淆未启用建议；本阶段没有为追求零提示擅自开启可能改变运行行为的混淆。

28 个 wearable 目标提示来自同一 HAP 内的 Phone Wear Engine receiver/远端启动代码；Phone/Watch Root 已按设备隔离，Transport 连接前检查 Wear Engine 能力。7 个系统能力提示来自 AudioCapturer（6）和 AVPlayer（1），调用前均有 `canIUse`。完整调用边界见 `doc/CURRENT_ARCHITECTURE.md`。

## 4. Git 与数据保护

- `.gitignore` 继续排除 `build-profile.json5`、`local.properties`、`.hvigor`、`entry/build`、`outputs`、日志和依赖目录。
- 本阶段不安装 HAP、不连接设备、不读取或改写 Watch/Phone 沙箱。
- 实现提交 `53e42a0` 只包含 Phase 5 源码、质量脚本和文档；签名材料、HAP、测试报告、设备备份和本机配置未进入 Git。

## 5. 用户验收

2026-08-30，用户按以下清单完成 Phone/WATCH 5 快速回归并确认通过：

1. WATCH 5 开始录音、停止封口并本地试听。
2. Phone 执行重连、同步一个缺失文件并试听，确认 Watch 源文件仍保留。
3. 从 Phone 发起一次手表录音控制；若进入通知降级，确认点击通知仍能回到手表前台继续操作。

本次真机操作由用户完成；Codex 本阶段没有安装 HAP，也没有读取或改写 Watch/Phone 沙箱。后续任何会触及设备数据的安装或迁移，仍须先执行总计划第 4 节的双份只读导出与 SHA-256 清单比较。
