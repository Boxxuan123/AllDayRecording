# 手机—电脑同步第二阶段 A 验收

后续本轮收尾与重新执行证据见 [SYNC_PHASE2A_CLOSEOUT.md](SYNC_PHASE2A_CLOSEOUT.md)。下文保留上一轮历史结果。

2026-09-26。**部分完成 / 未整体验收通过**。实现与分层测试随本文正常提交；不把用例存在、构建成功或宿主耗时当作真机全场景通过。最终两端完整提交号及远端核对在交付回复中给出，本文所在提交即本轮审查版本。

## 基线与范围

- 手机起始 `master`：`763f95a01bac7b0ff5e8ba5bc45bd0b8340e8a99`；电脑起始 `master`：`895c294f32480b7b34817e9dbab86b1a86ddf443`。开始两端干净，fetch 后没有后续远端提交；未发现适用 AGENTS.md。没有回退用户分支或覆盖无关修改。
- 第一阶段记录中的“尚未提交”已纠正为历史撰写时点；上述两提交是已经推送的第一阶段版本。
- 不改变 Watch→Phone 传输、审核决定安全语义、声纹/人物事实模型，不做缓存预取或永久后台联网。

## 实现、所有权和边界

之前 `PhoneV3UseCases.synchronize → audioBackup.backup → connect → sync`，整批大文件阻挡轻量操作。现在 ViewModel 持有一个 `PhoneSyncCoordinator`，分别驱动 `synchronize(..., maxBatches=4)` 和 `backupRecordings()`；每条通道一个消费者，一个共享唤醒计时器，正在执行时的新触发合并保留。后续批次继续运行，不是两个完整流程简单并行。

- 初始化完成、本地普通标注事务提交后、前台恢复、网络恢复、手动同步汇入同一协调器；保存回调先完成。新本地录音通知备份通道。空闲轻量轮询 120 秒，待操作/处理/备份时 15 秒；250ms 防抖。新保存可打断已排定的空闲计时器。
- 临时错误指数退避，首次约 3.2–4.8 秒，抖动后上限 300 秒。网络/保存事件不绕过失败退避；显式重试可提前。401/403、TLS/身份、其他非 408/429 的 4xx 和非结构化错误阻止自动重试；保留原始分类/HTTP/业务码，不能当成离线。失败分别显示，等待配对/Wi-Fi 不冒充成功。
- 每个备份任务只处理一个录音会话，继续沿用现有文件并发、SHA-256、offset、完成确认、manifest 顺序和持久化上传记录。仅默认网络为 Wi-Fi 才开始下一会话；正在上传的会话不因网络事件即时中断。仍有同步清单扫描成本，没有完成该热路径优化。
- 暂停持久化在 `phone_foreground_sync` preferences，写入串行；自动/手动触发均不能越过暂停，需“继续”。轻量在当前 HTTP/批次原子应用后停止；备份在当前会话结束后停止。页面明确显示“暂停中”，没有承诺立即中断所有 HTTP。切后台不派发新任务；stop 注销网络监听、清计时器、取消轻量续批并废弃旧 UI 回调；同一 ViewModel 重启等待旧通道收尾。
- 重新获取电脑数据要求先暂停，等待在途通道收尾后重建投影，避免和自动消费者竞争；普通同步不使用全局 BUSY 禁用保存/播放。
- 连接准备按 filesDir、receiver/device、CA 指纹与路径、RP、地址、签名 alias 合并；加入者和连接完成时重新验证配置。每个 HTTP request 自己创建/销毁客户端资源；没有跨通道 disconnect。每个实际请求重新获取一次性 challenge 和签名。DeviceRemote 请求前后和上传派发边界检查受信配置，旧配对结果不能继续应用。
- 只有保存地址的**只读、已认证 status 探测**允许 SDK 通用响应超时后重发现一次，再校验同一受信身份。业务响应不确定仍不普遍重发，审核决定不进入自动调度。原 HTTP 连接 20 秒/读取 120 秒和发现 12 秒上限未提高；尚未真机注入旧地址静默丢包测量总时延。
- outbox 仍是唯一持久化普通操作队列；重试不新建 operation_id。缺失选中资源和既有前置操作分别阻挡相关分支，其他就绪操作可先发送；不把等待改成冲突。网络等待不持数据库事务；原回执/投影/游标同事务、旧 revision 和本地新保存保护继续生效。
- 无变化不刷新全快照；只涉及 utterance 时按 ID 读取并替换相关会话卡片，保留其他会话引用、不扫描录音。其他资源变化/审核变化仍需缓存快照。真机发现“空增量响应清理已回执 outbox，但 UI 未失效”，已增加同步前后 pending 数比较及回归，避免本地已归零、界面仍显示 1。
- 真机完整上传触发了第一阶段遗留的 SHA-256 422：上传循环混用显式 offset 读取和未指定 offset 的读取，不能依赖前者推进描述符游标。现每个分片都使用电脑已确认 offset。`check-upload-offset` 对阶段基线实测哈希失败（exit 1），修复后首次/断点多分片和句柄释放通过（exit 0）；真实 8 MiB 上传与 manifest 最终确认通过。没有关闭哈希校验。
- 服务端成功请求 start/end 改 DEBUG；错误仍 WARNING/ERROR，保留关联编号、安全路由、状态及耗时。客户端成功日志 DEBUG；未删错误证据。

## 文件和可执行回归映射

|实现|验证|
|---|---|
|application/PhoneSyncCoordinator；runtime/PhoneSyncEnvironment；presentation/PhoneV3ViewModel|check-sync-coordinator：100 次合并、单消费者、备份交错、暂停、退避、401、计时器抢先、持久化写入顺序、监听注销、Wi-Fi 门禁|
|UseCases.synchronize/backupRecordings/refreshUtterances；PhoneV3ComputerBackup|phone 宿主解耦断言；check-sync-phase2a：依赖、批上限续跑、定向刷新、空页清理失效；check-sync-phase2a-lifecycle：3 条离线提交、实际 SQLite 重开后自动收敛|
|PhoneProjectionRepository.pendingOperations|缺失资源留队、就绪分支先行、资源到达后解锁；第一阶段事务/旧快照/原子游标回归保持|
|ComputerReceiverConnection/ComputerConnectionError/DeviceRemote/UploadService|check-receiver-connection、check-sync-connection、check-sync-discovery；真实生产真机链路使用独立配置|
|AnnotationPage / SessionInfoTabs 的无状态组件改 @Builder|同环境 UI 基线 lint 7 项，本轮 3 项，无屏蔽规则；正式编译及既有标注回归|
|tools/quality/build-sync-device.ps1；sync-phase2a-device；tests/ui/PhonePhase2Production|临时入口 finally 恢复；真实 TLS、HUKS 签名、上传与 native RDB；原始报告忽略|
|电脑 http_handler 与 test_transfer_tls_admission/test_sync_phase2a_recovery|真实 socket TLS、连接释放/上限、安全错误、成功 INFO 静默、真实 core 回执丢失同 ID 去重|

## 实际环境、命令和结果

Windows 10.0.26200 x64；DevEco Studio Node 24.14.1；SDK API26/platform26.0.0、26.0.0.32；独立宿主 SQLite Node 24.19.0。DevEco Testing Python 3.12.10、Hypium/xDevice 6.1.0.210、hdc 3.2.0c；本轮真实手机 PLR-AL00、HarmonyOS 7.0.0.109 SP6。电脑项目 Python 3.12.10、pytest 8.4.2、ruff 0.16.5。

手机仓库命令（N=Studio tools/node/node.exe，S=本机 bundled Node 24.19.0；两个绝对位置见复现 README/终端记录）：

```powershell
$env:DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
$env:JAVA_HOME='C:\Program Files\Huawei\DevEco Studio\jbr'
$env:JAVA_TOOL_OPTIONS='-Djdk.util.zip.disableZip64ExtraFieldValidation=true'
$env:PHONE_TEST_TYPESCRIPT='C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\ets\build-tools\ets-loader\node_modules\typescript'
$N='C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe'
$S=Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe'
& $N tools/quality/run-host-tests.mjs
& $N tools/quality/run-code-linter.mjs
# 对下列每个脚本执行：& $S tools/quality/<脚本名>.cjs
tools/quality/build-sync-device.ps1 production
```

13 个实际 Node 脚本：`check-sync-phase1`、`check-phase2-sync`、`check-sync-coordinator`、`check-sync-phase2a`、`check-sync-phase2a-lifecycle`、`check-sync-byte-limit`、`check-review-audio`、`check-voice-review-flow`、`check-annotation-experience`、`check-receiver-connection`、`check-sync-connection`、`check-sync-discovery`、`check-upload-offset`。各 exit 0，日志 `outputs/sync-phase2a-final-*.log`。SQLite/native 适配层受控，业务实现实际执行；它们不是原生 RDB 或真机性能报告。

|项目|本轮结果|本地原始证据（不提交）|
|---|---|---|
|宿主测试|最终 142/142（entry 67、phone 75），exit 0，25.468s|outputs/sync-phase2a-host-final.log|
|lint|exit 1，剩余 3 项 HomePage:14、MorePage:6、PeoplePage:19 的 avoid-overusing-custom-component-check|outputs/sync-phase2a-lint-final.log|
|同环境 lint 对照|两处改动 UI 文件恢复阶段基线运行后 finally 还原，其他三处文件本轮未改；7→3，exit 1→1；不是全仓独立旧版本性能对照|outputs/sync-phase2a-lint-ui-baseline.log|
|正式 phone Debug|clean assembleApp，exit 0，12.551s；已覆盖安装恢复正常入口，检查 HAP 无测试 rawfile|outputs/sync-phase2a-build-final.log|
|原样例|1/1，exit 0；本轮先执行原 main.py|tests/ui/reports/2026-09-26-13-58-55/summary_report.html|
|第一阶段隔离用例重跑|2/2，exit 0；离线保存/杀进程重开/回滚和替代备份端口交互|tests/ui/reports/2026-09-26-15-04-32/summary_report.html；outputs/sync-phase2a-phase1-ui.log|
|生产真机链路|最终 1/1，exit 0；中间失败均保留|tests/ui/reports/2026-09-26-15-01-47/summary_report.html；outputs/sync-phase2a-production-ui-final-pass2.log|
|电脑 pytest|70 passed / 11.18s，exit 0|电脑 outputs/sync-phase2a-pytest-final.log/.xml|
|电脑 ruff|src、tests、两个 receiver 工具；exit 0|本轮终端|

宿主 runner 现自动处理 SDK 的 phone/.test/phone 与 Hypium default 目录映射：仅复制本次新鲜字节码并校验源文件时间，再执行并验证最新报告、数量和失败数。首次 74/75 的旧测试要求“先备份”，已改为独立调用断言后通过，没有降低备份结果断言。真机中间失败包括未申请 GET_NETWORK_INFO、合成路径不符合生产 manifest 识别、已标记片段需先“修改标注”、空页清理后的 UI 漏刷新、测试把长 WAV 当两秒音频、Hypium 方向需大写；均按实际原因处理，不把中间失败报告计作通过。缺 Pillow/OpenCV 导致截图处理警告，原始截图存在；不由此宣称流畅。

被测树边界：上述成功生产真机包含上传 offset 修复和空页清理刷新修复；之后补了“保存期间延后的变更与下一批不同条目变化合并时必须重读缓存”的两行 ViewModel 保护。该最后补丁有 `check-sync-phase2a-lifecycle` 实际交错回归，最终 142 宿主、lint 和正式 clean 构建都在其后执行；没有再次整轮真机。提交包含这些最终源码和测试，不把早期 HAP 当最终逐字节版本。

## A—H 状态与剩余项

|场景|结论和证据范围|
|---|---|
|A 上传中轻量回执|生产真机通过：真实 applied operation_id、原生/界面队列清理及上传仍未结束；随后录音和 manifest 完成。正式备份类/认证/分片均执行，录音清单使用合成注入|
|B 依赖隔离|宿主业务集成通过：缺资源留队、无关分支先行、资源到达及前置收据后续跑、单批上限续跑。未覆盖所有人物依赖组合的真机矩阵|
|C 离线保存恢复|宿主真实 SQLite 重开 + 正式协调器自动收敛 3 条、相同 IDs，无重复应用；第一阶段原生离线保存/进程重启另列。真实电脑离线→恢复的完整原生自动收敛场景未执行|
|D 合并/生命周期|确定性协调器及环境适配器测试通过；同一所有者 stop/重进等待、旧 callback 不唤醒、暂停持久化顺序。未完成全部真机退出/重新配对交错|
|E 回执丢失/错误|电脑真实 core 同 ID 去重通过；手机 400/401/403/500、TLS/身份、只读超时一次发现的受控传输测试通过；不可幂等审核决定保护回归保留。旧地址静默丢包的原生网络故障注入未执行|
|F 通道隔离|单元/业务集成通过，备份失败不污染轻量成功，认证资源不复用；真机故障/取消全过程矩阵未执行|
|G 交互/性能|真实上传中切页、保存、完整两秒本地播放、3 次控件内滚动通过，传输仍推进。未做同设备基线/改后各 ≥20 样本的业务提交与 UI 时间分解、少量/大量历史/多会话 P50/P95/max；未采集帧/卡顿，不宣称无卡顿|
|H 正确性/工程|原生独立 schema10→11 回填断言；事务失败、旧快照、回执/游标、播放证据与未知审核结果、TLS 上限/释放回归通过。lint 尚有 3 项，因此整阶段不能写“全通过”|

## 安全恢复与交付核验

最终通过用例的脱敏证据：合成操作 `01M3E8AMNZ6SM4E81NRHQKNZ00`，服务端 applied 时间 `1790406120.5993392`（Unix 秒）；回执时录音上传 `589824` 字节、未完成。用例开始观察 `262144` 字节；完成切页/保存/播放/滚动后 `2621440` 字节、仍未完成；最终 `8388652` 字节且 manifest completed。驱动点击保存前 `1790406119.9420917`，观察“已保存” `1790406120.2587852`，交互结束 `1790406144.411466`；这些是单次驱动观察时序，包含驱动开销，不是本地事务计时、P50/P95 或性能对照。该次从前次正确上传的 262144 字节继续，保留生产断点语义；筛除旧回执，只接受本次新 operation_id。

本轮原始成功证据 `outputs/sync-phase2a-production-evidence.json` 包含之前失败尝试的合成回执，本文仅摘录最终成功操作；不提交大型原始报告。成功用例最后删除独立测试 HUKS alias 并停应用。

完整复现、临时入口和清理方法见 [隔离生产测试 README](../tools/quality/sync-phase2a-device/README.md)。原应用不卸载，不清真实库，不修改真实配对、录音、审核或 Watch。正式源码不 import 临时入口；公开提交只含源码、测试、生成器和脱敏说明。

最终恢复完成：仅清理列出核实的两个本轮测试 RDB 及同名附属文件、7 个测试 cache、4 个生成 rawfile；生产 HUKS alias 未操作，测试 alias 已由成功用例删除。正式入口/HAP 恢复，不自动启动真实同步。两个独立 receiver 已停止，19099/19100 测试 rport 已移除，最终映射为空，HDC 网络保持。

本轮 before/after 三目录逐文件 SHA-256 比较 **exit 0、different_files=0**：两侧各 **1892 文件、3614605522 字节**。记录 `outputs/sync-phase2a-data-integrity.json`；私有导出及清单位于 `outputs/sync-phase2a-private/`，不提交。没有用备份覆盖手机差异，没有卸载、清真实库或删除用户录音。

交付执行 `git diff --check`、暂存文件检查、正常 commit 和 `git push origin master`，不 force。推送后逐端比较 `git rev-parse HEAD` 与 `git ls-remote origin refs/heads/master`，并用远端 master 树核查本轮源码、测试、本文及电脑验收文档；完整 SHA/链接和实际核对结果由最终交付回复提供。
