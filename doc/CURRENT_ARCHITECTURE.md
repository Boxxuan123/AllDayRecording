# AllDayRecording 当前架构

> 文档状态：`current`
> 核对日期：2026-08-30
> 适用源码：维护性重构 Phase 5 工作树；后续行为或边界变化必须同步更新本文。

## 1. 交付与兼容边界

工程当前只有一个 `entry` HAP，同时面向 `phone` 和 `wearable`。目标 SDK 为 API 26，手表最低兼容 HarmonyOS `6.1.0(23)`。同一源码图会让编译器同时检查两个设备目标，因此手机侧 Wear Engine 接收/远程启动 API 会在 wearable 目标产生“unavailable to wearable”提示；这些调用只从 `PhoneRootPage -> PhoneRecordingViewModel -> WearEngineRecordingReceiver` 到达，不在手表页面执行。

物理拆分 Phone/Watch HAP 尚未批准。签名身份、Client ID、Wear Engine 对端身份和无损升级需要在 Phase 6 单独验证。

## 2. 依赖方向

```text
pages -> Root/ViewModel -> recording or sync coordinator -> transport/storage adapter
                                                    -> shared models and pure utilities
```

- `pages/Index.ets` 只按设备类型挂载 Phone/Watch Root。
- 页面组件只展示状态并转发事件，不直接操作 CoreFileKit、Wear Engine 或录音后台任务。
- ViewModel 负责页面生命周期与用户动作编排；持久化和协议状态由领域服务承担。
- `sync/transport/WearEngineTransport.ets` 是原始 Wear Engine 调用边界。
- `shared/io` 和 `recording/WavSegmentSlot.ets` 是耐久文件边界。
- `diagnostics` 默认关闭且生产 UI 不可达。

## 3. 录音与恢复数据流

1. `WatchRecordingViewModel` 经 `PcmSegmentedRecordingService` 启动能力检查、AudioCapturer 和 `AUDIO_RECORDING` 持续任务。
2. `readData` 回调只复制 PCM 并加入内存队列；队列最大约 5 秒，溢出会显式失败，不静默丢弃。
3. `WavSegmentSlot` 预建当前/备用 `.wav.part`，按 960,000 个采样（16 kHz、60 秒）切换。
4. 完成槽回写 WAV 头，执行 `fsync`、关闭和原子重命名后才成为可同步 `.wav`。
5. `PcmSessionSummaryStore` 原子写入 `session_summary.json`；目录和 schema 继续兼容既有 `pcm_gap_test_*` 会话。
6. 启动恢复只处理安全的 `.wav.part`；非空合法 PCM 被封口，空预建槽删除，冲突或非法文件保留并记录原因。

录音目录、WAV 参数、摘要 schema 和中断恢复语义没有在 Phase 5 改动。

## 4. 同步与手机持久化数据流

1. 已封口分片进入持久化的 `automatic_sync_queue_v1.json`；进程重启后会恢复仍存在且大小匹配的条目。
2. `WatchSyncCoordinator` 串行自动/手动请求；当前手动批次最多发送 1 个缺失文件，库存键按每页 24 个分页交换，后续点击继续补拉剩余文件。
3. `WearEngineTransport` 负责发现对端、应用身份、receiver 注册、消息、文件、远端启动和通道销毁。
4. Phone 先把收到的文件原子复制到 `synced_from_watch/<requestId>/`，再由 `ReceivedRecordingStore` 更新 `received_index_v1.json`。
5. 索引损坏或缺失时，Phone 扫描同步目录和旧 `received_*.wav` 重建可见列表。
6. 只有文件已落盘且索引流程完成后，Phone 才发送 `sync_file_received`；Watch 在 ACK 丢失或通信失败时保留源文件并重试。

Wire JSON、requestId、路径、重试/超时参数和源文件保留策略继续兼容 Phase 2。

## 5. 系统能力与编译提示

Phase 5 已逐项捕获并传播 CoreFileKit、Preferences、AudioKit、后台任务、通知和 Wear Engine 的潜在异常；生产代码中的 `Function may throw exceptions` 为 0。

仍保留的能力提示有明确边界：

| 提示范围 | 运行时保护 | 保留理由 |
| --- | --- | --- |
| `AudioCaptureLifecycle` 的 AudioKit 能力 | 创建采集器前调用 `canIUse('SystemCapability.Multimedia.Audio.Capturer')` | 只在 Watch 录音入口执行；枚举/创建调用仍会被多设备编译静态提示 |
| `AudioPlaybackService` 的 AVPlayer 能力 | 播放前调用 `canIUse('SystemCapability.Multimedia.Media.AVPlayer')` | 手机/手表共用播放服务，设备不支持时显式失败 |
| `RecordingTransferService` 的 Wear Engine phone API | 页面由设备类型隔离；Transport 连接前检查 `SystemCapability.Health.WearEngine` | 单 HAP 同时编译 phone/wearable；手机 receiver 与远程启动不会从 Watch Root 到达 |
| `diagnostics/legacy/AvRecorderGapBaseline` 的 AVRecorder 与麦克风权限 | `RecordingDiagnosticsPolicy` 默认关闭，构造前即拒绝；生产 UI 无入口 | 仅由业务测试编译以防历史基线腐化，相关能力/权限提示只出现在测试源码图 |

这些提示不能通过关闭规则隐藏。若未来出现新的能力提示，必须补充设备范围、调用路径、保护条件和真机证据。

## 6. 复审阈值与当前例外

软阈值：单文件超过 500 行、单类可变字段超过 25 个或一个改动横跨 UI/Transport/Storage 三层时必须说明理由。

当前已知例外：

- `services/RecordingTransferService.ets` 约 1,785 行，包含 Watch Sender 与 Phone Receiver 两个兼容 facade。协议、Transport、Queue、Phone/Watch/Control 状态机和接收 Store 已移出；在物理 HAP 拆分结论明确前保留现有公开入口。后续新增功能不得继续把协议或存储实现塞回该文件。
- `presentation/watch/WatchRecordingViewModel.ets` 约 591 行且可变字段超过 25 个。它是 Watch 页面生命周期与录音/播放/同步展示的编排层，不直接实现 Transport 或 Storage；下一次修改其状态集合时应优先拆分权限/通知或计时子状态。
- `WearEngineRecordingReceiver` 的展示字段仍超过 25 个，但传输与状态转换已经委托给协调器。若增加第三类同步状态，应先聚合为不可变 UI 快照。

阈值例外不是永久豁免；每次触碰相关文件都要重新核对。

## 7. 证据边界

- `hvigorw codeLinter` 是实际 Code Linter 报告，不是任务占位符；任何 defect 或不完整检查均失败。
- Hypium 报告证明宿主机业务测试通过；`ohosTest` HAP 构建只证明设备测试代码可打包，不等于已经在设备执行。
- Debug/Release 成功只证明相应模式可编译、打包和签名。
- WATCH 5 的开始/停止、熄屏、中断恢复和 Phone 同步/播放必须使用最终文件、摘要、大小/哈希与用户验收作为证据。
- 安装前必须按总计划的数据保护步骤完成双份只读导出，不得用清空沙箱代替测试准备。
