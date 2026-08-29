# AllDayRecording 项目可维护性重构计划

## 1. 文档目的

本计划用于在不改变现有录音、恢复、同步和播放行为的前提下，逐步降低 AllDayRecording 的文件体量、职责混杂、状态耦合和回归风险。

执行原则是：先建立可重复验证的行为基线，再按边界拆分；每个阶段独立验收、独立提交，未通过验收时不进入下一阶段。

## 2. 当前基线（2026-08-29）

当前主 ArkTS 代码共 5,573 行，主要集中在以下文件：

| 文件 | 行数 | 当前主要职责 |
| --- | ---: | --- |
| `entry/src/main/ets/services/RecordingTransferService.ets` | 2,029 | Wear Engine 建链、消息路由、手动同步、自动队列、重试、ACK、远程控制、手机接收与文件落盘 |
| `entry/src/main/ets/pages/Index.ets` | 1,379 | 手机/手表 UI、录音、播放、权限、恢复、通知、远程控制、同步进度和开发者界面 |
| `entry/src/main/ets/services/PcmSegmentedRecordingService.ets` | 663 | AudioCapturer 生命周期、PCM 队列、WAV 分段、后台任务和会话摘要 |

已确认的质量基线：

- `Index.ets` 包含 32 个 `@State` 和多套手机/手表页面。
- `RecordingTransferService.ets` 包含 Sender、Receiver 以及约 70 个私有状态字段。
- 唯一的 `entry` 模块同时声明 `phone` 和 `wearable`。
- 本地单元测试和 `ohosTest` 仍为模板断言，没有覆盖业务行为。
- `code-linter.json5` 已存在，但 Hvigor 中没有注册 `codeLinter` 任务。
- 干净 Debug 构建成功，但产生 79 个 ArkTS 警告。
- `AudioRecordingService.ets` 和 `SleepModeProbeService.ets` 当前未被生产入口引用。
- WAV 头生成、底层写入和 JSON 清单写入存在重复实现。
- 部分阶段文档描述的分段时长、同步数量和持久化能力与当前实现不一致。

上述数字只作为重构前基线。每个阶段开始前都要重新盘点，避免依据过期数据执行。

## 3. 硬约束

### 3.1 必须保持不变

除非进入单独批准的协议或数据迁移阶段，以下行为不得改变：

1. Watch 端最低兼容 API 23，API 26 能力必须继续使用运行时保护或兼容降级。
2. AudioCapturer 在一个录音会话内持续运行，WAV 按采样点切分，不允许重新引入 AVRecorder 轮换空洞。
3. 已封口 WAV 使用 `.part`、回写 WAV 头、`fsync`、关闭和原子重命名的顺序。
4. 中断恢复保留已经落盘的 PCM；无法安全恢复的文件必须保留证据，不得静默删除。
5. 手表源录音在同步成功、失败或重试后都继续保留，不得新增自动删除。
6. 手机只有在文件完成持久化后才能发送 ACK。
7. 自动同步和手动同步继续串行，不能让网络发送阻塞 AudioCapturer 数据回调。
8. 当前文件路径、JSON 清单版本、Wear Engine 消息字段和消息类型保持兼容。
9. 开发者/诊断功能可以移动和隔离，但不能在未确认用途前直接删除。

### 3.2 本计划前半段明确不做

- 不改变录音格式、采样率、声道数和分段时长。
- 不改变手机/手表包名、签名身份、Client ID 或 Wear Engine 审批配置。
- 不把手机和手表立即拆成独立 HAP；先完成逻辑边界拆分和构建可行性验证。
- 不在纯结构重构中加入 SHA-256 协议字段、断点续传、后台接收或云端能力。
- 不通过复制、覆盖或清空应用沙箱来制造“干净测试环境”。

## 4. 数据保护与真机前置条件

任何可能安装到 Watch 5、触发启动恢复、读取自动同步清单或改变文件索引的构建，都必须先执行以下检查：

1. 重新确认目标设备是 WATCH 5，而不是连接中的手机。
2. 对当前应用沙箱做只读导出，覆盖所有非空录音会话、清单和 `.part` 文件。
3. 至少生成两份独立的文件数量、总字节数和 SHA-256 清单，并逐项比较一致。
4. 保存安装前清单；安装和验收后再次导出并说明所有新增、修改或消失的文件。
5. 未完成备份或发现清单不一致时，停止安装和真机测试。

结构重构的本地构建不需要访问或修改设备数据。

## 5. 目标职责结构

第一阶段采用同一 `entry` 模块内的逻辑分层，降低一次性改变打包结构的风险：

```text
entry/src/main/ets/
  app/
    AppBootstrap.ets
    AppLifecycleCoordinator.ets
  phone/
    pages/
      PhoneHomePage.ets
      RecordingHistoryPage.ets
      PhoneSettingsPage.ets
      PhoneDeveloperPage.ets
    viewmodels/
      PhoneRecordingViewModel.ets
  watch/
    pages/
      WatchHomePage.ets
      WatchDeveloperPage.ets
    viewmodels/
      WatchRecordingViewModel.ets
  recording/
    capture/
      PcmCaptureSession.ets
    storage/
      WavSegmentWriter.ets
      RecordingSessionStore.ets
      InterruptedRecordingRecovery.ets
    lifecycle/
      BackgroundRecordingController.ets
  sync/
    protocol/
      WatchSyncMessages.ets
      WatchSyncCodec.ets
    transport/
      WearEngineTransport.ets
    watch/
      WatchSyncCoordinator.ets
      AutomaticSyncQueue.ets
    phone/
      PhoneSyncCoordinator.ets
      ReceivedRecordingStore.ets
    control/
      WatchRecordingControlCoordinator.ets
  playback/
    AudioPlaybackService.ets
  shared/
    io/
      AtomicFileWriter.ets
      AtomicJsonStore.ets
      WavFormat.ets
    models/
  diagnostics/
    AvRecorderBaseline.ets
    SleepModeProbeService.ets
```

该树是职责目标，不要求一次创建全部文件。拆分以依赖方向和可测试性为依据；行数只作为复审信号，不为追求短文件而制造无意义包装层。

期望依赖方向：

```text
Pages -> ViewModels/Coordinators -> Domain services -> Transport/Storage adapters
                                  -> Shared models and pure utilities
```

页面不得直接操作 `fileIo`、Wear Engine、后台任务或协议消息；Transport 和 Store 也不得直接修改 ArkUI 状态。

## 6. 分阶段执行计划

### Phase 0：冻结行为基线并建立特征测试

执行状态（2026-08-29）：已完成 Phase 0。实际 Hypium 报告为 19/19 通过，Debug/Release 均在独立 `clean` 后构建成功，用户随后确认真机录音没有问题；详细架构、测试、警告和构建证据见 `doc/MAINTAINABILITY_PHASE_0_BASELINE.md`。Codex 本阶段未安装或访问设备，队列/ACK 的直接生产状态机测试仍按计划在 Phase 2 用 fake transport/fake clock 替换当前同契约模型。

目标：在移动代码前，先把当前真实行为固化为可重复验证的测试和清单。

任务：

1. 建立当前架构和依赖快照，记录文件行数、入口引用、公开类型和构建警告分类。
2. 确认可用的本地测试任务；若模板未注册测试任务，先完成最小测试运行配置。
3. 为纯逻辑建立特征测试：
   - 协议消息编码/解码及非法版本拒绝。
   - exact key 与 legacy key 的兼容行为。
   - 自动队列恢复、缺失文件、损坏 JSON 和重复入队。
   - 接收索引加载、目录扫描、重复记录和损坏索引恢复。
   - 重复 ACK、过期 requestId、乱序消息和超时后的状态清理。
   - WAV 头字段、短写循环、空 `.part`、合法 `.part` 和超限 `.part`。
4. 把测试文件全部改为业务命名，删除 `abc contains b` 模板断言。
5. 建立警告清单，区分：未处理异常、系统能力提示、API 兼容提示和可接受的 SDK 警告。

验收标准：

- 测试命令可重复执行并产生实际报告，不以“测试源码能编译”代替测试通过。
- 上述关键行为至少各有一个成功路径和一个失败路径测试。
- Debug 和 Release 串行干净构建通过。
- 不修改任何生产协议、文件格式、存储路径或页面行为。

建议提交：`test: establish maintainability refactor baseline`

### Phase 1：提取无状态共享基础设施

执行状态（2026-08-29）：已完成，用户已确认真机回归通过。当前 Hypium 报告为 27/27 通过，`entry@ohosTest` 测试 HAP、独立 clean Debug 和 Release 构建均成功；路径、JSON schema/version、WAV 格式、录音参数和 wire 协议未改。真机回归期间发现 Wear Engine 核心接收通道卡住后仅重新注册回调不足以恢复，因此追加了 `stop -> destroy -> start` 的硬重连和重复点击保护；原先积压的第三段随后进入手机索引。详细迁移、字节/失败语义、警告保留依据及真机证据见 `doc/MAINTAINABILITY_PHASE_1_SHARED_IO.md`。

目标：先消除最容易验证的重复逻辑，为后续拆分提供稳定底座。

任务：

1. 提取 `WavFormat`：格式常量、WAV 头生成、LE 写入和完整写入工具。
2. 提取 `AtomicFileWriter`：`.part`、`fsync`、关闭、重命名和失败保留策略。
3. 提取 `AtomicJsonStore`：临时文件写入、`fsync`、原子替换、版本校验和损坏文件回退。
4. 让 PCM 分段、恢复服务、自动队列和接收索引复用这些组件。
5. 保留原有 JSON 字段、版本号、目录和最终文件名。

验收标准：

- 共享工具有独立单元测试，覆盖短写、异常关闭和损坏 JSON。
- 中断恢复与正常封口的输出字节和原实现一致。
- 不改变任何现有清单 schema。
- 修改文件中的未处理异常警告清零或给出有证据的保留说明。

建议提交：`refactor: extract durable file and wav primitives`

### Phase 2：拆分 Wear Engine 传输与同步状态机

目标：把 2,029 行传输文件拆成可独立测试的协议、Transport、Watch 协调器和 Phone 协调器。

执行顺序：

1. 把对端发现、应用身份、接收器注册和原始 `sendMessage/transferFile` 封装为 `WearEngineTransport`。
2. 把协议常量、消息类型和编解码移动到 `sync/protocol`，第一轮保持线上 JSON 完全兼容。
3. 把自动队列及其清单移动到 `AutomaticSyncQueue`。
4. 把 Watch 端手动同步、自动同步、重试和 ACK 等待移动到 `WatchSyncCoordinator`。
5. 把 Phone 端清单分页、文件接收、持久化和进度移动到 `PhoneSyncCoordinator`。
6. 把远程录音控制握手从文件同步中分离到 `WatchRecordingControlCoordinator`。
7. 用显式状态对象替代相互组合的布尔字段；状态转换集中在少数方法内。
8. 原 `RecordingTransferService.ets` 暂时保留兼容 facade，调用方稳定后再删除 facade。

必须覆盖的状态测试：

- 自动同步进行中收到手动同步请求。
- 传输完成但 ACK 丢失。
- 进度 60 秒不变与传输完成后 ACK 超时。
- Wear Engine `206`、对端重连、重复消息和重复文件。
- Phone 已保存文件但 Watch 未收到确认。
- 页面退出时启动任务尚未完成。
- 控制命令处于 `pending_user_action` 时的最终 ACK 和五分钟超时。

验收标准：

- Wire JSON、requestId 规则、路径、重试次数和超时值不变。
- 自动/手动串行和源文件保留行为不变。
- 各协调器可使用 fake transport、fake clock 和临时目录进行测试。
- 不再由一个类同时承担 Transport、Queue、Storage、文件同步和录音控制。
- Debug/Release 构建、业务测试和协议 golden fixtures 全部通过。

建议拆成 2–3 个小提交，但每个提交都必须可构建、可回退。

### Phase 3：拆分手机/手表页面与业务状态

目标：把 `Index.ets` 从业务控制中心降为最小设备入口。

任务：

1. 创建 `PhoneRecordingViewModel` 和 `WatchRecordingViewModel`，集中持有各端状态。
2. 将手机首页、录音记录、设置、开发者页面拆成独立组件。
3. 将手表首页和手表开发者页拆成独立组件。
4. 把录音权限、通知授权、同步请求、播放和计时操作移出 Builder 方法。
5. 将多项同步进度字段聚合为单一不可变 UI 状态对象。
6. 把 `aboutToAppear/aboutToDisappear` 中的异步资源启动和释放交给生命周期协调器，明确等待、取消和错误处理。
7. `Index.ets` 仅负责设备类型选择和挂载对应 Root 页面。

验收标准：

- 手机与手表页面不再通过大量 `if (isWearable)` 共享同一组件。
- Builder 只负责展示和事件转发，不直接实现文件、协议或权限业务。
- 页面消失后没有未观察的 Promise、活动计时器或重复 Wear Engine receiver。
- 圆屏布局、手机导航、开发者入口和 API 26 视觉保护保持不变。
- Watch 5 真机视觉和录音入口验收单独记录，不以 Previewer 代替。

建议提交：`refactor: separate phone and watch presentation state`

### Phase 4：整理录音领域与诊断代码

目标：区分生产录音链路、历史基线和诊断工具。

任务：

1. 把 AudioCapturer 生命周期、WAV 文件槽、会话摘要和后台任务控制拆成明确组件。
2. 将 `pcm_gap_test_*` 等实验命名迁移设计单独评审；未制定兼容迁移前保持现有目录可读。
3. 把旧 AVRecorder 基线和 Sleep Mode Probe 移入 `diagnostics`，明确编译是否保留、生产 UI 是否可达。
4. 清理未使用导出、模板 BackupAbility 和默认包描述；任何删除先确认没有设备流程、文档或调试脚本依赖。
5. 为诊断代码建立显式开关，避免生产首页直接承载实验逻辑。

验收标准：

- 生产录音路径不依赖诊断服务。
- 现有录音目录和恢复扫描仍可读取旧命名。
- 录音回调不执行网络传输、复杂 JSON 写入或耗时 UI 操作。
- 正常停止、异常停止、进程中断和后台录音的测试全部通过。

建议提交：`refactor: isolate recording diagnostics and lifecycle`

### Phase 5：接通质量门禁并修正文档

目标：让后续膨胀和文档漂移能被自动发现。

任务：

1. 正确注册 lint 任务，使 `code-linter.json5` 真正参与验证。
2. 对“Function may throw exceptions”逐项处理，不允许只通过关闭规则消除警告。
3. 对系统能力警告记录设备范围、运行时保护和保留理由。
4. 新增项目 README，说明模块、数据流、构建、测试、API 23 约束和真机验收边界。
5. 新增当前架构文档；历史 Phase 文档增加 `current/superseded/experiment` 状态。
6. 修正“一次 100 个”“历史索引未持久化”“5 秒分段”等已经失效的描述。
7. 增加软性复审阈值：单文件超过 500 行、单类可变字段超过 25 个或跨越 UI/Transport/Storage 三层时必须说明理由。

验收标准：

- lint、单元测试、Debug 构建、Release 构建有固定命令和实际报告。
- 修改过的生产文件没有未解释警告。
- README 与当前代码一致，历史文档不会再被误认为当前产品行为。
- 构建输出、签名材料、日志、设备备份和本地配置不进入 Git。

建议提交：`chore: enforce project quality gates and current documentation`

### Phase 6：评估物理拆分 Phone/Watch 模块

目标：在逻辑边界稳定后，判断是否把单一 `entry` 拆成按设备交付的 HAP。

先做只读/构建可行性审计：

1. 确认 HarmonyOS 当前工程模型对同一应用身份、Phone HAP、Wearable HAP 和 Wear Engine 对端匹配的要求。
2. 建立最小分支或独立实验提交，验证包名、签名、Client ID、appIdentifier 和 API 23 minAPIVersion。
3. 验证拆分后 Phone 不再声明麦克风/录音后台模式，Watch 不再打包手机页面。
4. 在不清除应用数据的升级路径上验证两端安装和文件保留。

只有构建、签名、升级和 Wear Engine 身份全部验证后，才批准物理拆分。若平台约束不适合拆分，则保留单模块，但继续使用清晰的 phone/watch 源码边界。

### Phase 7：单独设计内容完整性协议升级

该阶段不是纯重构，必须另行批准。

候选任务：

1. 在 Watch 5 API 23 上基准测试 SHA-256 对 1 分钟分片及历史批量文件的耗时、内存和功耗。
2. 为协议增加可选 `contentDigest` 和算法字段，设计 v1/v2 双向兼容。
3. Phone 在落盘、`fsync` 并校验摘要成功后才 ACK。
4. 迁移现有接收索引，保留 path+size 作为兼容信息，不能把弱 identity 当作内容完整性证明。
5. 用真实 Watch 源文件和 Phone 副本做独立 SHA-256 比较。

该阶段不得与 Phase 2 的结构拆分混在同一个提交中。

## 7. 验证矩阵

| 层级 | 必须验证的内容 | 不能替代的证据 |
| --- | --- | --- |
| 纯逻辑 | 协议、状态转换、队列、索引、WAV、恢复 | “能够编译”不能替代测试报告 |
| Debug 构建 | ArkTS、资源、HAP、签名、API 23 最低版本 | Debug 成功不能替代 Release |
| Release 构建 | 串行 clean 后完整 Release HAP | Release 成功不能替代真机 |
| Watch 5 | 开始/停止、至少两个完整分片、最后短分片、熄屏、恢复 | 页面计时不能替代最终文件检查 |
| Phone/Watch | 自动同步、手动补拉、ACK 重试、播放 | 进度 UI 不能替代最终字节完整性 |
| 数据保护 | 安装前后文件数、字节数、SHA-256 清单 | 单次导出不能替代独立复核 |

推荐的构建环境：

```sh
PATH=/Applications/DevEco-Studio.app/Contents/tools/node/bin:/usr/bin:/bin:/usr/sbin:/sbin \
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
clean assembleHap --mode module -p product=default -p module=entry@default \
-p buildMode=debug --no-daemon
```

Release 必须在 Debug 完成后再次 clean，避免共享 `entry/build` 造成产物混淆。测试命令以 Phase 0 实际注册并能生成报告的任务为准，不能预先把不存在的任务写成已验证流程。

## 8. 提交与审查规则

1. 每次只执行当前已批准的 Phase 或其明确子步骤。
2. 开始前记录 `git status --short --branch`，保护用户已有修改。
3. 不顺带修改相邻 UI、协议或产品行为。
4. 只暂存明确允许的文件清单，不使用宽泛的 `git add .`。
5. 提交前检查：
   - `git diff --cached --stat`
   - `git diff --cached --name-status`
   - `git diff --cached --check`
   - 是否误包含证书、签名路径、设备备份、HAP、日志、`.DS_Store`、本地配置或测试录音
6. 文档必须更新到实际验证结果后才能提交。
7. 一个阶段未通过测试或真机门槛时，保留未完成状态，不把计划或构建成功写成验收完成。

## 9. 风险与缓解

| 风险 | 影响 | 缓解措施 |
| --- | --- | --- |
| 拆分过程中改变异步顺序 | 丢 ACK、重复同步、录音控制超时 | fake transport/fake clock 特征测试；保持超时和重试常量不变 |
| JSON Store 重构破坏清单 | 自动队列或接收索引丢失 | 旧 schema fixtures、损坏清单测试、原子替换、目录扫描回退 |
| 页面拆分改变生命周期 | receiver 重复注册、录音提前释放 | 生命周期协调器、取消测试、真机前后台验收 |
| 共享 WAV 工具改变字节输出 | 文件不可播放或恢复失败 | golden WAV 头、现有样本只读对比、PCM 区域逐字节比较 |
| 物理模块拆分改变应用身份 | Wear Engine 无法匹配或升级清数据 | Phase 6 独立可行性审计，不与逻辑重构合并 |
| 追求行数导致碎片化 | 文件变多但依赖更复杂 | 以职责和依赖方向为主，行数仅为复审信号 |

## 10. 阶段状态

| Phase | 状态 | 验收记录 | 提交 |
| --- | --- | --- | --- |
| Phase 0 行为基线与特征测试 | 未开始 |  |  |
| Phase 1 共享文件/WAV 基础设施 | 未开始 |  |  |
| Phase 2 Wear Engine 与同步状态机拆分 | 未开始 |  |  |
| Phase 3 Phone/Watch 页面与状态拆分 | 未开始 |  |  |
| Phase 4 录音领域与诊断隔离 | 未开始 |  |  |
| Phase 5 质量门禁与文档 | 未开始 |  |  |
| Phase 6 Phone/Watch 物理模块评估 | 未开始 |  |  |
| Phase 7 内容完整性协议升级 | 未批准 |  |  |

## 11. 整体完成标准

项目可维护性重构只有同时满足以下条件才算完成：

- 手机 UI、手表 UI、录音、播放、同步、Transport、Storage 和诊断代码有明确单向依赖。
- 不再存在同时跨越 UI、网络、存储和领域状态的巨型类。
- 关键状态机、文件格式、恢复、队列和索引都有可重复测试。
- lint/test/Debug/Release 验证可由固定命令执行，并保存实际结果。
- Watch API 23 兼容性、圆屏 UI、熄屏录音、文件恢复和 Phone/Watch 闭环有各自独立验收证据。
- 重构前的录音和同步数据得到保全；所有行为或协议变化都有单独迁移计划。
- 当前文档与实际代码一致，历史实验结论有明确状态标记。
