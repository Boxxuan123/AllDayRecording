# AllDayRecording 维护性下一步工作计划

> 文档状态：`active`
> 建立日期：2026-08-30
> 基线提交：`f4bf48e refactor: split phone and watch into separate HAPs`
> 适用范围：维护性重构 Phase 0–6 完成后的收尾、可靠性修补与后续演进约束

## 1. 当前结论

Phase 0–6 已经完成主要结构目标：Watch、Phone 和 `common` 在源码及交付物上分离，页面、ViewModel、领域服务、Transport、队列与耐久文件边界基本清楚。当前不需要再进行一轮全项目机械拆分。

下一步按以下顺序执行：

1. 先恢复可以出具真实结果的测试门禁。
2. 修复自动同步队列对“合法 JSON、异常元素”的恢复缺口。
3. 消除 Debug/Release 构建改写被跟踪文件的问题。
4. 清理遗留的实验阶段命名。
5. 对仍然偏大的 facade 和 ViewModel 采用“触发式拆分”，不以行数为唯一理由立即重构。

每个阶段单独审批、单独验证、单独提交。不得把 Phase 7 内容完整性协议升级混入本文的维护性工作。

## 2. 当前基线与已知问题

### 2.1 已验证基线

- Code Linter：0 defects。
- Watch `entry@ohosTest` 测试 HAP：构建成功。
- Debug：独立 `clean assembleApp` 成功。
- Release：再次独立 `clean assembleApp` 成功。
- Release `.app`：解包后恰好包含 Watch `entry` 与 Phone `phone` 两个 HAP。
- 测试源码：Watch 50 项、Phone 3 项，共 53 项；比 N0 多出的 7 项均为 N1 队列结构损坏恢复测试。
- 宿主机 Hypium：`hostTest` 已在允许本地 socket 的 Darwin 环境生成当前报告，Watch 50/50、Phone 3/3，合计 53/53 通过；受限环境仍会在 `Darwin` 后有界超时。
- 审查结束时 Git 工作区干净。

### 2.2 已知可靠性缺口

`common/src/main/ets/sync/watch/AutomaticSyncQueue.ets` 的清单校验只确认 `files` 是数组，没有校验数组元素。类似下面的合法 JSON 会通过第一层校验，但在恢复时解引用 `fileName` 或 `relativePath` 发生异常：

```json
{
  "version": 1,
  "updatedAt": 1000,
  "completedCount": 0,
  "files": [null]
}
```

该异常不会删除 Watch 录音源文件，但会令本次启动的手机同步监听失败。现有测试只覆盖 JSON 语法损坏，没有覆盖结构损坏。

### 2.3 已知维护性债务

- `common/BuildProfile.ets` 被 Git 跟踪，但 Release 构建会改写其中的模式常量与格式，使正常构建污染工作区。
- Phone `EntryAbility` 的错误日志仍包含 `phase6Probe` 和 `Phone probe page`。
- Watch Sender 约 918 行、Phone Receiver 约 906 行、Watch ViewModel 约 591 行，仍属于复审热点；当前边界已经比重构前清楚，不应仅为降低行数制造包装层。

## 3. 明确不在本轮范围内的内容

以下内容未经单独批准不得修改：

- Wire 协议版本、消息字段、requestId 语义和超时/重试值。
- path+size 文件身份规则及 Phase 7 的 SHA-256/contentDigest 协议。
- Watch 录音目录、WAV 参数、分片长度、`.part` 恢复语义和源文件保留策略。
- `bundleName`、Client ID、签名、API 23 最低兼容版本和双 HAP 模块名称。
- 旧 Phone `entry` 沙箱到 `phone` 沙箱的数据迁移。
- 页面布局、视觉样式、录音交互和新的产品功能。
- 设备文件的删除、重命名或为了测试而故意损坏真实队列清单。

## 4. Phase N0：恢复真实测试门禁

### 目标

在修改生产代码前，为当前 46 项测试取得可追溯的真实执行结果；不能把 ArkTS 编译成功、测试 HAP 构建成功或进程停在 `Darwin` 当作测试通过。

### 工作内容

1. 记录开始时的提交、工作区状态、DevEco Studio、SDK、Node、Hvigor 和 Hypium 版本。
2. 分别运行 `entry@default` 与 `phone@default` 宿主机测试，设置合理的有界等待时间，并记录停滞位置、退出码和报告搜索路径。
3. 检查现有测试 runner、Hypium 配置、生成的测试入口和报告目录，确认问题属于项目配置还是当前 Darwin runner 限制。
4. 若宿主机 runner 可以修复，只修改测试工具链或测试配置，不触碰生产行为。
5. 若宿主机 runner 确认不可用，建立受支持的设备测试执行路径；Watch 43 项与 Phone 3 项都必须有实际报告。
6. 如果仍无法取得结果，将本阶段标记为 `blocked`，保留完整证据并由用户决定是否允许后续阶段暂用“编译 + 构建 + 真机回归”的降级门禁。

### 验收标准

- 报告中明确显示测试总数、通过数、失败数、运行时间和目标环境。
- Watch 与 Phone 测试均有结果；总数应与当前 46 项源码一致，差异必须解释。
- 不以旧报告冒充当前提交结果。
- 测试执行后工作区仍干净。
- README 中的命令与实际可用执行方式一致。

### 建议提交

若需要修改测试工具链：

```text
test: restore reproducible phone and watch test reports
```

若无需修改源码，只形成证据，则不创建空提交。

执行状态（2026-08-30）：已完成。补齐 Phase 6 遗漏的 Phone ArkTS UTF-8 宿主机 mock，
并新增会校验报告新鲜度、源码测试数、失败数且带有界超时的 `hostTest` 门禁。当前真实报告为
Watch 43/43、Phone 3/3，合计 46/46 通过；Linter、`entry@ohosTest`、独立 clean
Debug/Release 与双 HAP 产物边界均通过。详细证据见
`doc/MAINTAINABILITY_PHASE_N0_TEST_GATE.md`。

## 5. Phase N1：加固自动同步队列清单恢复

### 目标

任何缺字段、错类型、`null`、非法路径或非法大小的队列元素都不得令 Watch Sender 启动抛异常；异常清单不得影响录音源文件。

### 建议修改范围

- `common/src/main/ets/sync/watch/AutomaticSyncQueue.ets`
- `entry/src/test/AutomaticQueueAndSyncState.test.ets`
- 必要时更新 `doc/CURRENT_ARCHITECTURE.md` 的恢复说明

不得顺带修改 Transport、wire 消息、ACK、同步批量大小或目录结构。

### 实现要求

1. 清单级校验必须确认文档对象本身、版本、计数值和 `files` 的运行时类型安全。
2. 元素级校验至少覆盖：
   - 元素必须为非空对象；
   - `relativePath`、`fileName` 必须为非空字符串；
   - 路径不得为绝对路径，不得包含 `..`；
   - `size` 必须是有限正数且不超过既有上限；
   - `durationMs` 必须是有限的非负数；
   - 文件类型继续只接受既有 `.wav`/`.m4a`，拒绝 `.part`。
3. 结构损坏应返回明确的 invalid/damaged 状态，不得向 `WearEngineRecordingSender.start()` 抛出未处理异常。
4. 不得因为清单异常扫描、删除、截断或重写录音源文件。
5. 对有效旧清单保持完全兼容，不改变 schema version。

### 必须新增的测试

- `files: [null]`：不抛异常，队列为空，返回异常状态。
- 缺少 `fileName` 或 `relativePath`：不抛异常。
- 字符串、零、负数或超过既有上限的 `size`，以及负数或非数字类型的 `durationMs`：拒绝。
- 绝对路径和包含 `..` 的路径：拒绝且不访问目标文件。
- 合法清单中存在缺失文件：继续保留当前“过滤无效条目并持久化剩余项”的行为。
- 完全合法的生产格式清单：恢复结果与当前行为一致。

### 验收标准

- Phase N0 确立的真实测试门禁通过，并有新报告。
- Code Linter 0 defects。
- `entry@ohosTest` 构建成功。
- 独立 clean Debug/Release 构建成功。
- Release `.app` 仍只有两个 HAP。
- 运行测试和构建后 Git 工作区干净。
- 如果安装到 Watch，必须先完成只读备份；真机只验证正常队列重启和同步，不故意损坏真实清单。
- Phone 收到文件后仍先持久化再 ACK，Watch 源 WAV 保留。

### 建议提交

```text
fix: harden automatic sync queue manifest recovery
```

执行状态（2026-08-30）：已完成。清单及元素会在候选文件访问前完成类型、计数、路径、
大小、时长和音频后缀校验；结构无效返回 `invalid`，损坏 JSON/空文档返回 `damaged`，
合法清单缺失项的过滤与剩余队列持久化行为保持不变。新增 7 项测试后当前真实报告为
Watch 50/50、Phone 3/3，合计 53/53；Linter、`entry@ohosTest`、独立 clean
Debug/Release 与双 HAP 产物边界均通过。详细证据见
`doc/MAINTAINABILITY_PHASE_N1_QUEUE_RECOVERY.md`。

## 6. Phase N2：消除构建产生的 Git 污染

### 目标

连续执行 Debug 和 Release 构建后，工作区必须保持干净；构建模式切换不得改写被跟踪的源码文件。

### 决策前检查

1. 确认 `common/BuildProfile.ets` 是否由 Hvigor 自动生成、何时生成以及是否必须存在于源码目录。
2. 再次确认生产代码、测试代码和构建脚本都没有导入它。
3. 从干净状态分别执行 Debug、Release，记录每次产生的精确 diff。
4. 确认干净检出或新 worktree 中能够重新生成所需文件。

### 优先方案

按以下顺序选择最小可行方案：

1. 若该文件可以稳定重建，将其移出版本控制并加入精确忽略规则。
2. 若必须保留，调整 Hvigor/HAR 配置，使生成内容写入已忽略的构建目录。
3. 若平台工具不允许前两种方案，记录限制并增加明确的构建洁净度检查；不得用自动 `git checkout` 掩盖未知源码变化。

### 验收标准

- 从干净检出开始，Debug 和 Release 分别 clean 构建成功。
- 每次构建后 `git status --short` 为空。
- `common` HAR、Watch HAP、Phone HAP 和最终双 HAP `.app` 均正常生成。
- 不扩大 `.gitignore` 到可能隐藏源码、配置或签名变更的范围。

### 建议提交

```text
build: keep generated build profile out of source changes
```

## 7. Phase N3：清理遗留命名并同步文档

### 目标

去除已经进入正式架构后的实验阶段命名，让日志和文档与当前 Phone/Watch 双 HAP 结构一致。

### 修改范围

- 将 Phone `EntryAbility` 中的 `phase6Probe` 改为稳定的 Phone 模块日志标签。
- 将 `Failed to load Phone probe page` 改为正式页面加载错误描述。
- 复查生产目录中是否还有只属于已结束 Phase 的日志标签；诊断目录内明确保留的 `Probe` 不在本次清理范围。
- 更新本文件和 `doc/CURRENT_ARCHITECTURE.md` 的执行状态。

### 验收标准

- 不改变页面路由和加载路径。
- Code Linter 通过。
- Phone HAP 和完整 Debug 构建成功。
- Git diff 只包含明确的命名与文档变更。

### 建议提交

```text
chore: replace phase probe names in phone startup logs
```

## 8. 后续大文件采用触发式拆分

当前不单独启动大范围拆分。出现以下任一条件时，先补测试，再从对应 facade 中提取一个完整职责：

- Watch 或 Phone `RecordingTransferService.ets` 新增超过约 100 行。
- 一个需求同时修改 UI、Transport 和 Storage 三层。
- 同一类新增第三组独立状态或更多并发任务。
- 修复一个问题需要同时修改同一 facade 中三个以上不相邻流程。
- 单元测试必须构造大量 Wear Engine 对象才能覆盖纯状态转换。

候选拆分方向：

- Watch Sender：库存分页会话、单文件发送/ACK 会话、自动队列调度。
- Phone Receiver：文件接收持久化会话、同步进度不可变快照、控制通道生命周期。
- Watch ViewModel：权限/通知状态、录音计时状态、页面生命周期清理。

拆分时必须保持当前公开入口、wire JSON、超时值、目录和设备行为不变。一次提交只提取一个职责，并使用 fake clock、fake transport 或 fake filesystem 覆盖其状态转换。

## 9. 每阶段统一验证矩阵

| 层级 | 必须证据 | 不可替代关系 |
| --- | --- | --- |
| 工作区 | 开始和结束的 `git status --short --branch` | 构建成功不能证明没有污染源码 |
| 纯逻辑 | 当前提交生成的真实测试报告 | 测试源码编译成功不能替代执行结果 |
| 静态检查 | Code Linter 完整报告且 0 defects | 普通 ArkTS 编译不能替代 linter |
| Debug | 独立 `clean assembleApp` | Debug 不能替代 Release |
| Release | 再次独立 `clean assembleApp` | Release 不能替代真机 |
| 交付边界 | `.app` 解包后恰好两个 HAP，设备类型和权限边界正确 | 构建任务日志不能替代产物检查 |
| Watch/Phone | 最终文件、大小/哈希、ACK 与播放结果 | UI 进度不能替代传输完成 |
| 数据保护 | 安装前只读备份及独立清单 | 单次导出不能替代复核 |

## 10. 提交与停止规则

1. Phase N0、N1 已完成；默认下一次只执行 Phase N2，且必须先获得单独批准。
2. 每阶段开始前列出精确文件允许清单，不使用 `git add .`。
3. 提交前检查 staged stat、name-status、diff check，以及敏感/本地/设备产物。
4. 构建、测试、日志和设备备份不得进入 Git。
5. 发现 wire、路径、签名、API 23 或设备数据风险时立即停止并重新审批范围。
6. Phase 7 仍是独立产品协议升级；本文完成不代表 Phase 7 获得批准。

## 11. 本计划完成定义

只有同时满足以下条件，维护性收尾才可标记完成：

- 当前全部测试拥有当前提交对应的真实通过报告，或用户明确接受并记录替代门禁。
- 自动同步队列面对结构损坏清单不抛异常、不修改录音源文件。
- Debug/Release 构建不再污染 Git 工作区。
- 正式生产日志不再使用已结束 Phase 的临时命名。
- Linter、Debug、Release、双 HAP 产物边界均通过。
- 所有执行证据和当前架构文档已同步，且未夹带 Phase 7 或新产品功能。
