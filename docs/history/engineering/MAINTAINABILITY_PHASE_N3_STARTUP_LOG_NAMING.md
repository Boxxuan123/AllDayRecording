# AllDayRecording 维护性收尾 Phase N3 启动日志命名

日期：2026-08-30

基线提交：`71d5b94`

状态：已完成。Phone 启动失败日志不再使用 Phase 6 实验命名；页面路由、加载回调和运行时
行为保持不变。

## 1. 修改边界

本阶段只修改：

- `phone/src/main/ets/entryability/EntryAbility.ets` 的日志标签与错误文案；
- 当前架构、下一步计划与本证据文档。

没有修改 `pages/Index` 路由、Phone 页面、ViewModel、Transport、wire JSON、requestId、
超时/重试值、目录、录音、签名、bundleName、API 23/26 或设备数据。没有安装 HAP 或连接
设备。

## 2. 命名变更

- 新增稳定模块标签常量 `TAG = 'PhoneEntryAbility'`，替代内联的 `phase6Probe`。
- 将 `Failed to load Phone probe page` 改为
  `Failed to load Phone root page`。
- `windowStage.loadContent('pages/Index', ...)`、`err.code` 条件和错误序列化均未改变。

生产源码复查后，旧字符串 `phase6Probe` 与 `Phone probe page` 的命中均为 0。其余带
`Probe` 的名称不是本次遗留日志：

- `WATCH_CONTROL_PROBE/control_probe` 是 Watch/Phone 当前控制通道的 wire 消息类型；
- `diagnostics/SleepModeProbeService` 是计划明确保留、默认关闭且生产 UI 不可达的诊断能力；
- 兼容 facade 中的 Phase 2 注释不是运行时日志标签。

因此本阶段没有误改协议或诊断命名。

## 3. 验证矩阵

| 门禁 | 结果 |
| --- | --- |
| Host Hypium | PASS；Watch 50/50、Phone 3/3，合计 53/53；8,927 ms |
| Code Linter | PASS，0 defects，SDK 26.0.0 / API 26；5.788 秒 |
| Phone `phone@default` Debug HAP | PASS，4.757 秒 |
| 独立 clean Debug `assembleApp` | PASS，6.989 秒 |
| 独立 clean Release `assembleApp` | PASS，6.812 秒 |
| Release `.app` | 358,315 bytes；SHA-256 `eaf48072094e993ef6caed040fd1d0842dbb41a17eb44231909f7524be3c6e47` |
| Release 交付边界 | 恰好两个模块：Watch `entry`/wearable 与 Phone `phone`/phone |
| API 边界 | 两个模块均 compatible 23、target 26 |

Debug 与 Release 构建后 `git status --short` 都只包含本阶段允许清单中的源码/文档变更；
`common/BuildProfile.ets` 继续命中 Phase N2 的精确忽略规则。测试报告、HAP、APP 和本地
签名资料均未进入提交。
