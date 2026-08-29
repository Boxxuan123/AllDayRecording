# Phase 2：手机场景控制 Watch 5 录音

## 结论先行

拿到 Wear Engine 服务审批后，手机侧第三方应用可以调用 `startRemoteApp` 拉起手表侧应用，并通过 P2P 消息与手表侧应用双向通信。因此，“手机发起 → 手表应用被拉起 → 手表开始/停止录音”的技术链路具备官方接口基础。

但是三个能力必须分开验收：

1. **发出控制命令**：Wear Engine P2P 可以实现。
2. **拉起手表应用**：API 23 可使用旧版 `startRemoteApp(deviceRandomId, remoteBundleName)` 拉起整个应用。
3. **自动开始麦克风录音**：系统要求录音在前台启动，不能仅在后台收到消息后静默开麦。正确路线是先把手表 UI 拉到前台，再启动 AudioCapturer 和录音长时任务。麦克风权限未预先授予时，仍需用户在手表确认。

所以目标不是“后台偷偷唤醒并录音”，而是“手机触发官方远程拉起，让手表应用进入前台并可感知地开始录音”。熄屏后的持续录制仍沿用已经通过真机测试的长时任务实现。

## API 23 兼容边界

当前手表工程兼容 API 23。现有 SDK 中：

- Wear Engine 的 P2P `sendMessage`、`registerMessageReceiver` 在 wearable 设备上从 API 18 可用。
- 旧版 `startRemoteApp(deviceRandomId, remoteBundleName)` 从 API 12 可用，适合手机拉起手表应用。
- 可以指定 `UI`、`Service`、`DistributedService` 组件类型的新重载从 API 24 才提供，不能作为本工程 API 23 的基础方案。

因此首版应拉起手表的 `EntryAbility`，不设计 API 24 专属的远程 Service 冷启动。

## 推荐链路

```text
智慧生活场景 / 小艺意图 / 手机应用按钮
                  |
                  v
手机侧 StartRecording / StopRecording 动作
                  |
                  v
Wear Engine 查询已连接 Watch 5
                  |
                  v
startRemoteApp 拉起手表 EntryAbility
                  |
                  v
手表注册消息接收器并回复 READY
                  |
                  v
手机发送带 requestId 的 START / STOP
                  |
                  v
手表幂等执行并回复 ACK + 实际状态 + sessionId
```

不能用固定延时替代 `READY`。应用冷启动、Wear Engine 建链和消息接收器注册存在竞态；以握手和有限重试为准，才能知道命令真的被手表接收。

## 命令协议

首版只保留状态型命令，不使用“切换”命令：

```json
{
  "version": 1,
  "requestId": "唯一请求号",
  "desiredState": "recording",
  "source": "phone_scene",
  "sentAt": 0
}
```

`desiredState` 只取 `recording` 或 `stopped`。这样重复投递不会把状态翻转错：

- 已在录音时再次收到 `recording`：不创建第二个 AudioCapturer，直接 ACK 当前会话。
- 已停止时收到 `stopped`：直接 ACK，视为成功。
- 收到 `stopped` 时有活动会话：必须调用正常 `stop()`，等待 WAV 封口和 `session_summary.json` 落盘后再 ACK。
- 进程意外中断：下次启动先执行 Phase 1E `.wav.part` 恢复，再处理新命令。

## 与智慧生活“应用服务”的关系

截图说明智慧生活场景目前可以选择一批已经接入的“应用服务”，但 Wear Engine 获批不会自动让 AllDayRecording 出现在这个列表。二者是两层独立接入：

- **Wear Engine**：解决手机应用和手表应用之间的拉起、消息、文件通信。
- **HarmonyOS 意图框架 / Intents Kit**：把手机应用内的“开始录音”“停止录音”声明为系统可调用的功能服务。官方流程还包含应用上架、意图注册和审核。

建议先完成手机 App 内两个按钮的 Wear Engine 闭环，再把完全相同的两个动作包装为意图。意图审核通过后，实测它是否进入智慧生活的“应用服务”编排入口；如果该入口还有单独的白名单或业务审核，再按华为开放平台要求补充申请。仅凭当前截图不能证明任意第三方意图都会自动出现。

另一个待验收点是“睡眠模式”能否直接作为智慧生活的触发条件。截图展示的是动作选择页，只能证明场景能调用已接入应用服务，不能证明手机或手表的睡眠模式状态已对第三方场景开放。若系统没有提供该触发器，可先使用智慧生活中的固定时间、手动睡眠/起床场景，或小艺口令来触发同一动作。

## 开发顺序

### Phase 2A：手机按钮最小闭环

1. 新增 phone 模块或独立手机端应用。
2. 完成 Wear Engine 服务申请、Client ID、签名指纹和用户授权。
3. 手机显示 Watch 5 在线状态和“开始/停止”按钮。
4. 实现拉起、READY、命令、ACK，不接智慧生活。
5. 分别测试手表前台、后台、进程不存在、熄屏、睡眠模式五种状态。

### Phase 2B：安全状态机

1. 手表把录音控制从页面按钮抽成唯一的 `RecordingController`。
2. 页面和 Wear Engine 接收器都调用同一个幂等状态机。
3. ACK 只在 AudioCapturer 和长时任务真实启动，或 WAV 真实封口后返回成功。
4. 手机对断连、未授权、手表不在线、录音启动失败给出可解释状态。

### Phase 2C：智慧生活 / 意图接入

1. 手机端声明“开始全天录音”和“停止全天录音”两个意图。
2. 完成开发者测试、上架配置和意图审核。
3. 验证是否出现在智慧生活“应用服务”。
4. 用固定时间或可用的睡眠/起床触发器做端到端测试。

## 必须通过的真机验收

- 手表进程不存在时，手机动作能拉起手表 UI。
- 只有在手表进入前台后才启动录音；未获麦克风权限时不绕过授权。
- 手机收到成功 ACK 后，手表确有新的录音会话和持续任务提示。
- 重复 START 不产生并行会话；重复 STOP 不报错。
- STOP 的 ACK 到达前，最后一段 WAV 已完成封口。
- 手表断连或睡眠模式阻止拉起时，手机明确显示失败或待重试，不假成功。
- 场景执行记录、手机 requestId、手表 sessionId 可以对应追踪。

## 官方依据

- Wear Engine 调测验证：手机侧调用 `startRemoteApp` 能拉起穿戴设备侧应用，并验证手机向穿戴侧发送消息。
  <https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/wearengine_verification-V5>
- HarmonyOS 音频录制概述：持续或后台录制需申请长时任务；录制需要在前台启动，后台启动会失败。
  <https://developer.huawei.com/consumer/cn/doc/doccenter-feature-dev/bpta-audio-record-overview>
- HarmonyOS 意图框架：支持系统推荐和自动编排执行。
  <https://developer.huawei.com/consumer/cn/huawei-hag>
- 意图框架上架配置：应用包内声明意图后，还需在开放平台完成注册和审核。
  <https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/intents-kit-listing-configuration-V5>
