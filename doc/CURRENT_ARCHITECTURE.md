# AllDayRecording 当前架构

> 文档状态：`current`
> 核对日期：2026-08-30
> 适用源码：维护性重构 Phase 6 已验收双 HAP 结构；后续行为或边界变化必须同步更新本文。

## 1. 交付与兼容边界

工程当前构建一个包含两个设备类型互斥 HAP 的 `.app`：

- Watch `entry` HAP：`deviceTypes = [wearable]`，保留麦克风、持续任务、振动和 `audioRecording` 后台模式。
- Phone `phone` HAP：`deviceTypes = [phone]`，不声明录音权限或后台录音模式。
- `common` HAR：两端本地依赖的模型、共享状态、文件基础设施、协议、Transport、协调器和播放实现，不单独安装。

应用版本为 `1.0.1`（`versionCode = 1000001`，`buildVersion = 2`），目标 SDK 为 API 26，最低兼容 HarmonyOS `6.1.0(23)`。`bundleName`、Client ID 和签名配置保持不变；Watch 继续使用 `entry` 模块名，Phone 改用 `phone`。用户已决定不实现旧 Phone `entry` 沙箱到新 `phone` 沙箱的自动迁移，安装前双份只读备份承担回退。用户于 2026-08-30 确认双端覆盖安装完成且真机验收通过，Phase 6 物理拆分获准进入主线。

## 2. 依赖方向

```text
Watch HAP -> Watch Root/ViewModel -> recording / Watch Sender
Phone HAP -> Phone Root/ViewModel -> Phone Receiver / receive store
                         both -> common HAR -> coordinator -> transport / shared IO
```

- `entry/.../pages/Index.ets` 只挂载 `WatchRootPage`；`phone/.../pages/Index.ets` 只挂载 `PhoneRootPage`，不再做运行时设备分支。
- 页面组件只展示状态并转发事件，不直接操作 CoreFileKit、Wear Engine 或录音后台任务。
- ViewModel 负责页面生命周期与用户动作编排；持久化和协议状态由领域服务承担。
- `common/src/main/ets/sync/transport/WearEngineTransport.ets` 是原始 Wear Engine 调用边界。
- `common/src/main/ets/shared/io` 和 `entry/.../recording/WavSegmentSlot.ets` 是耐久文件边界。
- Watch Sender 与 Phone Receiver 分别留在对应 HAP，避免把对端专属 API 打入错误设备包。
- Watch `diagnostics` 默认关闭且生产 UI 不可达。

## 3. 录音与恢复数据流

1. `WatchRecordingViewModel` 经 `PcmSegmentedRecordingService` 启动能力检查、AudioCapturer 和 `AUDIO_RECORDING` 持续任务。
2. `readData` 回调只复制 PCM 并加入内存队列；队列最大约 5 秒，溢出会显式失败，不静默丢弃。
3. `WavSegmentSlot` 预建当前/备用 `.wav.part`，按 960,000 个采样（16 kHz、60 秒）切换。
4. 完成槽回写 WAV 头，执行 `fsync`、关闭和原子重命名后才成为可同步 `.wav`。
5. `PcmSessionSummaryStore` 原子写入 `session_summary.json`；目录和 schema 继续兼容既有 `pcm_gap_test_*` 会话。
6. 启动恢复只处理安全的 `.wav.part`；非空合法 PCM 被封口，空预建槽删除，冲突或非法文件保留并记录原因。

录音目录、WAV 参数、摘要 schema 和中断恢复语义没有在 Phase 5 改动。

## 4. 同步与手机持久化数据流

1. 已封口分片进入持久化的 `automatic_sync_queue_v1.json`；进程重启时先完整校验清单及元素类型、相对路径、大小、时长和音频后缀。结构无效清单在访问候选文件前返回 `invalid`，损坏 JSON 返回 `damaged`；合法清单仍恢复存在且大小匹配的条目，并过滤、持久化缺失项后的剩余队列。
2. `WatchSyncCoordinator` 串行自动/手动请求；当前手动批次最多发送 1 个缺失文件，库存键按每页 24 个分页交换，后续点击继续补拉剩余文件。
3. `WearEngineTransport` 负责发现对端、应用身份、receiver 注册、消息、文件、远端启动和通道销毁。
4. Phone 先把收到的文件原子复制到 `phone` 模块沙箱的 `synced_from_watch/<requestId>/`，再由 `ReceivedRecordingStore` 更新 `received_index_v1.json`。
5. 索引损坏或缺失时，Phone 扫描同步目录和旧 `received_*.wav` 重建可见列表。
6. 只有文件已落盘且索引流程完成后，Phone 才发送 `sync_file_received`；Watch 在 ACK 丢失或通信失败时保留源文件并重试。

Wire JSON、requestId、同步目录相对结构、重试/超时参数和源文件保留策略继续兼容 Phase 2。旧 Phone `entry` 沙箱内容不会自动迁入新 `phone` 沙箱；这是已备份并由用户接受的数据可见性变化，不是 wire 协议变化。

## 5. 系统能力与编译提示

Phase 5 已逐项捕获并传播 CoreFileKit、Preferences、AudioKit、后台任务、通知和 Wear Engine 的潜在异常；Phase 6 最终 Code Linter 报告为 0 defects。

仍保留的能力提示有明确边界：

| 提示范围 | 运行时保护 | 保留理由 |
| --- | --- | --- |
| `AudioCaptureLifecycle` 的 AudioKit 能力 | 创建采集器前调用 `canIUse('SystemCapability.Multimedia.Audio.Capturer')` | 只在 Watch 录音入口执行；枚举/创建调用仍会被多设备编译静态提示 |
| `AudioPlaybackService` 的 AVPlayer 能力 | 播放前调用 `canIUse('SystemCapability.Multimedia.Media.AVPlayer')` | `common` HAR 供两端依赖，设备不支持时显式失败 |
| Watch `RecordingTransferService` 的 Wear Engine sender API | Transport 连接前检查 `SystemCapability.Health.WearEngine` | 仅打入 Watch HAP；API 23 兼容调用点仍会产生静态能力提示 |
| `diagnostics/legacy/AvRecorderGapBaseline` 的 AVRecorder 与麦克风权限 | `RecordingDiagnosticsPolicy` 默认关闭，构造前即拒绝；生产 UI 无入口 | 仅由业务测试编译以防历史基线腐化，相关能力/权限提示只出现在测试源码图 |

这些提示不能通过关闭规则隐藏。若未来出现新的能力提示，必须补充设备范围、调用路径、保护条件和真机证据。

## 6. 复审阈值与当前例外

软阈值：单文件超过 500 行、单类可变字段超过 25 个或一个改动横跨 UI/Transport/Storage 三层时必须说明理由。

当前已知例外：

- Watch `entry/.../RecordingTransferService.ets` 为 918 行，只保留 Sender facade；Phone `phone/.../RecordingTransferService.ets` 为 906 行，只保留 Receiver facade。两者仍超过阈值，但已经物理隔离且协议、Transport、Queue、协调器和接收 Store 不在同一个巨型文件中。后续新增功能不得把协议或存储实现塞回 facade。
- `presentation/watch/WatchRecordingViewModel.ets` 约 591 行且可变字段超过 25 个。它是 Watch 页面生命周期与录音/播放/同步展示的编排层，不直接实现 Transport 或 Storage；下一次修改其状态集合时应优先拆分权限/通知或计时子状态。
- Phone `WearEngineRecordingReceiver` 的展示字段仍超过 25 个，但传输与状态转换已经委托给协调器。若增加第三类同步状态，应先聚合为不可变 UI 快照。

阈值例外不是永久豁免；每次触碰相关文件都要重新核对。

## 7. 证据边界

- `hvigorw codeLinter` 是实际 Code Linter 报告，不是任务占位符；任何 defect 或不完整检查均失败。
- `hvigorw hostTest` 会依次运行 Watch 与 Phone 宿主机测试，校验报告新鲜度、源码测试数和失败数，并对 Darwin runner 设置有界超时；当前报告为 Watch 50/50、Phone 3/3，合计 53/53 通过。受限环境仍会在 `Darwin` 后因本地 socket 不可用而超时；`ohosTest` HAP 构建仍只证明设备测试代码可打包。
- clean Debug/Release `assembleApp` 成功只证明两个 HAP 能编译、打包和签名；Release `.app` 解包确认恰有 Watch `entry` 和 Phone `phone` 两个 HAP。
- Release source map 检查中，Watch 包的 Phone Root/ViewModel/Receiver/Store 标识均为 0，Phone 包的 Watch Root/ViewModel/录音/Sender 标识均为 0；这证明当前构建图边界，不替代运行时验收。
- WATCH 5 的开始/停止、熄屏、中断恢复和 Phone 同步/播放必须使用最终文件、摘要、大小/哈希与用户验收作为证据。
- 安装前双份只读导出已完成并核对一致；用户随后确认不清数据覆盖安装与真机验收通过。Codex 未代替用户安装，也未在验收后改写设备文件。
