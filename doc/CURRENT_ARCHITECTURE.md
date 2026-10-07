# AllDayRecording 当前架构

> 文档状态：`current`
> 核对日期：2026-10-07
> 适用源码：当前工作区的工程整改分支状态。整改尚未完成统一验收；下述新增边界以源码和局部测试为准。

## 1. 交付与兼容边界

工程当前构建一个包含两个设备类型互斥 HAP 的 `.app`：

- Watch `entry` HAP：`deviceTypes = [wearable]`，保留麦克风、持续任务、振动和 `audioRecording` 后台模式。
- Phone `phone` HAP：`deviceTypes = [phone]`，不声明录音权限或后台录音模式。
- `common` HAR：两端本地依赖的模型、共享状态、文件基础设施、协议、Transport、协调器和播放实现，不单独安装。

应用版本为 `1.0.1`（`versionCode = 1000001`，`buildVersion = 2`），目标 SDK 为 API 26，最低兼容 HarmonyOS `6.1.0(23)`。`bundleName`、Client ID 和签名配置保持不变；Watch 继续使用 `entry` 模块名，Phone 使用独立 `phone` 模块。Phone 沙箱不从原 `entry` 沙箱自动迁移；安装前双份只读备份仅是设备外的数据保护证据，不是应用回退入口。用户于 2026-08-30 确认双端覆盖安装完成且真机验收通过，Phase 6 物理拆分获准进入主线。

## 2. 依赖方向

```text
Watch HAP -> Watch Root/ViewModel -> recording / Watch Sender
Phone HAP -> Phone Root -> V3 ViewModel -> v3/runtime -> native receiver / recording store
                       -> computer transfer VM -> QR/mDNS/HTTPS/HUKS upload service
                         both -> common HAR -> coordinator -> transport / shared IO
```

- `entry/.../pages/Index.ets` 只挂载 `WatchRootPage`；`phone/.../pages/Index.ets` 只挂载 `PhoneRootPage`，不做运行时设备分支。`PhoneRootPage` 只组合 V3 本地优先工作台和 `v3/runtime`，没有备用页面或只读入口。
- Phone `EntryAbility` 固定加载 `pages/Index`，启动错误使用稳定日志标签 `PhoneEntryAbility` 和正式的 Phone root page 文案；协议中的 `control_probe` 与默认关闭的 Watch 诊断 Probe 保持原有语义。
- 页面组件只展示状态并转发事件，不直接操作 CoreFileKit、Wear Engine 或录音后台任务。
- ViewModel 负责页面生命周期、UI 状态和用户动作编排；`PhoneSyncService` 在应用生命周期内持有唯一投影仓库、同步串行队列、运行状态和订阅。首页与 Computer 页面共享同一个 `PhoneV3UseCases.synchronize` 执行实现；旧 data 层的独立同步循环已移除。取消只影响该入口的排队或在途工作，不取消另一页面的请求。
- `PhoneV3ProjectionQueries` 负责首页摘要、Daily 缓存和按 session 游标分页的应用查询；只读 SQL 在 `PhoneProjectionQueriesStore`，纯投影映射在 `PhoneV3ProjectionMapping`。`PhoneV3AnnotationCommands` 负责标注与转写修订的原子 outbox 命令；`PhoneV3ReviewCommands` 校验审核证据并构造请求；`PhoneReviewAudioPrefetch` 负责最多三个可见审核样本的缓存准备和退避定时。`PhoneV3ApplicationSession` 组合本地音频、远端、Calendar、备份与音频缓存适配器；ViewModel 保留展示与生命周期调用。查询 `loadCached()` 不触发外部同步、Calendar 或权限流程。
- `PhoneProjectionRepository` 是 `PhoneSyncService` 唯一持有的数据库事务入口及同步投影写入协调器。转写/投影读取、Calendar mapping、离线声音审核队列分别委托给 `PhoneProjectionQueriesStore`、`PhoneCalendarMappingStore`、`PhoneReviewQueueStore`；各组件共享同一个 RdbStore，写入通过同一事务入口串行化。页面不创建另一个投影数据库实例。
- `common/src/main/ets/sync/transport/WearEngineTransport.ets` 是原始 Wear Engine 调用边界。
- `common/src/main/ets/shared/io` 和 `entry/.../recording/WavSegmentSlot.ets` 是耐久文件边界。
- Watch Sender 留在 Watch HAP；Phone Receiver、接收索引、播放与 Wi-Fi 生命周期统一位于 `phone/.../v3/runtime`，避免把对端专属 API 打入错误设备包。
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
4. Phone 原子复制带 V3 来源描述的文件，核对大小并计算 SHA-256；Wi-Fi 入口先核对发送方摘要。`PhoneV3RecordingStore` 在音频旁原子写入 v2 `.receipt.json`，保存 recording ID、原始 session key、`sourcePath`、request、exact key、大小、SHA-256 和接收时间。receipt 写入失败会抛错，两个入口均不得发送成功 ACK。receipt 的 `sessionKey` 保留发送端目录（如 `pcm_session_1760000000000`）；Computer manifest 根据目录时间规范化为 `watch-session:1760000000000`，ASR ingest 与 Phone 会话投影均使用后者作为跨端 session identity。
5. `received_index_v1.json` 是可重建索引。重启时 Phone 从每个新录音旁的 receipt 恢复可信 session ownership；仅有音频而无 receipt、也无旧 index 的文件保留在磁盘供修复，不会被当作已确认录音、去重库存或电脑 manifest 来源。旧版 index 中已有的持久条目仍可展示并按原兼容规则组成清单，但在取得 receipt 前不会被作为重传成功的 ACK 证据。
6. 只有音频内容及 receipt durable 后，Phone 才发送 `sync_file_received` 或 Wi-Fi ACK。ACK 前崩溃时，重启可从 receipt 恢复并幂等补发；Watch 在 ACK 丢失或通信失败时保留源文件并重试。
7. 普通 Wear Engine 同步不删除 Watch 源文件。加密 Wi-Fi 全量同步会对新文件和 Phone 已有文件逐一核对 SHA-256；只有所有文件 ACK 及批次 ACK 完成后，Watch 才重新核对路径、大小和 SHA-256 并删除本批快照中的源文件。批次失败时一个也不删，单文件清理失败时只保留该文件；进程重启后可通过 Phone 的重复文件校验继续清理。
8. Phone 到电脑的传输使用 `computer` 目录中的二维码配对、mDNS、HUKS/HTTPS、清单和断点上传。`PhoneComputerTransferViewModel` 负责页面状态，投影仓库、同步互斥、取消和重建入口归 `PhoneSyncService`。页面直接客户端由服务适配到同一 `PhoneV3UseCases.synchronize`。`loadCached()` 不执行 Calendar reconciliation；页面生命周期显式调用 `reconcileCalendar()`。
9. 手机扫码验证并固定电脑 CA 的 DER SHA-256 指纹，以首次配对码和系统 Passkey 授权登记 HUKS P-256 设备公钥。后续每个受保护请求都用一次性 challenge 生成静默设备签名，绑定 method、path、正文 SHA-256 和分片 offset，不保存访问令牌；换 Wi-Fi 通过稳定 `receiver_id` 自动重新发现电脑地址。
10. 上传以 receipt 恢复的 `ReceivedRecordingFile.sourcePath` 确认原 Watch 会话路径，先传全部音频，再生成并上传当前 `AllDayRecording session manifest v2` 清单。电脑确认最终 SHA-256 后才计为完成，手机原文件始终保留。
11. 审核收件箱以电脑当前待审集合为唯一事实来源：Phone 完成普通 V3 增量同步后，通过同一套 CA 固定、HUKS 设备签名和一次性 challenge 拉取审核快照，并用整批替换方式缓存为 `review_item` 投影。离线时只展示该快照；提醒、人物记忆、事件提案、未知人物和已知人物声音样本的决定都必须在线提交，电脑会再次确认条目仍待审后才执行并返回最新快照。已知人物声音只允许逐样本决定，当前证据的所有窗口完整播放结束后才开放确认或拒绝，不提供整组确认；页面展开状态不写入审核数据，单个样本处理后只要组内仍有待审项就保持展开。声音样本按有序窗口由电脑制作可复用的单声道 WAV（单次裁剪最多 15 秒、总窗口最多 40 秒），并以约 −20 LUFS、−3 dB 峰值上限做试听响度归一化；原始录音和手机系统媒体音量均不改变。

### 审核音频持久准备与前台同步（2026-09-26）

审核元数据现在可携带 `audio_content_key`：电脑由不可变内容地址、源副本版本、按序窗口、PCM/响度配置生成；它与审核 `review_key`、完整试听凭证分别管理。手机用本地受信 receiver/CA/device/RP/key-alias 命名空间查缓存，IP 变化不改变身份。命中路径只读取本地配置和投影，不先发现或认证电脑；缺少新字段的旧条目仍走原有受保护在线播放。

手机 `PhoneV3ReviewAudioCache` 使用私有派生目录，文件名为摘要；单项最多 16 MiB、总音频预算 64 MiB、最多 48 项，最多 4 个共享任务，制作/下载按队列串行。当前及后两项串行预取；前台请求提升尚未开始的预取，已运行共享任务可安全完成，取消页面不取消其他等待者。`@Concurrent` 工作函数负责 Base64、SHA-256 和文件 IO，以临时文件、原子改名、索引发布；播放租约阻止清理在用文件。完成、暂停和退出播放器只释放租约，保留可复用缓存。损坏、缺失、源身份改变按 miss 恢复；清理仅限派生目录。本地录音删除前释放播放器并清理派生缓存，不改变原录音保护规则。

审核页只在内容窗口或生命周期变化时调整预取；进入审核页通过已有 coordinator 触发轻量拉取，页内 15 秒轮询，普通空闲前台仍按既有 120 秒节奏，不新增同步轮询器。同窗口预取区分完成、在途和失败需求；最多三项失败合并为一个有界截止任务，临时错误按 60/120/240/300 秒退避，网络或前台恢复也可重新评估。授权/身份问题阻止盲重试；离页、后台和 stop 清除截止任务。后台/停止取消后续预取；旧页面退出只可停止其拥有的播放代次，不能误停新页面的播放。缓存可用、完整听完、决定提交分别显示和校验。离线可听本机已知证据，决定仍由电脑核对当前资格。

Wear Engine wire JSON、requestId、同步目录相对结构和重试/超时参数继续兼容 Phase 2；源文件删除仅发生在独立的 Wi-Fi 加密传输路径，不改变普通同步协议。原 Phone `entry` 沙箱内容不会自动迁入新 `phone` 沙箱；设备外备份不参与应用运行时，这是已由用户接受的数据可见性变化，不是 wire 协议变化。

### Calendar reconciliation

`CalendarReminderScheduler` 在提交系统 create 前先持久化 `creating` 意图。create 回包丢失时，本地 event ID 可以暂为 `-1`；用户取消或完成后，调度器仍按应用 Calendar account 和稳定 identifier 查找、删除并再次确认不存在，之后才把本地 mapping 标为 `removed`。重复 reconcile 幂等。`PhoneV3UseCases.loadCached()` 只读取缓存投影；Calendar reconcile 由页面生命周期显式调用。

### Transcript 分页与查询成本

首页只读取 session/processing 摘要及每个 session 的 utterance 计数，不解析全历史 transcript。进入 session 后，`PhoneProjectionRepository.sessionUtteranceRows` 用 session ID、游标和 `LIMIT 50` 读取一页，滚动末端才加载下一页；计数控制 `hasNext`。搜索使用 SQLite 查询，Daily 来源播放按 utterance ID 和 revision 查询，不依赖首页缓存。标注冲突只读取其涉及的 utterance ID。同步更改已打开页时，页游标失效并从首个 SQL 页重新加载。

人物页的跨 session 分组需要完整发言集合；仅在用户打开该页时，ViewModel 才通过同一 session 游标分页查询补齐发言，首页和单 session 首次打开不会为它预加载全历史。人物键使用稳定 person ID，同名人物仍分别成组。

## 5. 系统能力与编译提示

既有 Phase 5/6 的能力边界仍在源码中；本轮 Code Linter 与完整构建结果以统一最终验收为准，不沿用旧报告数字。

本地 `build-profile.json5` 被忽略且包含私人签名参数，不能提交。仓库提供的 `build-profile.example.json5` 将 `entry@watch` 映射至 `default` product、`phone@default` 映射至 `phone` product。本机旧 profile 曾把 Phone target 错映射到 `default`，本轮只更正本机映射，未改动签名字段。当前 DevEco SignHap 的 ZIP64 兼容问题可在构建进程内设置 `JAVA_TOOL_OPTIONS=-Djdk.util.zip.disableZip64ExtraFieldValidation=true`；这不是生产签名配置的变更。构建是否通过以最终统一验收为准。

仍保留的能力提示有明确边界：

| 提示范围 | 运行时保护 | 保留理由 |
| --- | --- | --- |
| `AudioCaptureLifecycle` 的 AudioKit 能力 | 创建采集器前调用 `canIUse('SystemCapability.Multimedia.Audio.Capturer')` | 只在 Watch 录音入口执行；枚举/创建调用仍会被多设备编译静态提示 |
| `AudioPlaybackService` 的 AVPlayer 能力 | 播放前调用 `canIUse('SystemCapability.Multimedia.Media.AVPlayer')` | `common` HAR 供两端依赖，设备不支持时显式失败 |
| Phone 电脑传输的 ScanKit、mDNS、FIDO2、HUKS、证书、HTTPS 与 SHA-256 能力 | 首次配对由系统扫码页读取电脑二维码；上传前以 mDNS 发现稳定接收端；页面初始化及登记入口检查 FIDO2，HUKS 私钥不可导出；CA 导入检查 Cert/CryptoFramework，HTTP 客户端检查 NetStack/CryptoFramework，异常显式返回；Phone HAP 最低 API 23 | 仅由用户从 Phone 设置页触发；RP 域名必须先在 AGC/App Linking 与应用关联，日常上传使用设备签名，不提供令牌降级 |
| Watch `RecordingTransferService` 的 Wear Engine sender API | Transport 连接前检查 `SystemCapability.Health.WearEngine` | 仅打入 Watch HAP；API 23 兼容调用点仍会产生静态能力提示 |
| `diagnostics/legacy/AvRecorderGapBaseline` 的 AVRecorder 与麦克风权限 | `RecordingDiagnosticsPolicy` 默认关闭，构造前即拒绝；生产 UI 无入口 | 仅由业务测试编译以防历史基线腐化，相关能力/权限提示只出现在测试源码图 |

这些提示不能通过关闭规则隐藏。若未来出现新的能力提示，必须补充设备范围、调用路径、保护条件和真机证据。

## 6. 复审阈值与当前例外

软阈值：单文件超过 500 行、单类可变字段超过 25 个或一个改动横跨 UI/Transport/Storage 三层时必须说明理由。

当前已知例外：

- Watch `entry/.../RecordingTransferService.ets` 只保留 Sender facade；Phone Receiver 已迁入 `phone/.../v3/runtime/PhoneV3WearEngineReceiver.ets`。两者与协议、Transport、Queue、协调器和接收 Store 物理隔离；后续新增功能不得把协议或存储实现塞回 facade。
- `presentation/watch/WatchRecordingViewModel.ets` 约 591 行且可变字段超过 25 个。它是 Watch 页面生命周期与录音/播放/同步展示的编排层，不直接实现 Transport 或 Storage；下一次修改其状态集合时应优先拆分权限/通知或计时子状态。
- `PhoneV3DeviceRuntime` 的原生生命周期状态仍超过 25 个字段，但传输与状态转换已经委托给协调器，并经 `PhoneV3DeviceRuntimeAdapter` 映射为不可变应用状态。若增加第三类同步状态，应先拆分运行时子状态。
- `PhoneProjectionRepository.ets` 保留 schema migration、同步 receipt/outbox、投影发布和本地音频关联的事务协调职责。Calendar mapping、声音审核队列与转写查询 SQL 已拆成专用存储组件；迁移脚本仍与数据库入口同文件，后续修改 schema 时应复核这一边界。它不是 ViewModel 的扩展点。

阈值例外不是永久豁免；每次触碰相关文件都要重新核对。

## 7. 当前测试矩阵与证据边界

开发阶段仅运行受影响模块的编译级检查、lint 和单个合成回归测试。最终统一验收会运行 Phone/Watch/common 宿主机与 Hypium 可执行项目、Phone 构建、Code Linter、跨仓库合同校验，以及录音接收、Calendar、并发同步和分页性能故障注入。最终数量和失败项以 `ENGINEERING_REMEDIATION_REPORT.md` 为准；本文件不沿用历史 Phase 6 报告数字。

Phone/Watch 真机录音、系统 Calendar 和音频播放只有设备测试才能证明。没有设备时标记 `NOT_RUN_DEVICE_ONLY`，宿主机 fake/fixture 的通过不冒充实机。所有故障注入使用临时目录、合成录音、临时 SQLite 和 fake Calendar/remote；生产录音、Calendar、用户确认任务和语义结果不参与测试。
