# Phase 6 Phone/Watch 物理 HAP 拆分可行性审计

日期：2026-08-30

分支：`codex/phase6-hap-split-feasibility`

基线：`f09b223`

状态：已完成。真实 Phone/Watch 功能已迁入双 HAP，Lint、Debug/Release 构建、包边界和双端安装前只读数据基线通过；用户已确认双端覆盖安装与真机验收通过，物理拆分获准进入主线。宿主机 runner 未产出新报告的限制继续保留

## 1. 本轮边界

本轮先完成只读设备身份核验和隔离工作树中的构建实验；在用户明确授权后，又完成 Phone/WATCH 5 安装前数据基线：

- 未安装、卸载或覆盖 Phone/WATCH 5 上的应用。
- 仅通过 HDC `file recv -b` 把两端完整 `entry/files` 树各导出两次；没有修改或删除设备端录音与同步清单。
- 对本地副本执行 SHA-256、WAV 和 JSON 一致性检查，备份位于 Git 忽略的 `outputs/device-backups/phase6-pre-split-20260830`。
- 随后把真实 Phone 页面、ViewModel、Receiver、接收索引和资源迁入 `phone` HAP，把共享模型、文件基础设施、协议、Transport、协调器和播放服务迁入 `common` HAR，并将 Watch Sender 留在 `entry` HAP。
- 用户已明确决定不设计 Phone `entry -> phone` 沙箱自动迁移；安装前双份只读备份作为回退点。此决定不改变“不得安装、删除、改名或修改设备文件”的本轮执行边界。

## 2. 平台约束

1. HarmonyOS 一个应用包可以包含多个 HAP，HAP 与模块对应；同一目标设备只允许一个 Entry HAP。Phone 与 wearable 的 `deviceType` 不相交时，可以在同一应用包中分别交付 Entry HAP。参见[模块化设计](https://developer.huawei.com/consumer/cn/doc/doccenter-architecture/bpta-modular-design)和[Hvigor HAP 唯一性校验规则](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/ide-hvigor-verification-rule-V5)。
2. module target 可以限定 `deviceType`、源码和资源，工程应显式配置 product-target 映射，避免无关 target 被重复编译。参见[多目标产物定制](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/ide-customized-multi-targets-and-products-sample-V5)和[多 product/target 构建优化](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-multi-product-target-practice)。
3. 覆盖安装仍受 `bundleName`、`appIdentifier`、版本和模块一致性约束；相同 `versionCode` 下不能改变 Entry 模块名，因此候选从 `1.0.0 / 1000000` 提升到 `1.0.1 / 1000001`。本地签名成功不能替代真机升级检查。参见[应用安装与更新一致性校验](https://developer.huawei.com/consumer/cn/doc/doccenter-getting-started/install-and-update-consistency-verification)。
4. Wear Engine 权限与所选 HarmonyOS 应用绑定，最终必须在两端安装后重新核对应用身份并执行消息、文件和远程控制闭环。参见[Wear Engine 服务开通](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/wearengine_apply)、[应用指纹核验 FAQ](https://developer.huawei.com/consumer/cn/doc/doccenter-dev-faq/faqs-wear-engine-1)和[Wear Engine 验证](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/wearengine_verification-V5)。

## 3. 安装前真机身份基线（只读）

通过 HDC 的系统属性与 `bm dump -n AllDayRecording.huawei.com` 查询：

| 项目 | Phone | WATCH 5 |
| --- | --- | --- |
| 型号 | `PLR-AL00` | `RTS-AL00` |
| deviceType | `phone` | `wearable` |
| bundleName | `AllDayRecording.huawei.com` | `AllDayRecording.huawei.com` |
| appIdentifier | `6917614522462210985` | `6917614522462210985` |
| moduleName | `entry` | `entry` |
| compatible / target API | 23 / 26 | 23 / 26 |
| 当前签名用途 | debug | debug |

结论：两端当前都依赖 `entry` 模块身份。Watch 录音文件位于模块沙箱之下，因此候选结构让 Watch 继续使用 `entry`。Phone 改为 `phone` 后不会自动读取旧 `entry` 沙箱；用户已接受不迁移并以本轮双份只读导出回退，真机验收时应把 Phone 首次进入新沙箱后的空历史视为预期，而不是误报为同步源文件丢失。

## 4. 被否决的方案

### 4.1 两个工程模块都命名为 `entry`

为了同时保留两端模块沙箱路径，实验先尝试让两个设备 HAP 都使用内部模块名 `entry`。

- 根工程节点名与 `module.json5` 模块名不一致时，Hvigor 报 `00303053`。
- 两个根工程节点都命名为 `entry` 时，Hvigor 报 `00303039 Duplicated modules: entry`。

因此当前 DevEco/Hvigor 工程不能用两个独立源码模块直接产出两个同名 `entry` HAP。

### 4.2 同一 `entry` 模块建立 Phone/Watch target

实验随后在同一模块建立 `phone` 与 `watch` target：Phone target 使用 `removePermissions` 删除麦克风、后台运行和振动权限，并用 `source.abilities` 只选择无后台模式的 Phone Ability。

Phone target 可以构建成功，但 Hvigor 明确警告模块自身在 `module.json5` 声明的权限不应通过 `removePermissions` 删除。按官方[拆包工具](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/unpacking-tool)解包后确认：

- Phone HAP 仍包含 `MICROPHONE`、`KEEP_BACKGROUND_RUNNING`、`VIBRATE`。
- Phone HAP 仍包含带 `audioRecording` 的 Watch `EntryAbility`。
- `source.abilities` 没有形成预期的物理 Ability 隔离。

因此单模块多 target 不能满足“Phone 不声明录音权限和后台录音模式”的 Phase 6 验收条件。

## 5. 通过的本地产品候选

候选结构：

- Watch：模块名 `entry`，`deviceTypes = [wearable]`，保留现有录音 Ability、权限和模块沙箱名。
- Phone：模块名 `phone`，`deviceTypes = [phone]`，真实 Phone 页面、Receiver、接收索引和 Entry Ability，无录音相关权限和后台模式。
- Common：模块名和包名 `common` 的本地 HAR，提供两端共享的模型、表现状态、WAV/原子文件、协议、Transport、协调器和播放服务。
- 两端 HAP 使用相同 `bundleName`、`client_id`、`1.0.1 / 1000001` 版本和 API 23/26 配置，由同一工程签名配置打包。
- Watch 与 Phone 的 `Index.ets` 分别只挂载本端 Root，不再使用运行时设备类型分支；Sender 与 Receiver 也分别留在对应 HAP。

构建命令：

```sh
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
clean assembleApp -p product=default -p buildMode=debug --no-daemon
```

Release 在再次 `clean` 后把 `buildMode` 改为 `release` 独立执行。Debug 和 Release 均为 `BUILD SUCCESSFUL`。解包后的 `.app` 只包含两个目标 HAP：

| 字段 | Watch HAP | Phone HAP |
| --- | --- | --- |
| bundleName | `AllDayRecording.huawei.com` | `AllDayRecording.huawei.com` |
| moduleName / type | `entry` / Entry | `phone` / Entry |
| deviceTypes | `wearable` | `phone` |
| compatible / target API | 23 / 26 | 23 / 26 |
| client_id | `6917614522462210985` | `6917614522462210985` |
| 权限 | 麦克风、后台运行、振动 | 无 |
| backgroundModes | `audioRecording` | 无 |

本次产物 SHA-256：

| 模式 | `.app` | Watch HAP | Phone HAP |
| --- | --- | --- | --- |
| Debug | `2293981112666fb67544f2b0adbaaeec3797b36ce431d77c62d1f10e91bf3fe4` | `b5cba55d95aafa44dd6013a8f48b85b8b0e7ba57e438dbcd141a409e2dda1ce1` | `9fe1a346a872ee1fd4024e5bac8f8c9715c072d56e5514a6d85741326b9f48ea` |
| Release | `49174f9446b37ebca12c595c72e1fadc4089d38658158470ede9f45b46b3bd27` | `0c6c2b0cbaad6365773179a3c957fc26d74e74299d026368c8bca4e5e80737df` | `c7b11795a5888a02debbfcb5a91f1f5e7c1b3158c9e00b56b0266db0af954046` |

这些摘要只证明本轮本地产物身份，不代表真机文件完整性验收。

质量门禁结果：

- `hvigorw --no-daemon codeLinter`：`PASS (0 defects, SDK 26.0.0 / API 26)`。
- `entry@default` 与 `phone@default` 宿主机测试均完成 ArkTS 编译，但 Darwin runner 启动后持续无输出且没有生成 `test_result.txt`；两次均已终止，不能计为测试通过。源码测试数量仍为 46（Watch 侧 43、Phone 侧 3），这里只报告数量，不报告通过数。
- `entry@ohosTest` 测试 HAP 构建成功，但没有在设备执行。
- Release source map 边界检查中，Watch 包内五个 Phone Root/ViewModel/Receiver/Store 标识计数均为 0；Phone 包内六个 Watch Root/ViewModel/录音/Sender 标识计数均为 0。
- `master` 上 Phase 5 的 46/46 报告仍是已提交基线，但不能替代本实验分支的新报告。

## 6. 当前结论

物理拆分已通过包模型、本地产品构建和用户真机验收，批准进入产品主线：

1. Watch 可继续使用 `entry`，避免主动改变最重要的录音源目录。
2. Phone 改用 `phone` 后沙箱路径改变；按用户决定不做迁移，新模块首次启动时旧接收历史不可见，旧内容由安装前备份保全。
3. 真实 Phone/Watch 功能和测试源码已经迁入对应模块，`common` HAR 只承载共享实现；当前包边界没有检测到跨端页面或端侧 facade 泄漏。
4. 本地包中的相同 `bundleName`/`client_id`、版本提升与共享签名配置本身不能替代真机；本阶段最终以用户报告的双端覆盖安装与验收通过作为运行时批准证据。

## 7. 数据保全结果与下一道硬门禁

已完成的数据保全基线：

- WATCH 两份正式导出各 29 个文件、24,625,471 字节，逐文件 SHA-256 清单完全一致。
- Phone 两份正式导出各 25 个文件、30,716,796 字节，逐文件 SHA-256 清单完全一致。
- WATCH 19 个 WAV 与 Phone 接收索引中的 19 个自动同步副本逐一同大小、同 SHA-256；所有 WAV 均为 16 kHz、mono、16-bit PCM，无解析失败和 `.part`。
- 完整验证报告保存在本地忽略目录 `outputs/device-backups/phase6-pre-split-20260830/BACKUP_VERIFICATION_REPORT.md`，不进入 Git。

覆盖安装前的本地任务已完成：真实功能迁入双 HAP，Debug/Release 与 `.app` 解包边界通过，版本提升到 `1.0.1 / 1000001`，安装候选复制到 Git 忽略的 `outputs/phase6-hap-split-20260830`。Phone 数据迁移按用户决定取消，以双份只读备份回退。

用户于 2026-08-30 明确报告 Phone 与 WATCH 5 覆盖安装完成并验收通过，因此 Phase 6 的安装和运行时门禁关闭。Codex 本轮没有代替用户安装、卸载、删除、改名或修改设备文件，也没有把安装包成功等同于用户验收。

宿主机 runner 问题作为独立已知限制保留：在生成新报告前，不把源码中的 46 个测试写成 Phase 6 新报告通过；它不推翻此前已提交的 Phase 5 测试基线和本次用户真机结论。

任何一项失败，都应保留当前单 HAP 产品结构；逻辑 Phone/Watch 源码边界可以继续维持，不把物理拆分作为可维护性重构的强制完成条件。
