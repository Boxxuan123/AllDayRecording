# 阶段二 A 收尾：本轮复测与交付

日期：2026-09-26。**关键正确性回归通过；完整阶段验收部分通过，性能与完整故障矩阵尚有未完成项。** 此文与上一轮 `SYNC_PHASE2A_ACCEPTANCE.md` 分开记录，旧报告不计为本轮执行结果。最终提交、固定版本在线链接与远端 HEAD 比对结果由交付回复给出。

## 源码和安装包

- 起始手机：`8badf925b9cb399f36057e02afec75bdeaddf686`；电脑：`95f3ff16a4edffe4fa2681b3ecd4b8d62a6f26af`。开始均在 master，工作区干净，远端一致，未发现适用 AGENTS.md。
- 手机生产修复提交：`c98fac77566105665c5db62099c849310441ffc1`。最终原生夹具候选：`f6864926d54fef2b9794a375c968acac0507bf52`；两者生产源码相同，后续提交只修正夹具和补充宿主错误分类矩阵。
- 被测电脑接收端：`61c7a91f25e792a4dfb784b6154084cf3d3eb12b`，真实 gateway/trust/UploadStore，仅本地 fault.json 控制合成服务器的断连或响应丢失；没有公开故障控制接口。
- 实际安装并最终通过的候选 HAP SHA-256：`dc35dff8bf02a2f74ded0ae44af278833215ec8129daf5cda4eb476c612d94ca`。这是正式 SDK、product=phone、Debug 编译的隔离装配，使用生产业务类、独立原生库和测试入口；不是正常业务入口的同一个二进制包。测试 CA/配置通过临时 rawfile 注入，不提交。
- 恢复正式正常入口的 phone Debug HAP：`0d087b2b2eb0edb6584e82745c153b8b3b649cf9c0a2d5151505607d01f12c7e`，clean assembleApp 12.818s/exit0，ZIP12条目且无测试 rawfile；覆盖安装成功，未启动真实业务同步。原生测试期间未卸载/清正式库/重置真实配对。
- 第一轮候选 HAP：`ec806762d5aba5fbe6105f15c4acc89f0a9879a2064fecde5177b552c29e0384`，对应 c98fac7。仅引导公钥的包：`6542e8f26a9588cf3c6220a8dea17699f930b6fa55f71ab9437afb19d2ecb1ab`，不作为业务验收证据。
- 第二轮 b470242 的 HAP：`706ac2bb3150aefa7715ccea19382bbaf4c6cc31f2ec36a7a815295e4dadfa16`；第三轮 `6d539348416d9923de5b462badda91e13bde10f6` 的 HAP：`c5844adebed9c7e26a054e85a3f6bb377311e9765d5773bb3972b67940d08111`。这些轮次整套报告失败，不能替代最终通过报告。

## 实际修复和行为证据

先补 `check-sync-phase2a-lifecycle.cjs`：真实 SQLite 和 ViewModel 中，挂起本地保存，另一条同步增量先落库；保护逻辑跳过 UI 刷新后断网，再让保存提交。原实现 5 秒内无法显示最后增量，断言失败。不是凭外部审查推测判定缺陷。

修复保留已有 dirty 标记，以单个本地读取循环刷新已提交投影。保存结束和恢复前台也触发本地读取，不等待下一次成功 HTTP。正常单批增量仍按 ID 读取；已有未显示变更则读取本地缓存，不扫描录音目录。读取被新保存或 generation 变化打断时保留需求；停止旧生命周期后不发布旧结果。没有全局 busy，没有持数据库事务等待网络。

Home/More/People 三个页面改用 `@ObjectLink` 链接已有 `@Observed PhoneV3ViewModel`，避免自行创建备用 ViewModel，保留页面已有 revision 通知。未改 lint 规则或忽略范围。

## 本轮命令和分层结果

环境：Windows 10.0.26200；Studio Node 24.14.1，SQLite Node 24.19.0；SDK 26.0.0.32/API26；Python3.12.10，DevEco Testing/Hypium/xDevice6.1.0.210，hdc3.2.0c。目标核对为 PLR-AL00 手机，只安装 phone，不操作 Watch。

|检查|本轮结果与忽略目录内证据|
|---|---|
|电脑 10 个相关 pytest 文件|70 passed，11.21s，exit0；电脑 outputs/sync-phase2a-closeout-pytest-final.xml|
|电脑 ruff|src/tests/两接收端工具通过；导出工具另行通过|
|手机 run-host-tests.mjs|142/142（entry67、phone75），23.468s，exit0；outputs/sync-phase2a-closeout-host-final.log|
|13 个 check 脚本|各 exit0，outputs/closeout-*.log；sync-phase1、phase2-sync、sync-coordinator、sync-phase2a、sync-phase2a-lifecycle、sync-byte-limit、review-audio、voice-review-flow、annotation-experience、receiver-connection、sync-connection、sync-discovery、upload-offset|
|真实 Code Linter|0 defects，exit0；outputs/sync-phase2a-closeout-lint-final.log|
|额外错误分类矩阵|400/403/TLS/identity 停止自动重试并可显式重试；500/timeout 有界退避，100 次触发不造成风暴；是真实 coordinator 的可控时钟行为测试，不是真机完整矩阵|

复现命令沿用现有脚本，设置 `DEVECO_SDK_HOME` 为本机 SDK、`PHONE_TEST_TYPESCRIPT` 为 SDK ets-loader/node_modules/typescript；使用 `tools/quality/build-sync-device.ps1 phase2a`、`production`；原生使用 `tests/ui/run_phase2a.py`，`SYNC_PHASE2A_EVIDENCE` 指向本轮独立接收端 evidence.json。完整环境与安装、清理步骤见 [夹具 README](../tools/quality/sync-phase2a-device/README.md)。

## 最终原生业务回归

原始报告 `tests/ui/reports/2026-09-26-16-20-39/summary_report.html`，**1/1、失败0**；这是一个包含多个业务阶段的完整用例，不虚增为多项用例。终端日志 `outputs/sync-phase2a-closeout-native4.log`；脱敏观察值来源 `outputs/sync-phase2a-closeout-native-evidence.json`。原始文件忽略，不公开提交。

- A：独立入口装配生产 BackupService/UploadService、DeviceRemote、ViewModel、UseCases、原生 RDB；8,388,652字节录音上传期间保存标注，电脑 applied 时已传393,216字节、尚未完成。随后手机 UI/native pending 均0；实际切页、播放完整2秒本地音频和滚动后上传仍未完成，最终offset=8,388,652并确认manifest，服务端 SHA-256 校验未关闭。
- B：同一 TLS 接收端断连时连续3次真实本地提交，完整队列有3个不同ID，第二条依赖第一条、第三条依赖前两条；停止并重启应用，原生持久化仍3。恢复同一受信接收端后未点同步，自动收敛为0，三个原ID均获applied。
- D代表性：服务器实际提交后丢弃响应；相同ID重送并再次确认。最终只读核对真实core.sqlite3：8个回执事件、7个唯一操作、7个client_operations；初始1事实/版本2，加7次业务操作得到8事实/版本9，没有重复业务生效。合成数据的本地摘要位于电脑 outputs/sync-phase2a-closeout-device4/verified-facts.json。
- C：原生库中控制读取/提交次序；一条片段保存被挂起，另一条片段连续两个增量落库；之后无成功网络响应，保存完成后最后合法投影可见，保存结果保留。另验证旧快照晚于新保存返回时不覆盖、停止后旧请求不发布、重新打开独立库仍能读回。此阶段是可控同步完成的原生业务测试，不是远端协议测试；“网络回执事务正好与另一条保存交错”的独立真机场景仍未单列完成。

合成时间线（epoch毫秒；跨设备时间用于观察顺序，不作为校准后的网络延迟）：驱动发起触摸1790410853661.618；手机queue入口1790410853797、事务提交后返回1790410853802；驱动观察完成1790410853975.766；电脑applied1790410854328.604；手机确认native/UI pending为0的观察点1790410869934；播放/滚动结束1790410877784.548时上传仍未完成。之后完整manifest确认。**回执落库的精确瞬时时间和备份完成瞬时没有独立埋点**，不能把“观察点”写成准确应用时刻。

当前手机本地提交计时：备份中1个UI保存样本，queue入口到提交返回5ms；备份完成后3个夹具连续保存样本均5ms。驱动触摸至可见约314ms只作单次自动化观察，包含驱动开销，不算应用性能；两组路径和样本量不足以构成同UI空闲/备份性能结论。

已实际采集 `hdc ... shell hiperf stat --app AllDayRecording.huawei.com --per-thread -d 10`，exit0，报告 `outputs/sync-phase2a-closeout-hiperf.log`。10秒期间主线程sw-task-clock原始计数324,566,409；这是第三轮相同生产源码在合成备份中的线程计数，**不是帧率、卡顿次数或主线程阻塞时长**。设备系统核对为 PLR-AL00 7.0.0.109(SP6C00E105R7P3)。

## 失败、性能边界和未执行项

- 首次电脑受限运行 61 passed / 7 failed / 2 errors，错误为临时目录/子进程 WinError5；使用获准的本地测试权限后 70/70 通过，未修改断言。
- 首次 lint 未设置 Windows SDK 环境，错误解析到 macOS 默认路径；补齐环境后真实报告仍 3 项，源码修复后 0 项。
- 新刷新回归先失败后通过；首次 ArkTS 构建/phone 宿主因 catch 值需要 `as Error` 未通过，修正类型后构建及142宿主通过。
- 第一次原生全流程报告 `tests/ui/reports/2026-09-26-16-05-13/summary_report.html`：0/1。A 的上传、标注、播放、滚动及 manifest 已执行成功；B 的夹具把 `pendingOperations()` 可发送分支当作完整 outbox，数量断言失败。改为 `annotationOperations()` 检查完整依赖链；保留失败报告，未绕过真实依赖门禁。
- 第二次报告16-09-51：A/B/丢响应分项通过，C夹具假设首个会话有片段，TypeError失败。第三次16-15-36：C夹具在正在保存的同一片段上更改revision，生产安全校验正确拒绝过期标注，夹具却期待成功而失败。最终使用两个独立片段构造所要求的交错；另加宿主断言确认同片段过期保存仍拒绝。最终16-20-39整套通过，未把失败轮次计为通过。
- DevEco 日志提示 Pillow/opencv 未安装；不能由截图步骤推断已取得帧性能数据。
- 本轮宿主 0/1000/10000 历史行各8次保存，均16次目标/依赖查询、返回36行，0次目录扫描、0次保存网络调用；宿主 p50 分别2.63/2.52/2.76ms，不能当作手机性能。
- 未执行：相同 UI 保存流程在不同原生历史数据量上的统计对照；主线程阻塞/帧数据；可比历史 HAP 性能对照；真实 LAN 地址重发现/探测超时全时延；原生 400/401/403/TLS 全故障矩阵；后台被系统挂起后的执行。审核决定不进入通用自动重放。

## 可审查交付

本轮恢复后重新导出三个业务目录并逐文件SHA-256比较：before/after均1,892文件、3,614,605,522字节，different_files=0，exit0；记录 `outputs/sync-phase2a-closeout-data-protection.json`，私有清单位于 `outputs/sync-phase2a-closeout-private/`。这次重新导出与计算，未复用上一轮结果。独立测试HUKS alias已由UI成功清理；两个明确命名的测试库及sidecar、测试cache与rawfile已移除；正式正常入口已覆盖恢复；19100映射清理后fport列表为空。

最终通过候选f686492之后只补验收文档、夹具README及一个已执行的宿主过期目标断言；`phone/src`、`common/src`、构建脚本和原生夹具无后续变化。实际核对c98fac7到最终候选的生产输入diff为空。测试候选和最终交付之间不以文档自引用hash造成反复改动。

收口判定：交付与关键正确性证据齐备，但**不宣称附件中的完整性能、精确时间埋点和全部故障/交错验收已完成**；仍为部分通过，本轮未开展审核音频缓存/预取。

审核包仅从两端已提交 HEAD 的明确文本范围导出，包含 phone/desktop、阶段一到本轮的源码 diff（含删除行）、当前验收说明及逐文件 SHA-256 manifest。先验证阶段一基线为 HEAD 祖先；检查 PEM 实体、常见凭据及文本格式，包内不包含运行数据、HAP、证书、密钥或原始报告。

在电脑仓库执行：

```powershell
.venv\Scripts\python.exe tools/export_sync_phase2a_review.py --phone '<手机仓库绝对路径>' --output outputs/sync-phase2a-closeout-review.zip
```

输出在既有忽略目录，不能提交公开仓库。最终版本清单位于 ZIP 的 manifest.json；线上文档使用最终提交 SHA 固定链接，避免分支移动或缓存混淆。
