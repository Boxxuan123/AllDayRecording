# 手机片段标注体验重构交付（2026-09-25）

## 工作区与范围

- 手机/手表项目初始 HEAD：`8c78bac85e036bd62dfaa461f016171538e31643`。
- 服务端初始 HEAD：`61b40024fc1491600d49ba4f84faa2c8e37c6633`。
- 开始时两个工作区均无未提交修改。未回滚工作区、清库、删除录音或清空用户 outbox。
- 本轮修改手机生产代码及验证工具；服务端代码未修改。未增加声纹训练、自动同步、审核包或撤销协议。

## 实现

统一编辑器默认逐条处理。顶部以本句/本组为范围显示待标注和已标注数量；真实冲突/过期优先进入需复核。指定已标注句进入查看/修改；已标注列表保留结果及同步状态。

正文默认四行，支持展开；播放/停止显示实际状态，前后文为次级选项。人物可搜索缓存列表，主动选择新建才显示姓名输入。人物和声音类型分别编辑；未改声音类型不写分类。新条目不沿用上一条人物。

“保存并继续”只在本地事务成功后推进，不自动播放。反馈及查看刚才结果的入口保留在编辑器内；数据库失败保留表单，已提交但读取失败禁止重复保存并提供只读重试。

批量独立进入，默认不全选；跨页保留，全选仅覆盖当前筛选待标注项，显示筛选外选择数量，并以每页 20 条查看选择。保存最多 2000 条。切换视图/对象时，未保存表单先确认。

打开期间范围按稳定 utterance ID 保持；后台更新不替换核对过的版本，不清空输入/多选。来源删除时在当前范围保留失效说明；人物改名/重新归组不会使本次范围丢失。人物页提供再次查看上次范围的入口。

样本查询/重试移入“更多 → 样本处理详情”；编辑器复用既有冲突处理组件。人物页、会话时间线、审核原句入口同步显示标注结果；不会自动采纳样本、改变匹配授权或关闭 review_item。

## 状态映射与事实依据

| 依据 | 状态 |
| --- | --- |
| 只有模型 speakerLabel 或默认 soundKind | 待标注 |
| outbox 中未确认的人工操作，事务已提交 | 已标注；已在手机保存·待同步到电脑 |
| outbox.applied_revision 存在，逐资源投影尚未到齐 | 已标注；电脑已接收，结果更新中 |
| 当前有效 person_annotation 或非空 annotation_fact_ids.sound | 已标注；已同步 |
| 未接受操作的 last_error 非空 | 保留已标注；同步失败提示 |
| conflicts 中的人工操作、annotation_review.dimensions、annotation_outdated、非 active 来源 | 待标注中的需复核；保留选择与原因 |

`annotationFacts` 只是每次读取时由现有持久事实推导出的展示字段，未建立完成表。人物和声音分别推导，任一真实冲突/过期使整条进入需复核；另一个有效维度仍显示其结果。已标注只意味着至少一个人工决定有效保存，不代表两个维度均确认，也不代表声纹样本已采纳。

服务端证据：`person_annotation.person_id/state`、`annotation_fact_ids.sound`（数组）、`annotation_review.dimensions.person/sound`、`annotation_outdated`、utterance.status。

手机证据：outbox 的操作种类、selections、person_id/new_person_id、sound_kind、applied_revision、projected_resource_ids、last_error；conflicts 的 kind/status 和结构化 selections。冲突不再使用 JSON 字符串 includes 匹配。

新保存的 selection 同时持久化 session_id/start_ms/end_ms，明确检测来源范围变化。文本版本变化不直接清除已经有效的人工事实；保存时仍按当前生产协议核对用户看到的 revision。服务端 DTO/契约保持不变。

## 事务与关键文件

- `phone/src/main/ets/v3/domain/PhoneV3AnnotationState.ets`：共享状态 selector、文案与 UI 内容键。
- `phone/src/main/ets/v3/domain/PhoneV3AnnotationEditor.ets`：稳定范围、聚焦、筛选、跨页选择、计数与版本保护。
- `phone/src/main/ets/v3/domain/PhoneV3LocalAnnotation.ets`：本地操作、已接受但未投影操作与冲突的事实叠加。
- `phone/src/main/ets/v3/application/PhoneV3UseCases.ets`：queueAnnotation 组合事务；事务内核对版本、缓存人物并写逐维度操作，不嵌套事务。仅修改一维时只写该维。
- `phone/src/main/ets/v3/presentation/PhoneV3ViewModel.ets`：重复提交保护、持久化/读取失败区分、只读重试、播放器回调代际隔离。
- `phone/src/main/ets/v3/presentation/PhoneV3SpeakerAnnotationPanel.ets`：实际 ArkUI 编辑器。
- `PhoneV3PeoplePage.ets`、`PhoneV3SessionDetailPage.ets`、`PhoneV3ReviewInboxPage.ets`：相关入口反馈。
- `phone/src/test/PhoneV3AnnotationState.test.ets`、`PhoneV3AnnotationEditor.test.ets`、`PhoneV3UseCases.test.ets`：真实 selector/编辑状态/用例行为测试。
- `tools/quality/check-annotation-experience.cjs`：实际 PhoneProjectionRepository + SQLite + UseCases + 投影/selector 的重启、回执、事务和规模回归。
- `tools/quality/check-review-audio.cjs`：实际 ViewModel/播放器的保存回调与原样本试听门槛回归。

保存保留现有按维度依赖、版本校验和冲突协议。不等待电脑、不启动备份。网络同步、样本审核仍使用既有流程。

## 实际验证

所有命令在相应项目根目录运行。测试所用 SQLite 为临时合成数据库，不读取或改写用户业务数据库。

PowerShell 环境：

```powershell
$env:DEVECO_STUDIO_HOME='C:\Program Files\Huawei\DevEco Studio'
$env:DEVECO_SDK_HOME="$env:DEVECO_STUDIO_HOME\sdk"
$env:HVIGOR_USER_HOME="$PWD\.hvigor-local"
$env:HVIGOR_TEST_EXECUTABLE="$env:DEVECO_STUDIO_HOME\tools\hvigor\hvigor\bin\hvigor.js"
$env:PHONE_TEST_TYPESCRIPT="$env:DEVECO_STUDIO_HOME\tools\hvigor\hvigor-ohos-plugin\node_modules\typescript"
```

| 命令 | 结果 |
| --- | --- |
| `node tools/quality/run-host-tests.mjs` | PASS 140/140，手机 73、手表 67，无忽略 |
| `& "$env:DEVECO_STUDIO_HOME/tools/node/node.exe" tools/quality/check-annotation-experience.cjs` | PASS：双维度离线保存、数据库重开、网络失败、回执先于投影、旧操作清理、改名/文本更新、回滚、拒绝、来源范围变化、版本拒绝 |
| 同上 Node，`tools/quality/check-review-audio.cjs` | PASS：原完整试听门槛、撤回、停止/切换/旧回调，新增真实 ViewModel 双击/数据库失败/读取失败/只读重试/片段播放状态 |
| 同上 Node，`tools/quality/check-phase2-sync.cjs` | PASS：1001 条持久操作重启，32 条/64 KB 分批，依赖、冲突隔离、断网重试、取消及并发锁 |
| `node tools/quality/run-code-linter.mjs` | FAIL：5 项既有 avoid-overusing-custom-component-check，均在未修改文件；新增页无剩余报告 |
| `git diff --check` | PASS |

规模回归使用 1202 条真实投影片段：全选、跨页、筛选外选择、计数以及 1000 次相同 snapshot 更新合计约 3.8 ms（本机一次运行，不代表手机端帧率）。另有 Hypium 2000 条跨页选择测试和既有 10000 条索引测试。

服务端命令：

```powershell
.venv/Scripts/python.exe -m pytest -q tests/test_phase1_human_facts.py tests/test_phase2_samples.py tests/test_annotation_purposes.py tests/test_phase2_preflight.py
```

结果：41 passed。首次沙箱运行因音频子进程受限出现 6 个样本失败；允许本地子进程后完整重跑通过。

主机测试工具修正：当前 SDK 将 phone 测试编译到 `.test/phone`，内置 Hypium 却仍读取 `.test/default`。门禁现在核对新字节码时间，将本次生成物复制到启动目录后执行并核对测试数量，避免把昨天的 62 条旧报告误判为成功。

Lint 剩余项：PhoneV3HomePage:13、PhoneV3MorePage:6、PhoneV3SessionInfoTabs:24/89/177。已通过完整诊断定位并确认这些文件没有本轮 diff。没有禁用规则或宣称 lint 全部通过。

## 手机完整构建

```powershell
$env:JAVA_TOOL_OPTIONS='-Djdk.util.zip.disableZip64ExtraFieldValidation=true'
node "$env:DEVECO_STUDIO_HOME/tools/hvigor/hvigor/bin/hvigor.js" --mode module -p product=phone -p module=phone@default -p buildMode=debug assembleHap --no-daemon
```

完整 assembleHap（包含 CompileArkTS、PackageHap、SignHap）成功。上述 Java 环境变量仅作用于本次构建进程，用于当前签名工具的 ZIP64 兼容；没有修改证书或密码。不设置该变量时，本机 SignHap 报 Invalid CEN header。

签名包：`phone/build/phone/outputs/default/AllDayRecording-phone.hap`。

本次日志在项目根目录：`annotation-experience-tests.log`、`annotation-experience-build.log`、`annotation-experience-sqlite.log`、`annotation-experience-audio.log`、`annotation-experience-sync.log`、`annotation-experience-lint.log`。

## 截图与真机验收边界

用户提醒设备已连接后重新检查，识别到 PLR-AL00，分辨率 1316×2832。通过 HDC 覆盖安装签名 HAP，保留应用数据，执行真实界面点击、输入、截图与杀进程重启。以下替代此前设备列表为空时的验收记录。

已执行：

- 人物页进入真实 819 条已标注分组：默认显示待标注 0 和完成态；切换已标注列表、进入单条编辑，正确回填原人物，未确认的声音类型没有被当成人工事实。
- 对一条现有人工标注重新选择原人物（身份信息已脱敏），双击保存。保存期间按钮禁用，返回待同步状态。强制停止应用并重新启动后，外层仍显示已标注 819、待同步 1，单条结果仍在。没有改变这条录音原有的人员归属或声音类型。
- 待标注 924 条分组默认进入单条模式；暂时跳过后切换到下一片段，计数保持 924；批量模式初始已选 0、保存禁用，没有默认全选。
- 新人物输入草稿后切换页签，出现放弃修改确认。测试字符串 AnnotationUITest 已放弃，未创建测试人物。
- 点击真实片段播放按钮，界面进入“正在加载 · 停止”，稍后恢复“播放片段”，未显示播放错误；未进行声音听感或蓝牙路由验证。

真机发现并修复两处布局问题：软键盘默认平移弹层使保存栏不可见；保存结果会继承原滚动位置而隐藏顶部反馈。两个标注弹层改用 RESIZE_ONLY，内容滚动器在主动导航和保存结果刷新后回到顶部。重新完整构建成功并覆盖安装；复测键盘展开时姓名输入框与保存按钮均在键盘上方，放弃草稿和切换列表后内容回到顶部。保存后的滚动复位由相同 Scroller 路径实现，本次没有为了再次触发保存而额外重复写入标注。

真实截图和本轮构建日志在 `outputs/annotation-device-20260925/`：

- `01-open-completed-group.png`：已完成分组入口。
- `02-keyboard.png`：修复前键盘遮挡。
- `04-keyboard-fixed.png`：修复后键盘、输入框和保存栏（草稿已放弃）。
- `05-reopened-persisted.png`：重启后重新进入已保存片段，仍显示待同步。
- `device-fixes-build.log`：修复版完整签名构建成功。

本次保留一条同人物确认操作待同步，未触发整批录音备份。尚未完成的设备验收：电脑端同步投影闭环、蓝牙和退后台音频、明亮模式、系统大字体与其他尺寸设备、跨页批量交互完整流程；相关主机状态测试不能替代这些设备验收。
