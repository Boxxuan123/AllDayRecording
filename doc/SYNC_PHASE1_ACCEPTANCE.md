# 手机—电脑同步第一阶段实施与验收

日期：2026-09-26。本轮结论：**部分验收通过，不能宣布整阶段通过**。代码、真实手机 UI 用例、服务端真实 TLS 回归及正式 phone Debug 应用已交付。手机 lint 仍失败；同设备改造前后性能验收及部分真机故障/交互场景未完成。

## 版本与工作区

|仓库|分支|实施基底 HEAD（撰写原记录时）|
|---|---|---|
|AllDayRecording|master|fe872618fe8ecd7d205dfe236767c91640985768|
|AllDayRecording-ASR|master|04e2e7f994025c1df0e2f653dd83404c9e11582a|

原实施记录写于提交前；后来第一阶段已经正常提交并推送：手机 `763f95a01bac7b0ff5e8ba5bc45bd0b8340e8a99`，电脑 `895c294f32480b7b34817e9dbab86b1a86ddf443`。上表是实施基底，不是交付版本。开始时电脑仓库干净，手机已有用户未跟踪 tests/；原 PhoneMoreSmoke.py、main.py、配置保留，新增业务用例沿用它们。检查两仓库及上级路径未发现适用 AGENTS.md。第二阶段变更和剩余问题见 [SYNC_PHASE2A_ACCEPTANCE.md](SYNC_PHASE2A_ACCEPTANCE.md)。

## 已确认问题与改法

1. 手机保存地址校验曾吞掉各种失败进入发现。新增 ComputerConnectionError，保存原生码、HTTP 状态、服务端码、请求 ID、接口、阶段、原始原因及可能已发送标志。只有明确不可达错误允许重发现；400/401/403/500、TLS、身份失败保真。SDK 2300028 无法可靠区分连接/响应超时，保守视为响应结果不确定，不自动重发现。没有提高上传并发、统一延长超时或增加全请求重试。
2. 电脑监听 socket 原先包装 SSL，握手可阻塞接入。真实测试修改前正常客户端握手超时；修改后 TLS 握手移至有界连接工作线程，默认上限 32，握手超时 5 秒，超限关闭新连接，关闭服务时释放已接收 socket。此证据只证明一个接入风险，不能解释所有用户超时或 HTTP 500。
3. 标注保存曾整表读取并在提交后全量刷新。按选中 ID 查询投影、相关操作和人物；schema 11 增加 outbox_selections 索引表、维护触发器及 schema 10 回填。提交后直接应用已提交操作，不扫描录音、不调用远端、不安排延迟全量刷新。保留 revision/active、声音类型、依赖与回滚校验。
4. 短写事务串行化覆盖本地保存与同步应用；失败只标记已派发批次。旧 revision/tombstone 不覆盖新数据；UI generation 拒绝迟到全量快照。提交成功但显示异常单独提示，不能误报数据库失败。
5. 同步状态从全局 BUSY 分离；保存、音频、审核对象提交分别防重/清理。进度在可观察状态赋值前按 150ms/会话结束限频；上传文件 open/read/close 改平台异步 I/O。页面退出/审核切换保护迟到回调。
6. 客户端连接/逻辑操作/请求尝试关联，电脑产生 26 字符 request_id，安全记录路由、状态、耗时和异常链的类型/源码位置。500 不暴露原始异常消息、私密路径或请求正文；上传成功日志抑制、challenge 成功采样。

保留配对 CA/TLS、HUKS 签名、challenge、撤销校验、上传 SHA-256/续传/完成确认及回执/投影/游标语义；没有修改 Watch→Phone 传输、源音频删除规则或审核听完与证据匹配要求。

## 修改文件与职责

路径相对于手机仓库：

- computer/ 下新增 ComputerConnectionError.ets；修改 ComputerReceiverConnection.ets、ComputerReceiverDiscovery.ets、ComputerTransferHttpClient.ets、ComputerReviewNotSentError.ets：错误保真、连接合并、发现清理、原因链、诊断、保守重试。
- computer/ComputerRecordingUploadService.ets：分片文件异步 I/O。以上目录均为 phone/src/main/ets/computer/。
- phone/src/main/ets/v3/application/PhoneV3Ports.ets、PhoneV3UseCases.ets：定向端口、提交结果、派发批次与短事务。
- phone/src/main/ets/v3/data/PhoneProjectionRepository.ets：schema 11、索引/批量查询、串行写、版本保护。
- phone/src/main/ets/v3/domain/PhoneV3AnnotationIndex.ets、PhoneV3LocalAnnotation.ets：共享行索引、局部应用。
- phone/src/main/ets/v3/presentation/PhoneV3ViewModel.ets：状态拆分、保存反馈与 generation。RootPage、RecordingListPage、SyncCenterPage、AnnotationPage、PersonSelector、VoiceReviewPage 同目录文件：局部同步提示、稳定组件 ID、页面回调保护。
- tools/quality/check-sync-phase1.cjs、check-sync-connection.cjs、check-sync-discovery.cjs 新增；check-receiver-connection.cjs、check-review-audio.cjs、check-phase2-sync.cjs、check-sync-byte-limit.cjs 更新。迁移测试更新 schema 期望，未删失败断言。
- tools/quality/sync-phase1-device/：独立临时真机入口及操作说明；verify-phase1-exports.py：只读数据导出哈希比较。
- tests/ui/testcases/PhoneOfflineAnnotation、PhoneSyncInteraction 的 .py/.json 及 run_phase1.py；.gitignore 忽略原始报告和运行缓存。

电脑修改：src/allday_asr/v3/interfaces/transfer/composition.py、http_handler.py；新增 tests/test_transfer_tls_admission.py、tools/sync_phase1_test_receiver.py。后者仅是 127.0.0.1 合成测试服务，不是生产管理接口。

跨 UI/存储/传输的修改对应本轮实际调用链；保留现有长文件结构，没有顺手重写架构。完整调度器、双端音频缓存/预取、静默同步均未实现。

## 实际环境

- Windows 10.0.26200 x64；电脑项目 .venv Python 3.12.10、pytest 8.4.2、ruff 0.16.5。
- DevEco Studio 内置 Node v24.14.1；HarmonyOS SDK API 26、platform 26.0.0、SDK 26.0.0.32；SQLite 宿主脚本用 bundled Node v24.19.0。
- DevEco Testing 自带 Python 3.12.10；Hypium/xDevice 6.1.0.210，hdc 3.2.0c，设备 uitest 7.0.0.1 / agent 1.2.3。
- 真实目标：PLR-AL00 手机，软件 PLR-AL00 7.0.0.109(SP6C00E105R7P3)。仅操作配置选定手机；bundle AllDayRecording.huawei.com / phone / EntryAbility。未向 Watch 安装。
- 构建使用 DEVECO_SDK_HOME 指向 Studio/sdk、JAVA_HOME 指向 Studio/jbr，JAVA_TOOL_OPTIONS=-Djdk.util.zip.disableZip64ExtraFieldValidation=true。

## 已执行命令与本次结果

下列相对路径基于各自仓库；N 为 Studio/tools/node/node.exe，H 为 Studio/tools/hvigor/bin/hvigorw.js，S 为 bundled Node v24.19.0。原始输出保留在本地被忽略的 outputs/，不是提交材料。设备准备/清理的具体步骤见 [真机复现说明](../tools/quality/sync-phase1-device/README.md)。

|命令/入口|退出码、数量|本次证据|
|---|---|---|
|电脑 .venv/Scripts/python.exe -m pytest tests/test_transfer_tls_admission.py -q|修改前 1（阻塞测试失败）；修改后 0，最终 4 通过，多次重复运行|真实 TCP/SSL，正常请求 1 秒截止；超时释放循环、上限及 shutdown、500 诊断|
|电脑 pytest 下述完整相关集合|0，68 passed，10.87s|outputs/sync-phase1-pytest.log、.xml|
|电脑 .venv/Scripts/python.exe -m ruff check src tests tools/sync_phase1_test_receiver.py|0|终端 All checks passed|
|S tools/quality/check-*.cjs，下述九个脚本|各 0，9 个脚本通过（不是 9 个 UI 测试）|outputs/sync-phase1-check-*.log|
|N tools/quality/run-host-tests.mjs|0，142/142（entry 67、phone 75）|outputs/sync-phase1-host-final.log；phone/.test/default/.../test_result.txt|
|N tools/quality/run-code-linter.mjs|1，7 defects|outputs/sync-phase1-lint-final.log、sync-phase1-linter-raw.jsonl|
|N H --mode project -p product=phone -p buildMode=debug clean assembleApp --no-daemon|0，正式应用 BUILD SUCCESSFUL，15.480s|outputs/sync-phase1-build-final.log|
|DevEco Testing Python tests/ui/main.py（cwd tests/ui）|0，原样例 1/1|tests/ui/reports/2026-09-26-10-43-10/summary_report.html|
|DevEco Testing Python run_phase1.py（cwd tests/ui）|0，最终新增 2/2|tests/ui/reports/2026-09-26-11-22-01/summary_report.html；outputs/sync-phase1-ui-final.log|
|hdc -t <手机> install -r phone/build/phone/outputs/default/AllDayRecording-phone.hap|0，恢复正式 phone HAP|安装成功输出；未卸载/清库|
|verify-phase1-exports.py before-a before-b；before-a after|均 0、different_files=0|outputs/sync-phase1-private/ 下私有清单|

完整电脑集合：
```powershell
.venv\Scripts\python.exe -m pytest tests/test_transfer.py tests/test_device_auth.py tests/test_v3_device_sync.py tests/test_v3_device_annotations.py tests/test_v3_device_reviews.py tests/test_review_audio_guards.py tests/test_review_audio_boundaries.py tests/test_phone_voice_review_flow.py tests/test_transfer_tls_admission.py -q --junitxml=outputs/sync-phase1-pytest.xml
```

九个 Node 脚本：check-sync-phase1、check-sync-connection、check-sync-discovery、check-receiver-connection、check-review-audio、check-voice-review-flow、check-annotation-experience、check-phase2-sync、check-sync-byte-limit（均 tools/quality/*.cjs）。设置 PHONE_TEST_TYPESCRIPT 为本机 SDK/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript 后执行；check-sync-phase1 使用 Node 内置 SQLite，非手机 RDB 性能测试。

真实失败/环境记录：
- 初次电脑受限运行出现 WinError 5 临时目录/文件访问失败，不能算业务通过；在允许执行项目测试的环境重跑上述集合通过。新诊断 ID 曾为 24 字符导致兼容断言失败，修正为 26 后完整重跑通过。
- 构建/lint 在受限环境遭 ENOENT/EPERM 子进程或 junction 限制，授权环境执行成功/得到实际 lint 结果。中间 ArkTS 类型、动态头字段、测试入口 HdsNavigation 参数编译错误已修复，最终正式 clean 构建通过。
- clean 后 host runner 首次因 SDK phone/default 测试目录映射超时失败。将本次刚编译的 phone/.test/phone 内容复制至 phone/.test/default，再运行原 runner；它重新执行并检查报告时间和源码用例数量，最终 142/142。不是沿用旧报告。
- lint 当前 7 项均为 @performance/avoid-overusing-custom-component-check：AnnotationPage 341、HomePage 14、MorePage 6、PeoplePage 19、SessionInfoTabs 24/89/177（均 PhoneV3 前缀 .ets）。没有屏蔽规则；这些组件已存在，但本轮未做相同环境的改前 lint 对照，不能把失败免责为已证明的基线问题。
- Hypium 截图处理提示缺 Pillow/OpenCV；实际 JPEG、步骤和断言报告存在，未把警告当作性能证据。

## A—G 分层验收

|场景|状态|证据与边界|
|---|---|---|
|A 原样例|通过|PhoneMoreSmoke 原样运行 1/1，原驱动/配置/入口|
|B 离线标注|隔离真机通过|真实生产标注页、VM/usecase/RDB；远端端口显式离线。8 秒截止内可见保存，读回 1 条，杀进程重启仍 1 条/待同步；隔离 RDB 注入失败不生成第二条、不显示假成功。未把 8 秒断言阈值当作实测耗时|
|C 同步期间交互|部分通过|真实 8MiB 慢 TLS 字节持续传输时进入生产标注页、保存、返回读回、原生本地音频播放完成；未直接自动化滚动，未测帧耗时。替代备份端口调用真实网络，不代表完整生产录音备份链路已端到端验收|
|D 错误保真|分层通过，UI 不完整|客户端实际边界以平台 stub 注入 400/401/403/500、5 原生失败，检查原因/释放；连接测试断言重发现 1/0；发现超时/取消/替换/启动失败清理与迟到回调；真机仅离线代表场景，不是所有网络故障的真机测试|
|E TLS 接入|通过|项目 Python 下真实 socket/TLS：改前失败、改后 4 通过；超时释放 3 轮、上限拒绝及关闭清理、500 安全关联|
|F 交错正确性|相关测试通过，原生矩阵未齐|SQLite/VM 测试重复保存、事务回滚、重启、并发短写、旧 revision/快照、同步进行中保存/播放与防重；既有审核证据/完整播放/不确定提交测试保留。保存中退出的所有真机时序未逐项覆盖|
|G 规模/性能|未完成要求|有宿主结构计数及后测数据；没有同设备同数据改前/改后点击至提交/可见完成 P50/P95/max，也没有真机帧报告|

最终 C 证据（接收端字节计数；总量 8,388,608；各时间点 ended=0）：
- 操作开始前 8,192；
- 保存后 458,752；
- 播放完成后 884,736。
这证明动作完成时传输仍在推进，不能推出“全程不卡顿”。安全摘要来自 outputs/sync-phase1-interaction-evidence.json。
代表性截图：最终报告 details/PhoneSyncInteraction/ 下时间 20260926112239055710 的 JPEG，显示“持久化操作 1”“合成传输进行中”；它在播放步骤之前，播放结果由用例断言与后续计数证明。只包含合成夹具文案；原始截图/日志不提交。

### 宿主规模证据（不是设备性能）

每规模 8 次保存，毫秒；使用生产存储/usecase 转译及宿主 SQLite，历史转写/无关操作规模：

|历史条数|P50|P95|最大|8 次合计查询/返回行|扫描/保存网络调用|
|---:|---:|---:|---:|---|---|
|0|2.3747|3.0635|3.0635|16 / 36|0 / 0|
|1,000|2.6047|3.8781|3.8781|16 / 36|0 / 0|
|10,000|2.3986|4.2996|4.2996|16 / 36|0 / 0|

测试结果标记 HOST_SQLITE_NOT_DEVICE；计时为宿主操作到回调路径，非触摸点击测量。样本 8 次较少、没有改前对照；不能据此宣布性能验收通过。结构上消除了保存触发的目录扫描/全表投影加载；UI 仍浅复制 sessions 数组，成本随会话数变化，且本测试未覆盖大量无关会话的真机渲染。该残余需要后续测量/局部状态优化。

## 数据保护与生产恢复

在安装临时测试入口前停应用，独立导出两次 phone files、历史 entry files、phone database；两份各 1,892 文件、3,614,604,870 字节，逐文件 SHA-256 一致。测试只用 sync-phase1-isolated-20260926.db、合成人物/文字/正弦音频及独立测试 CA，不访问真实配对或真实审核数据。

最终删除本轮明确命名的隔离 DB 及附属文件、cache/sync-phase1-test-ca.pem、cache/sync-phase1-tone.wav；恢复生产 Index.ets，移除生成 rawfile 夹具与测试 CA，clean 构建正式 phone Debug 应用并 install -r。没有自动启动正式应用，避免此次核验引发正常迁移/同步。再次导出的上述三目录仍 1,892 文件、3,614,604,870 字节，和 before-a 零差异。此验证范围是这三目录，并不宣称所有系统/HUKS/cache 数据逐字节校验。

独立接收端进程和本轮 tcp:19099 反向映射已关闭/移除。未断开调试 Wi-Fi。私有导出、证书密钥、HAP、完整报告只在忽略的 outputs/build/tests/ui/reports 下，不提交。

## 迁移、回退与后续

schema 10→11 保留原数据、回填操作选择关系并建立索引/触发器；测试覆盖旧库迁移及关闭重开。正式手机应用尚未自动启动，不宣称真实业务库已完成迁移。

旧 schema 10 应用不兼容已升级的 schema 11 库。回退前先停止应用、保留当前数据库/新 outbox、选择支持 schema 11 的修复版本；不能直接装旧版本后删库，也不能用旧备份覆盖新未同步操作。此次没有执行真实数据回退。

仍需完成：7 项 lint、真机 G 前后性能、C 滚动和完整生产备份交互、代表性 D 原生故障及 F 更多退出时序。剩余热点包括备份清单同步扫描、必要生命周期的全快照及 sessions 浅复制；取消同步仍以批次边界为主，发现 cancel 已有独立清理测试，但没有承诺所有网络请求即时中断。

下一阶段再处理备份与元数据依赖调度、静默同步、审核音频双端缓存/预取。没有用定时 synchronize() 冒充静默同步。
