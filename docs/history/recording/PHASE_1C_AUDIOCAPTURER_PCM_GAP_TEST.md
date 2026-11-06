# Phase 1C：AudioCapturer 连续 PCM 双缓冲分段

> 文档状态：`experiment` — 本文保留 5 秒分片验证数据；当前生产实现沿用连续采集设计，但分片为 60 秒，5 秒仅是内存队列上限。

## 目标

Phase 1B 已在 Watch 5 亮屏条件下证明：每 5 秒停止并重建 `AVRecorder` 会稳定丢失约 0.45 秒音频。本阶段不再重启麦克风采集器，只验证 `AudioCapturer` 连续输出 PCM 时，按精确采样编号轮换 WAV 能否消除边界空洞。

本阶段仍不接入手机传输、云端转写或 AAC 编码。

## 实现结构

1. 整个会话只创建并启动一次 `AudioCapturer`。
2. 格式固定为 16 kHz、单声道、S16LE PCM。
3. `readData` 回调只复制数据并加入队列，不关闭文件、不创建新采集器。
4. 内存队列最多缓存 5 秒 PCM；超过上限立即报错并停止，禁止静默丢数据。
5. 当前 WAV 与下一 WAV 同时预先打开，形成双文件槽。
6. 每累计 80,000 个采样（160,000 PCM 字节）切换文件槽，不使用 `setTimeout` 决定边界。
7. 切换后回写旧文件 WAV 头、`fsync`、关闭，并把 `.wav.part` 重命名为 `.wav`。
8. 正常停止后写入 `session_summary.json`，记录每段首采样、采样数、硬件溢出、软件队列溢出和连续性结论。

实现文件：`entry/src/main/ets/services/PcmSegmentedRecordingService.ets`。旧 `AudioRecordingService.ets` 保留为 AVRecorder 基线，没有删除。

## 文件布局

每次会话创建：

```text
files/pcm_gap_test_<会话时间>/
  segment_000001_first_000000000000.wav
  segment_000002_first_000000080000.wav
  ...
  session_summary.json
```

正常的完整 5 秒段应满足：

- WAV 大小：160,044 字节。
- `sampleCount`：80,000。
- 下一段 `firstSample` 等于上一段 `firstSample + sampleCount`。
- `hardwareOverflowCount` 与 `softwareQueueOverflowCount` 均为 0。
- `continuityValid` 为 `true`。

最后一段允许不足 5 秒，只要 WAV 可解码且采样链仍连续。

## 第一轮真机步骤

1. 覆盖安装 Debug HAP，不卸载应用，保留既有录音沙箱。
2. 播放 Python 工程中的 360 秒 `reference.wav`。
3. 播放约 10 秒后，在 Watch 点击“开始 PCM 测试”。
4. 第一轮保持亮屏，录制至少 20 个完整段后点击“停止测试”。
5. 确认页面显示硬件溢出为 0。
6. 导出最新 `pcm_gap_test_<时间戳>` 中全部 `.wav` 和 `session_summary.json`。
7. 先核对内部采样连续性，再用 `analyze_segments.py` 做声学时间轴复核。
8. 亮屏通过后，以相同步骤执行熄屏测试。

## 验收标准

- 所有完整 WAV 都是 16 kHz、单声道、16-bit PCM，且恰好 80,000 个采样。
- 正常停止不遗留 `.part`。
- `continuityValid=true`，软硬件溢出均为 0。
- 至少 19 个边界全部能匹配参考音。
- 声学间隙中位数绝对值不超过 20 毫秒，P95 不超过 50 毫秒，最大值不超过 80 毫秒。
- 结果必须明显优于 Phase 1B 亮屏基线：中位数 447.7 毫秒、P95 458.2 毫秒。

## 当前状态（2026-08-24）

- 连续 AudioCapturer、5 秒采样切分、5 秒队列、双文件槽、WAV 回写封口、溢出诊断和会话摘要均已实现。
- 页面已切换为 PCM 测试入口，旧 AVRecorder 服务仍保留在工程中。
- 清理后的 Debug 构建已经完成，ArkTS 编译、资源处理、HAP 打包和签名成功。
- Watch 5 熄屏真机会话 `pcm_gap_test_1787580420697` 已完成并通过连续性验收：
  - 21 个 WAV，共 1,628,800 个采样、101.8 秒；其中 20 个完整 5 秒段，最后一段 1.8 秒。
  - 所有 WAV 均为 16 kHz、单声道、16-bit PCM；文件头、文件尺寸、采样数和摘要逐项吻合，且无残留 `.part`。
  - 所有相邻 `firstSample` 连续；`capturerFramePosition` 等于 `totalSamples`；`continuityValid=true`。
  - `hardwareOverflowCount=0`，`softwareQueueOverflowCount=0`。
  - 20 个边界全部匹配参考音：声学间隙中位数 0.023 ms、P95 0.497 ms、最大值 0.497 ms，超过 100 ms 的边界为 0。
  - 相比 Phase 1B 的 447.7 ms 中位间隙，本方案已把切段空洞降低到分析分辨率附近。
- 本轮由用户确认是在 Watch 5 熄屏状态下录制，说明连续 `AudioCapturer` 在本次 101.8 秒熄屏测试中没有被暂停，也没有在 5 秒 WAV 轮换处丢失采样。Phase 1C 的短时熄屏连续性验收通过。
