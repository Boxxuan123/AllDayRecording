# Phase 4：录音领域与诊断隔离

> 文档状态：`superseded` — 这是 Phase 4 完成时的历史快照；当前录音边界与告警状态以 `doc/CURRENT_ARCHITECTURE.md` 为准。

## 1. 当前状态

截至 2026-08-30，Phase 4 已完成。用户已确认 WATCH 5 正常停止、熄屏录音和中断恢复回归通过，代码提交为 `550fb46`。

Codex 本阶段没有连接、安装或读取 WATCH 5，也没有改动任何设备录音。安装新 HAP 前仍须执行总计划第 4 节的只读双份导出与 SHA-256 清单比较。

## 2. 生产录音边界

| 组件 | 单一职责 |
| --- | --- |
| `services/PcmSegmentedRecordingService.ets` | 编排会话、PCM 内存队列、双槽轮换和回调，不再直接实现 AudioKit、后台任务、WAV 封口或摘要 schema |
| `recording/AudioCaptureLifecycle.ets` | AudioCapturer 能力检查、创建、监听、启动、停止、诊断读取和释放 |
| `recording/AudioRecordingBackgroundTask.ets` | `AUDIO_RECORDING` 持续任务和通知 WantAgent 的启动/停止 |
| `recording/WavSegmentSlot.ets` | 占位 WAV 头、PCM 完整写入、回写头、`fsync`、关闭、发布以及失败时保留 `.part` |
| `recording/PcmRecordingContract.ets` | 现有目录/文件命名、60 秒分片常量和 `session_summary.json` schema |
| `recording/PcmSessionSummaryStore.ets` | 分片证据收集、连续性判断和摘要原子写入 |

主编排服务从 663 行降为 405 行。AudioCapturer 的 `readData` 回调仍只校验、复制并把 PCM 放入最多 5 秒的内存队列；WAV 封口、摘要落盘和自动同步触发均不在该实时回调内执行。

## 3. 数据与协议兼容

本阶段没有批准命名或 schema 迁移，因此以下值保持不变：

- 会话目录仍为 `pcm_gap_test_<timestamp>`。
- WAV 仍为 `segment_<6位序号>_first_<12位首采样>.wav`。
- 每段仍为 60 秒、960,000 个采样、1,920,000 PCM 字节。
- 音频仍为 16 kHz、单声道、16-bit S16LE PCM WAV。
- 摘要文件仍为 `session_summary.json`，`format` 仍为 `AllDayRecording PCM gap test v1`，字段名和字段顺序未改。
- 中断恢复现在复用同一目录/分片常量，仍会扫描并读取所有既有 `pcm_gap_test_*` 会话。
- `.part` 的正常封口顺序仍为回写 WAV 头、`fsync`、关闭、原子重命名；封口失败不发布最终 WAV，也不删除 `.part`。
- Wear Engine wire JSON、同步路径、ACK、重试和手表源文件保留规则均未改。

## 4. Diagnostics 与模板清理

- 旧 AVRecorder 轮换基线移动为 `diagnostics/legacy/AvRecorderGapBaseline.ets`。
- Sleep Mode Probe 移动为 `diagnostics/SleepModeProbeService.ets`。
- `RecordingDiagnosticsPolicy.ets` 的显式开关默认为 `false`；两个诊断服务的构造器都会先检查该开关。
- 两个诊断源文件在 Hypium 测试图中编译，但生产依赖图没有任何 `diagnostics` import，手机/手表页面、路由和开发者页均不可达。
- 删除未实现备份逻辑的模板 `EntryBackupAbility`、对应 manifest 注册和 `backup_config.json`。删除范围仅为工程模板源码/配置，不会删除应用沙箱或设备文件；应用不再声明该备份扩展。
- 当前 `module_desc`、Ability 描述和应用标签已经是产品文案，不是默认模板文本，因此保留。

## 5. 自动验证

最终 Hypium 文本报告：

```text
Tests run: 46, Failure: 0, Error: 0, Pass: 46, Ignore: 0
```

Phase 4 新增 7 项直接生产代码测试：

1. 旧会话目录和 WAV 文件名兼容。
2. 连续分片生成原 schema 摘要。
3. 分片缺口、硬件溢出和软件队列溢出拒绝 `continuityValid`。
4. WAV 正常封口后才发布最终文件。
5. 封口失败保留 `.part` 且不发布最终文件。
6. 空备用槽关闭并删除占位 `.part`。
7. diagnostics 默认关闭，同时两份保留源码可在测试图编译。

Phase 0–3 原有 39 项继续通过；既有 `InterruptedWavRecovery` 5 项继续覆盖空 part、有效恢复、超长 part 保留和短写失败。

- `entry@ohosTest` Debug 测试 HAP：构建成功，仅保留既有 `start_window_background` 资源重复提示。
- 独立 `clean` Debug：构建成功；signed HAP 792,817 bytes，SHA-256 `7b9b89f726b788ec61d99c6e0befd73960d1e45dabdb20ca9b110f62ab95b7fc`。
- 再次独立 `clean` Release：构建成功；signed HAP 393,971 bytes，SHA-256 `c3e0ad53320cb1d85a7452edaeba04950714dd204870994e25f70a6868a82198`。
- Release `pack.info` 仍为 `phone` + `wearable`、compatible API 23、target API 26、`entry` 模块；只移除了未使用的备份 extension 声明。

录音拆分后的生产文件仍有 17 个 ArkTS 提示位置：6 个 AudioKit 系统能力提示，以及 11 个 CoreFileKit、AudioKit 和后台任务潜在异常提示。能力检查和现有失败保留路径均未删除；逐项消除或说明属于 Phase 5 质量门禁，未通过关闭规则隐藏。

## 6. WATCH 5 验收清单

1. 完成安装前双份只读备份和 SHA-256 清单比较，再覆盖安装 Debug HAP。
2. 正常录制至少 65 秒，确认出现一个完整 60 秒 WAV 和一个停止时封口的短尾 WAV。
3. 停止后检查 `session_summary.json`：两个分片首采样连续、总采样相符、无溢出时 `continuityValid=true`。
4. 在手表试听并确认自动同步；手机端播放收到的两个文件。
5. 开始一个新会话后熄屏至少 10 分钟，再亮屏并正常停止，确认计时和最终文件正常。
6. 在一个新的短会话中制造一次应用进程中断，重新打开应用，确认非空 `.wav.part` 被恢复且原 PCM 保留；再冷启动一次确认恢复幂等。
7. 确认手机、手表及开发者界面都没有 AVRecorder gap baseline 或 Sleep Mode Probe 入口。

## 7. 真机验收结论

2026-08-30，用户按上述清单完成 WATCH 5 真机测试并确认通过。Phase 4 未观察到正常停止、熄屏录音、中断恢复、试听、同步或历史目录兼容回归。
