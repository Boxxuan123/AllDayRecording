# AllDayRecording 维护性收尾 Phase N2 构建洁净度

日期：2026-08-31

基线提交：`6fdfba6`

状态：已完成。`common/BuildProfile.ets` 已从版本控制中移除，并由唯一的根目录精确规则
`/common/BuildProfile.ets` 忽略；Debug/Release 切换不再产生源码树差异。

## 1. 修改边界

本阶段只改变构建生成文件的版本控制边界并同步维护性文档：

- `.gitignore` 增加 `/common/BuildProfile.ets`；
- Git 不再跟踪 `common/BuildProfile.ets`；
- 更新当前架构、下一步计划与本证据文档。

没有修改 Hvigor 配置、ArkTS 生产/测试代码、依赖、签名、bundleName、API 23/26、模块名、
wire 协议、录音/同步目录或设备数据。没有安装 HAP 或连接设备。

## 2. 生成来源与引用检查

- `common/hvigorfile.ts` 使用平台 `harTasks`；本机 DevEco 的
  `hvigor-ohos-plugin/src/tasks/common/task-names.js` 将 `CreateHarBuildProfile` 描述为创建
  HAR 的 `BuildProfile.ets`。
- `har-build-profile-task.js` 通过 HAR 的生成路径写入 `HAR_VERSION`、
  `BUILD_MODE_NAME`、`DEBUG` 与 `TARGET_NAME`；实际构建日志也执行
  `:common:default@CreateHarBuildProfile`。
- 排除该文件本身与构建输出后，仓库内生产源码、测试、脚本和配置对 `BuildProfile` 及上述
  常量的搜索结果均为 0。
- 删除磁盘文件后执行 clean Debug，任务在编译前自动重建该文件并完成整个 `.app` 构建，
  因而干净检出不依赖仓库保存一份模式相关副本。

## 3. 修复前精确复现

从无差异的 `6fdfba6` 分别执行独立 clean 构建：

| 模式 | 结果 | 唯一 Git 差异 |
| --- | --- | --- |
| Debug | PASS，7.991 秒 | class 声明增加尾随空格，文件末尾换行被移除 |
| Release | PASS，7.349 秒 | 另把 `BUILD_MODE_NAME` 改为 `release`、`DEBUG` 改为 `false`，并产生同样的格式差异 |

两次 `git status --short` 都只显示 `M common/BuildProfile.ets`。Debug 证据采集后先用
`apply_patch` 精确恢复基线，再从干净状态运行 Release；没有用自动 `git checkout` 掩盖其他
源码变化。

## 4. 最小修复与洁净度证明

选择计划中的第一优先方案：取消跟踪稳定可重建文件，并加入精确忽略规则。没有使用
`**/BuildProfile.ets`、`*.ets` 或其他会隐藏源码/配置的宽泛模式，也没有改写 Hvigor 的
生成路径。

取消跟踪后的目标索引状态下再次分别执行：

| 模式 | 结果 | 构建后的未暂存差异 |
| --- | --- | --- |
| Debug clean `assembleApp` | PASS，7.886 秒 | `git diff --exit-code` = 0 |
| Release clean `assembleApp` | PASS，7.314 秒 | `git diff --exit-code` = 0 |

两次构建后生成文件均仍存在于磁盘，且 `git check-ignore -v` 唯一命中
`.gitignore` 中的 `/common/BuildProfile.ets`。提交后 `git status --short` 应为空；生成文件
无需删除，后续模式切换会由 Hvigor 覆盖但不会进入版本控制。

## 5. 统一验证矩阵

| 门禁 | 结果 |
| --- | --- |
| Host Hypium | PASS；Watch 50/50、Phone 3/3，合计 53/53；10,100 ms |
| Code Linter | PASS，0 defects，SDK 26.0.0 / API 26；5.945 秒 |
| `entry@ohosTest` Debug 测试 HAP | PASS，4.338 秒；仅保留既有测试资源重复声明提示 |
| 独立 clean Debug `assembleApp` | PASS，7.886 秒；无新增未暂存差异 |
| 独立 clean Release `assembleApp` | PASS，7.314 秒；无新增未暂存差异 |
| `common@default` Release `assembleHar` | PASS，4.130 秒；`common.har` 32,145 bytes |
| Release `.app` | 358,309 bytes；SHA-256 `0b8c8d6725495cc34aabcb9374facee5de134f8ebcde2054fdac709feed880c5` |
| Release 交付边界 | 恰好两个 HAP：`AllDayRecording-watch.hap` 与 `AllDayRecording-phone.hap` |
| 模块/API 边界 | Watch `entry` 仅 wearable，Phone `phone` 仅 phone；compatible 23、target 26 |

本阶段只调整可重建派生文件的 Git 边界，不改变运行时行为。构建、测试报告、HAR、HAP、
APP 和本地签名资料均保持在既有忽略范围内，没有进入提交。
