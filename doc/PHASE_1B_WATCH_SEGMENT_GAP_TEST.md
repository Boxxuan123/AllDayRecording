# Phase 1B：Watch 5 自动分段连续性测试

## 目的

本阶段不接入 Wear Engine，不测试手机传输，只回答一个问题：Watch 5 使用 AVRecorder 每 5 秒或 10 秒停止、封口并启动下一段时，相邻 M4A 之间实际丢失多少音频。

用户已经报告完成一次约 150 分钟的单文件连续录音，因此本阶段把长时录音能力视为已有正向证据，但不把该用户报告等同于自动分段验收。

## Watch 实现

- 整次测试只申请一次 `AUDIO_RECORDING` 长时任务。
- 页面可选择 5 秒或 10 秒分段。
- 当前分段先写入 `segment_<序号>_start_<时间戳>.m4a.part`。
- AVRecorder 停止、释放并关闭文件后，原子重命名为 `.m4a`。
- 下一段启动后重新按绝对开始时间安排下一次轮换。
- 每次测试使用独立沙箱目录：`files/gap_test_<会话开始时间>/`。
- `.part` 文件表示未成功封口，不参与连续性分析。

## 测试音和分析工具

Python 工具位于 `/Volumes/hardDrive/pythonProject/audio_gap_test`：

- `generate_reference.py`：生成固定种子、16 kHz 单声道参考音。
- `validate_analyzer.py`：用已知缺口验证分析误差。
- `analyze_segments.py`：解码导出的 M4A，并通过互相关匹配计算间隙。

详细命令见该目录的 `README.md`。

## 真机步骤

1. 先运行 `validate_analyzer.py`，必须通过已知缺口自测。
2. 生成 360 秒参考音。
3. Mac 扬声器与 Watch 固定相距 30–50 厘米，音量适中，环境保持安静。
4. 开始播放参考音；播放 10 秒后，在 Watch 选择“5 秒”并开始测试。
5. 立即让 Watch 正常熄屏，持续录制 5 分钟。
6. 停止 Watch 测试后，让参考音继续播放至少 10 秒。
7. 导出最新 `gap_test_<时间戳>` 目录下全部 `.m4a`，保持文件名不变。
8. 使用 `analyze_segments.py` 生成 CSV、JSON、Markdown 和 PNG 报告。
9. 对照再执行一次亮屏测试和一次 10 秒熄屏测试。

## 需要记录的证据

- 预期和实际生成的分段数量。
- 空文件、损坏文件和遗留 `.part` 文件数量。
- 每个边界的间隙或重叠毫秒数。
- 中位数、P95、最大值与累计正间隙。
- 大于 100、300、500 毫秒的边界数量。
- 每段参考音匹配置信度。
- 亮屏、熄屏及 5 秒、10 秒方案的差异。

## 决策边界

- 如果分段全部可解码且间隙稳定处于可接受范围，可继续使用 AVRecorder 轮换方案。
- 如果频繁超过 500 毫秒、出现整段缺失或轮换停止，应放弃停止/重建 AVRecorder 的连续性假设，改为验证持续 AudioCapturer 加编码封装层分段。
- 构建成功只能证明代码和打包通过，不能代替上述 Watch 真机音频测量。

## 当前验证状态（2026-08-24）

- Watch 端 5 秒/10 秒轮换实现已经通过 ArkTS 编译、HAP 打包和签名，Debug 产物为 `entry/build/default/outputs/default/entry-default-signed.hap`。
- Python 已知间隙自测通过：PCM/WAV 最大误差 0 毫秒，AAC/M4A 最大误差 10 毫秒。
- 完整分析链路已经用 7 个合成 AAC/M4A 分段跑通，成功生成 CSV、JSON、PNG 和 Markdown 报告。
- 360 秒参考音已经生成在 `/Volumes/hardDrive/pythonProject/audio_gap_test/outputs/audio_gap_test/reference.wav`，SHA-256 为 `460ca8ddb9df3b1ce02ad5da58f200486c54df392bcb0350fea66d318af625b0`。
- Watch 5 第一轮 5 秒真机测试已通过开发调试通道导出 3 个完整 M4A；另有 1 个 259 字节的 `.part`，按规则不参与分析。
- 两个真实边界分别测得 533.2 毫秒和 377.6 毫秒正间隙，中位数 455.4 毫秒，累计丢失 910.8 毫秒；两个边界均超过 300 毫秒，其中一个超过 500 毫秒。
- 该轮只有两个边界，不能据此形成稳定的中位数/P95，但已经否定“停止并重建 AVRecorder 可以无缝 5 秒轮换”的假设。完整证据保存在 Python 工程的 `outputs/audio_gap_test/watch_run_001/`。
- 第二轮全程亮屏测试导出 20 个完整 M4A、无 `.part`，形成 19 个高置信度边界：间隙最小 421.2 毫秒、中位数 447.7 毫秒、P95 458.2 毫秒、最大 466.9 毫秒，累计丢失 8,491.0 毫秒，19/19 均超过 300 毫秒。
- 第二轮间隙标准差仅 11.0 毫秒，证明约 0.45 秒空洞在亮屏下仍稳定出现，主要来自 AVRecorder 重建生命周期，而不是熄屏调度。完整证据保存在 `outputs/audio_gap_test/watch_run_002/`。
- 工程已进入 Phase 1C：保持一个 AudioCapturer 连续采集，以精确采样编号轮换双缓冲 WAV，详见 `PHASE_1C_AUDIOCAPTURER_PCM_GAP_TEST.md`。
