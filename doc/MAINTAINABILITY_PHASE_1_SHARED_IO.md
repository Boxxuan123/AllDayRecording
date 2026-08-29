# Phase 1：共享持久化与 WAV 基础设施

## 1. 状态与范围

执行日期：2026-08-29

当前状态：实现、本地验证和用户真机回归均已完成。

本阶段只提取并复用无状态的文件与格式基础设施：

- `WavFormat`：16 kHz、单声道、16-bit PCM 常量，44 字节 WAV 头和完整写入循环。
- `AtomicFileWriter`：`.part` 写入、`fsync`、关闭、原子重命名和失败证据保留。
- `AtomicJsonStore`：UTF-8 JSON、版本校验、损坏状态、`.part` 原子替换。
- 迁移 PCM 分段封口、中断恢复、自动同步队列、手机接收索引和接收文件落盘。

共享基础设施提取没有修改录音参数、分段时长、目录名、最终文件名、JSON 字段/版本、Wear Engine 消息或 API 23 最低兼容版本。真机回归另发现手机 Wear Engine 核心接收通道卡住后，仅注销并重新注册回调无法恢复；本次收口追加了窄范围页面/接收器修复：`stop -> wearEngine.destroy() -> start` 硬重建、重复点击保护，以及重连期间禁用同步和手机控制入口。

## 2. 共享组件

### 2.1 `WavFormat.ets`

统一的生产常量仍为：

| 项目 | 值 |
| --- | ---: |
| 采样率 | 16,000 Hz |
| 声道 | 1 |
| 位深 | 16 bit |
| 每采样字节数 | 2 |
| WAV 头 | 44 bytes |

`createPcmWavHeader` 是正常封口和中断恢复共同使用的唯一 WAV 头生成实现。`writeEntireBuffer` 在底层短写时继续写剩余字节；返回 0 或负数时立即失败，避免产生被误认为成功的截断文件。

### 2.2 `AtomicFileWriter.ets`

耐久发布顺序固定为：

```text
写 finalPath.part -> 完整写入/复制 -> fsync -> close -> rename 到 finalPath
```

约束：

- 写入、`fsync` 或关闭失败时不执行最终重命名。
- `fsync` 失败后仍尝试关闭文件，并保留原始同步错误。
- 失败的 `.part` 不自动删除，继续作为诊断或恢复证据。
- 手机接收文件仍只有在原子复制完整返回后才进入后续记录与 ACK 流程。

### 2.3 `AtomicJsonStore.ets`

读取结果显式区分：缺失、成功、版本无效、内容无效和损坏。文件访问、读取或 JSON 解析异常统一返回损坏状态，由现有调用方继续执行原有回退策略。

写入保持原 JSON 的 `JSON.stringify(document, null, 2)` 字节表现，但改为 UTF-8 编码后复用 `AtomicFileWriter`。真实临时目录测试已经验证：当最终 JSON 已存在时，第二次写入可原子替换，且不会残留 `.part`。

## 3. 调用方迁移与兼容性

| 调用方 | 迁移内容 | 保持不变的契约 |
| --- | --- | --- |
| `PcmSegmentedRecordingService` | PCM 完整写入、占位 WAV 头、最终 WAV 头、耐久封口、会话摘要 | AudioCapturer 单会话连续运行、60 秒分片、路径和摘要字段 |
| `InterruptedWavRecoveryService` | WAV 头、短写循环、`fsync`/关闭/发布、恢复摘要 | 空 part 处理、PCM 长度限制、目标已存在时保留 part、证据字段 |
| `RecordingTransferService` | 自动队列读取/写入、手机接收文件耐久复制 | 清单 v1、队列字段、源文件保留、同步串行、ACK 时机和 wire 协议 |
| `ReceivedRecordingStore` | 接收索引读取/写入 | `received_index_v1.json`、清单 v1、目录扫描回退和去重规则 |

本阶段删除的是上述调用方内部的重复实现，没有删除旧录音、迁移数据库或重命名既有路径。

## 4. 字节与失败语义核对

- 新 WAV 头代码逐字段保持原实现：`RIFF/WAVE/fmt /data`、PCM 格式 1、16 kHz、单声道、16 bit、byte rate 32,000、block align 2 和 PCM 长度字段均由独立测试核对。
- 中断恢复测试仍对恢复后的完整文件读取字节，核对 WAV 头与原 PCM 内容。
- 正常录音封口与恢复现在调用同一个头生成和完整写入实现，不再存在两份可能漂移的算法。
- JSON 的文件名、字段、版本和缩进不变；变化只发生在最终文件可见前的 `.part` 耐久写入。
- 自动队列读取失败仍保留录音；接收索引损坏仍扫描音频文件重建可见列表。

## 5. 测试与构建证据

本地 Hypium 命令与 Phase 0 相同。当前实际报告：

```text
Tests run: 27, Failure: 0, Error: 0, Pass: 27, Ignore: 0
```

其中 Phase 1 新增 8 项共享基础设施测试：

- WAV 头完整字段。
- 短写循环及 `fsync -> close -> rename` 顺序。
- `fsync` 异常时仍关闭且不发布。
- 关闭异常时不发布。
- 文件复制的同步、关闭与发布顺序。
- JSON 缺失、损坏、版本无效和内容无效的区分。
- 版本化 JSON 读写结构不变。
- 真实文件系统中原子替换已有 JSON 且不残留 `.part`。

`entry@ohosTest` Debug 测试 HAP 编译打包成功；仍只有 Phase 0 已记录的 `start_window_background` 测试资源重复声明提示。这只证明测试 HAP 可构建，没有执行设备测试。

Debug 与 Release 均分别先执行 `hvigorw clean --no-daemon`：

| 构建 | 结果 | Hvigor 用时 | signed HAP 大小 | signed HAP SHA-256 |
| --- | --- | ---: | ---: | --- |
| Debug | 成功 | 5.629 s | 674,323 bytes | `0cbfd53f333ba5f96f5718e626230edf4a0ff0f2b520a04ecfa57e78dcb87898` |
| Release | 成功 | 4.385 s | 674,328 bytes | `8beaf1816e273984219ac9438faf8f264d2d5abe674237b699e4a634eee5a909` |

Release `pack.info` 复核：`deviceType` 为 `phone`、`wearable`，`compatible` 为 23，`target` 为 26，模块类型仍为 `entry`。

## 6. 警告复核与保留依据

Phase 0 的 clean 构建为 74 项 ArkTS 警告，其中未处理异常 67 项、系统能力提示 7 项。Phase 1 共享提取后为 63 项；真机收口增加的 `wearEngine.destroy()` 边界保留 1 项未处理异常提示，最终 Debug/Release 均为 64 项：未处理异常 57 项、系统能力提示 7 项。相对 Phase 0 减少的 10 项来自重复 I/O 路径被共享实现替代，不把数量变化解释为功能验收。

| 文件 | 当前警告 | Phase 1 说明 |
| --- | ---: | --- |
| `AtomicFileWriter.ets` | 7 | CoreFileKit 边界适配器允许底层错误向组合操作传播；组合操作保证尝试关闭、失败不重命名并保留 `.part`，已有故障注入测试 |
| `AtomicJsonStore.ets` | 2 | 默认文件访问/读取位于统一读取边界；异常被转换为损坏状态，原子写入错误继续交给原调用方处理 |
| `PcmSegmentedRecordingService.ets` | 11 | 6 项为 AudioKit 能力提示；其余是既有 Audio/CoreFileKit 调用，Phase 1 修改的封口路径已进入受测共享组合操作 |
| `ReceivedRecordingStore.ets` | 8 | 剩余为目录扫描和 stat 等既有 CoreFileKit 边界；JSON 读取/写入已迁移，扫描与音频权威回退保持不变 |
| `RecordingTransferService.ets` | 19 | 剩余为 Wear Engine/CoreFileKit 边界；新增 1 项是硬重连的 `wearEngine.destroy()`，异常由页面重连入口捕获并显示；队列写入仍由原 `try/catch` 转换为布尔结果，接收复制失败不会发送 durable ACK |

未修改的 `WatchRecordingStartFallback.ets` 13 项和 `AudioPlaybackService.ets` 4 项继续留给后续所属阶段。上述警告没有通过关闭规则隐藏；Phase 2/4/5 拆分实际边界时继续逐项缩小。

## 7. 真机验收结果

用户在 WATCH 5 与手机上完成回归并确认通过。回归期间先复现到：前两段已经持久化，第三段 `segment_000003_first_000001920000.wav` 在手机 Wear Engine 核心接收器报错后持续留在手表自动队列，页面“重新连接”与手动同步均不能使该文件进入应用回调。

追加硬重连后，用户确认恢复成功；随后只读回拉 JSON 复核：

- 原故障来源 `pcm_gap_test_1788013447924/segment_000003_first_000001920000.wav` 已进入手机 `received_index_v1.json`。
- 手机记录大小为 1,516,204 bytes，本地相对路径为 `synced_from_watch/auto_1788013437819/005_segment_000003_first_000001920000.wav`，接收时间为 2026-08-29 22:55:33 +0800。
- 手表 `automatic_sync_queue_v1.json` 的 `completedCount` 已从故障时的 4 前进到 7，证明原卡点已经越过。
- 23:05:35 回读时队列仍包含用户后来新录会话 `pcm_gap_test_1788015521224` 的一段 530,604-byte 短尾片；因此本报告只确认原故障恢复，不把当时队列误报为空。
- 录音文件、队列 schema、接收索引 schema 和 durable ACK 规则均未改变。

Phase 1 与真机收口修复使用提交信息 `refactor: extract durable file primitives and harden reconnect`。
