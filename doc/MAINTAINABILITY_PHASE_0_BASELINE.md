# AllDayRecording 可维护性重构 Phase 0 基线

## 1. 结论

Phase 0 已于 2026-08-29 完成本地基线冻结：

- 业务命名的本地特征测试共 19 项，实际执行结果为 19/19 通过，`Failure: 0, Error: 0`。
- Debug 与 Release 均在各自执行 `clean` 后串行构建成功。
- 生产 HAP 仍同时声明 `phone`、`wearable`，兼容 API 23、目标 API 26。
- 用户于 2026-08-29 补充完成真机录音回归，并确认录音没有问题。
- 本次 Codex 执行未安装 HAP、未连接设备、未读取或改写 Watch 5 沙箱数据。
- 本阶段未进入 Phase 1，没有提取共享 WAV、原子文件或 JSON 基础设施。

本基线以阶段开始前提交 `c6cff1d` 为源码快照。Phase 0 只增加测试、测试运行所需 mock，以及少量保持生产默认行为不变的 I/O 测试缝。

## 2. 源码与职责快照

Phase 0 修改前，`entry/src/main/ets` 共 5,573 行：

| 文件 | 修改前行数 | 主要职责 |
| --- | ---: | --- |
| `entryability/EntryAbility.ets` | 67 | UIAbility 生命周期、窗口初始化、加载唯一页面入口 |
| `entrybackupability/EntryBackupAbility.ets` | 15 | 模板备份扩展 |
| `models/RecordingModels.ets` | 54 | 录音、同步和控制状态模型 |
| `pages/Index.ets` | 1,379 | 手机/手表 UI 以及大部分页面业务编排 |
| `services/AudioPlaybackService.ets` | 92 | 本地音频播放 |
| `services/AudioRecordingService.ets` | 342 | 旧 AVRecorder 分段录音实现 |
| `services/InterruptedWavRecoveryService.ets` | 231 | 中断 `.wav.part` 恢复和恢复摘要 |
| `services/PcmSegmentedRecordingService.ets` | 663 | 当前 AudioCapturer、PCM 分段和后台录音链路 |
| `services/ReceivedRecordingStore.ets` | 277 | 手机接收文件索引、扫描和清单持久化 |
| `services/RecordingTransferService.ets` | 2,029 | Wear Engine、同步队列、ACK、接收和远程控制 |
| `services/SleepModeProbeService.ets` | 150 | 熄屏/系统事件诊断探针 |
| `services/WatchFileSyncProtocol.ets` | 83 | 同步协议常量、键规则和编解码 |
| `services/WatchRecordingStartFallback.ets` | 191 | API 23 远程启动的前台交互降级 |

Phase 0 完成后的主代码为 5,597 行。新增的 24 行只用于把生产 I/O 的目录枚举、文本读取、文件指针复位和完整短写循环暴露为可替换操作；默认实现仍调用原来的 CoreFileKit API。

复杂度信号：

- `Index.ets` 有 32 个 `@State`。
- `RecordingTransferService.ets` 有 70 个私有字段：Sender 31 个、Receiver 39 个。
- `AudioRecordingService.ets` 与 `SleepModeProbeService.ets` 没有生产入口引用，当前应视作保留的历史/诊断实现，尚未授权删除。

## 3. 入口与依赖快照

当前唯一页面入口是：

```text
module.json5 -> $profile:main_pages
main_pages.json -> pages/Index
EntryAbility.onWindowStageCreate -> windowStage.loadContent('pages/Index')
```

主要生产依赖为：

```text
Index
  -> PcmSegmentedRecordingService
  -> AudioPlaybackService
  -> InterruptedWavRecoveryService
  -> WearEngineRecordingSender / WearEngineRecordingReceiver
  -> WatchRecordingStartFallback

RecordingTransferService
  -> WatchFileSyncProtocol + RecordingModels
  -> ReceivedRecordingStore
  -> Wear Engine + CoreFileKit + AbilityKit

ReceivedRecordingStore
  -> WatchFileSyncProtocol + RecordingModels + CoreFileKit
```

模块仍是单一 `entry`，同时打包手机与手表。页面直接持有录音、播放、恢复、同步和远程控制服务，尚未形成计划中的 ViewModel/Coordinator 边界。

## 4. 公开契约快照

公开契约按职责归类如下：

- 模型：`RecordingFile`、`WatchSyncFileDescriptor`、`ReceivedRecordingFile`、`WatchSyncProgress`、`WatchRecordingControlStatus`。
- 协议：协议版本、18 个消息类型常量、`WatchSyncProtocolMessage`、exact/legacy key、encode/decode。
- 同步：4 个 handler 类型、`WatchRecordingControlResult`、`WearEngineRecordingSender`、`WearEngineRecordingReceiver`、`wearEngineErrorMessage`。
- 录音/播放/恢复：`PcmSegmentedRecordingService`、`AudioRecordingService`、`AudioPlaybackService`、`InterruptedWavRecoveryService` 及其 callback/result 类型。
- 接收存储：`SYNC_RECEIVE_DIRECTORY`、`ReceivedRecordingStore`、`loadReceivedRecordings`。
- 远程启动降级：action 常量、pending/UI state、`WatchRecordingStartFallback`。
- 诊断：`SleepModeProbeCallbacks`、`SleepModeProbeService`。

Phase 0 新增的公开类型仅是可测试性接口：目录枚举、文本读取、恢复 seek 和 WAV 完整写入操作。现有调用方不传参数时继续走原生产实现。

## 5. 实际测试基线

本地测试命令：

```bash
PATH=/Applications/DevEco-Studio.app/Contents/tools/node/bin:/usr/bin:/bin:/usr/sbin:/sbin \
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  --mode module -p product=default -p module=entry@default \
  -p buildMode=debug test --no-daemon
```

实际结果文件：

- 文本结果：`entry/.test/default/intermediates/test/coverage_data/test_result.txt`
- HTML 报告：`entry/.test/default/outputs/test/reports/index.html`

测试分组与结果：

| 分组 | 数量 | 覆盖行为 | 覆盖方式 |
| --- | ---: | --- | --- |
| WatchSyncProtocol | 3 | 当前版本往返、非法版本拒绝、exact/legacy key 语义 | 直接测试生产协议代码 |
| AutomaticQueuePersistence | 3 | 有效恢复并跳过缺失文件、损坏 JSON 回退、重复路径不入队 | 同契约状态模型 |
| FileTransferAckState | 3 | durable ACK 只接收一次、乱序/过期请求忽略、只清理匹配超时 | 同契约状态模型 |
| ReceiverRequestState | 2 | 过期手动请求拒绝但自动消息允许、重复 descriptor 去重 | 同契约状态模型 |
| ReceivedRecordingStore | 3 | 有效清单、缺失项、损坏索引扫描修复、重复路径 | 直接测试生产存储代码和临时目录 |
| InterruptedWavRecovery | 5 | 空 part、合法恢复、超限保留、WAV 头、短写和零进度失败 | 直接测试生产恢复/写入代码和临时目录 |

总计：`Tests run: 19, Failure: 0, Error: 0, Pass: 19, Ignore: 0`。

边界说明：

- `RecordingTransferService` 的队列、ACK 和超时状态仍深藏在私有字段、真实 Wear Engine 和真实时钟中。Phase 0 用 `SyncStateCharacterization.ets` 锁定同契约转换；Phase 2 提取 fake transport/fake clock 后，必须把这些用例替换为直接协调器测试。
- DevEco Previewer 缺少 `fileIo.listFileSync`、`fileIo.readTextSync` 和 `fileIo.lseek` 的可执行实现。本地测试仅替换这三个边界；stat/open/read/write/fsync/rename/unlink、清单解析、扫描规则、恢复判断和 WAV 生成仍执行生产代码。
- 协议测试使用仅在 `src/mock` 生效的 UTF-8 encoder/decoder；生产 HAP 不包含该 mock。
- `entry@ohosTest` 的模板文件已改为 `ApplicationProtocolContract.test.ets`，其 Debug 测试 HAP 已成功编译打包；构建保留 1 项测试资源重复声明提示。本阶段没有把“能编译”当作真机测试通过，也没有运行设备测试。

## 6. 模板测试清理

- 删除 `entry/src/test/LocalUnit.test.ets` 的 `abc contains b` 模板断言。
- 删除 `entry/src/ohosTest/ets/test/Ability.test.ets` 的同类模板断言。
- 本地测试入口现在只加载上述五个业务测试分组。
- `ohosTest` 入口加载业务命名的协议契约测试。

## 7. 构建与打包基线

两种构建均使用绝对 DevEco 工具链和 `DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk`，并分别先执行 `hvigorw clean --no-daemon`。

| 构建 | 结果 | 用时 | signed HAP 大小 | signed HAP SHA-256 |
| --- | --- | ---: | ---: | --- |
| Debug | 成功 | 4.174 s | 657,997 bytes | `d6303d1cf3d396fd88de4476a979ffb4f94807408e0923eef69c00f1a89eeab7` |
| Release | 成功 | 3.898 s | 349,477 bytes | `3e3cf0b4bd89a0f27e1ebe04e1859ebd7d29b36e6532b92375bb02d87463aa8a` |

Release `pack.info` 复核结果：

- `deviceType`: `phone`, `wearable`
- `apiVersion.compatible`: 23
- `apiVersion.target`: 26
- module type: `entry`

这些结果只证明本地编译、打包和签名成功，不代表安装、真机录音、熄屏生命周期或跨设备传输验收通过。

## 8. 警告清单

计划编写时记录的重构前 Debug 基线为 79 个 ArkTS 警告。加入测试缝后，本次 Debug 和 Release 的当前可重复计数均为 74 个 ArkTS 警告；这次变化来自编译器对 I/O 调用报告位置的改变，不应解释为已修复异常处理。

| 分类 | 当前数量 | 说明 |
| --- | ---: | --- |
| 未处理异常 | 67 | `Function may throw exceptions. Special handling is required.`，后续按 Phase 1/2/5 所属文件逐项处理 |
| 系统能力提示 | 7 | AudioKit 6 项、MediaKit 1 项；需结合 phone/wearable 和运行时分支复核 |
| API 兼容提示 | 0 | 本次 clean 构建没有单独的 API version 警告；API 23 约束仍是硬门槛 |
| SDK/构建提示 | Release 1 项 | Release 关闭混淆的 Hvigor 提示；当前配置明确 `enable: false`，记录但不在 Phase 0 改变 |

按文件分布：

| 文件 | ArkTS 警告 |
| --- | ---: |
| `AudioPlaybackService.ets` | 4 |
| `InterruptedWavRecoveryService.ets` | 4 |
| `PcmSegmentedRecordingService.ets` | 16 |
| `ReceivedRecordingStore.ets` | 13 |
| `RecordingTransferService.ets` | 24 |
| `WatchRecordingStartFallback.ets` | 13 |

`code-linter.json5` 虽存在，但实际运行 `codeLinter` 返回 `00306054`：任务未在项目中注册。因此 Phase 0 只能记录该缺口，不能把配置文件存在视为 lint 已通过；注册门禁仍留在 Phase 5。

## 9. Phase 0 验收判定

| 验收项 | 判定 | 证据/限制 |
| --- | --- | --- |
| 测试命令可重复并产生实际报告 | 通过 | Hypium 真实结果 19/19，文本和 HTML 报告均生成 |
| 关键成功/失败路径有特征测试 | 通过 | 6 个分组；队列/ACK 的直接生产测试延后至 Phase 2 |
| Debug 串行干净构建 | 通过 | clean 后 4.174 s 成功 |
| Release 串行干净构建 | 通过 | clean 后 3.898 s 成功 |
| 不改变协议、格式、路径和页面行为 | 通过 | 未改 wire 常量、JSON schema/version、路径常量、录音参数或页面；用户确认真机录音回归没有问题 |
| 不触碰设备和现存录音 | 通过 | 全程仅本地源码、Previewer 临时目录和构建产物 |

真机结论来自用户验收反馈；本报告没有收到对应录音时长、文件大小、播放结果或 SHA-256，因此只记为“录音功能正常”的用户确认，不扩展为文件完整性、长时熄屏或跨设备同步验收。

下一步若获批准，才进入 Phase 1：提取无状态共享 I/O 和 WAV 基础设施。
