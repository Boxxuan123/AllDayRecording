# Wear Engine 指定 UI 启动条件与手表通知降级方案

## 结论

`startRemoteApp(deviceRandomId, remoteApp, startConfig)` 这个可以指定 `EntryType.UI` 和 `EntryAbility` 的新重载，编译接口从 HarmonyOS `6.1.1(24)` 开始提供。它要真正生效，不能只修改工程的 `targetSdkVersion`，还必须同时满足以下条件：

1. 手机侧使用 API 24 或更高版本的 SDK 编译，才能引用 `EntryType`、`StartConfig` 和新重载。
2. 手机当前安装的 HarmonyOS/Wear Engine 运行时实际实现了这个新重载。
3. 对端设备及其 Wear Engine 运行时支持按指定组件类型启动 UIAbility。
4. 手机与手表在线，应用包名、签名身份、Client ID、Wear Engine 服务审批及用户授权保持一致。
5. 真机调用确实进入三参数新重载，而不是被旧运行时按 `startRemoteApp(deviceRandomId, remoteBundleName, ...)` 解释。

当前工程已经是 `targetSdkVersion 26.0.0`，所以“继续提高 target API”不是本次故障的修复方法。真机测试中：

- `wearEngine.EntryType` 在运行时为 `undefined`；
- 改用字面量 `UI` 后，新调用返回 `401`，并提示 `remoteBundleName length cannot exceed 255`；
- 这个错误表明运行时把第二个参数对象当成了旧接口的 `remoteBundleName` 字符串参数。

因此，当前 Mate 70 Pro + WATCH 5 组合虽然能用 API 26 SDK 编译新代码，但实际 Wear Engine/手表平台尚未提供可用的新重载。未来只有在手机系统、Wear Engine 服务和手表侧平台共同更新后，才能重新做真机能力探测；更新工程 API 版本本身不能补齐运行时能力。

## 新旧接口边界

| 能力 | SDK 起始版本 | 当前真机结论 |
| --- | --- | --- |
| `startRemoteApp(deviceRandomId, remoteBundleName)` | API 12 | 可调用，但只表示请求启动对端应用，不能证明手表 UI 已进入前台 |
| `EntryType.UI`、`StartConfig` | API 24 | 编译可见，当前真机运行时不可用 |
| `startRemoteApp(deviceRandomId, remoteApp, startConfig)` | API 24 | 编译通过，但当前真机被旧运行时错误解析 |
| Wear Engine P2P 消息/文件传输 | 现有 API 23 兼容链路 | 已继续使用，不受本次降级影响 |

## 为什么不能在后台直接开麦

华为音频录制说明明确要求：录制必须在前台启动，启动后才可以退到后台；在后台首次启动录制会失败。`AUDIO_RECORDING` 长时任务的作用是让已经在前台成功启动的录音继续运行，并不会授予应用在后台首次打开麦克风的能力。

因此，本工程不再把 `6800301` 或 `system error` 当成重试问题，也不再尝试通过调整长时任务调用顺序绕过系统限制。

## 已批准的降级链路

```text
手机点击“启动手表录音”
        |
        v
Wear Engine 发送带 requestId 的录音命令
        |
        v
手表判断 UI 是否已在前台
   |                    |
   | 是                 | 否
   v                    v
直接启动录音       保存待处理 requestId
                        |
                        v
                发布可点击通知并振动提示
                        |
                        v
                 用户在手表点一次通知
                        |
                        v
              EntryAbility 进入前台后自动录音
                        |
                        v
              把最终 recording ACK 发回手机
```

手机会先显示“等待在手表点击通知”，不会把后台收到命令误报成录音成功。只有 `AudioCapturer` 和录音长时任务真实启动后，才回传最终 `recording` 状态。

### 通知首次授权

真机首次验证曾返回 `1600004 Notification disabled`，说明应用通知开关关闭时，系统会在发布通知前直接拒绝请求。修订后的应用会在手表页面进入前台且 UI 加载完成后检查通知状态：

- 尚未授权时，主动显示系统通知授权窗口；
- 用户曾拒绝授权时，页面显示“开启通知”按钮，点击后进入本应用通知设置；
- 后台命令发现通知仍关闭时，向手机返回“请先在手表前台允许通知（1600004）”，不再只显示英文系统错误；
- 通知授权只用于可感知的录音启动提醒，不会改变麦克风权限或录音文件。

## 保留不变的安全边界

- 不删除、移动或重命名任何手表录音文件。
- 不修改现有 WAV 分片、`.part` 恢复、自动同步和手动补拉逻辑。
- 覆盖安装只允许使用保留应用数据的安装方式，不卸载应用。
- 后台收到 `stopped` 时仍可走现有正常停止和封口流程。
- 通知只负责取得一次明确的用户前台操作，不绕过麦克风授权。

## 真机验收标准

1. 手表应用在前台时，手机点击启动后直接开始录音并收到最终 ACK。
2. 首次打开新版手表应用时，系统通知授权窗口可以正常显示；允许后页面不再显示“开启通知”。
3. 手表应用在后台或息屏时，手机先显示“等待手表点击通知”，手表出现通知和振动提示。
4. 点一次通知后，手表进入前台并自动开始录音，无需再点页面里的开始按钮。
5. 录音启动后可再次熄屏，分片持续封口并按现有队列自动传到手机。
6. 手机收到最终 `recording` 状态；重复开始不创建第二个录音实例。
7. 停止录音后最后一片完成封口，手表已有文件全部保留。

## 依据

- 本机 DevEco SDK：`@hms.health.wearEngine.d.ts` 将 `EntryType`、`StartConfig` 和三参数 `startRemoteApp` 标记为 `since 6.1.1(24)`；旧版按包名启动的重载标记为 `since 5.0.0(12)`。
- [华为 Wear Engine 调测验证](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/wearengine_verification-V5)
- [华为音频录制概述](https://developer.huawei.com/consumer/cn/doc/doccenter-feature-dev/bpta-audio-record-overview)
- [后台任务管理 API](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/js-apis-resourceschedule-backgroundtaskmanager)
- [通知管理 API](https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V3/js-apis-notification-0000001333321097-V3)
