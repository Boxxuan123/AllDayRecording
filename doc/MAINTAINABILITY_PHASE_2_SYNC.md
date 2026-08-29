# Phase 2：Wear Engine 传输与同步状态机拆分

## 1. 当前状态

截至 2026-08-29，Phase 2 的代码拆分、本地验证和 WATCH 5 真机回归均已完成；用户确认本阶段真机测试通过。

本阶段不改变录音格式、采样参数、文件路径、JSON 清单版本、Wear Engine wire JSON、重试次数或超时值。手表源录音继续在成功、失败和重试后保留；手机仍只有在文件安全落盘并写入接收索引后才发送 ACK。

## 2. 拆分结果

| 新边界 | 职责 |
| --- | --- |
| `sync/protocol/WatchFileSyncProtocol.ets` | 协议常量、消息类型、编解码、exact/legacy 文件键 |
| `sync/transport/WearEngineTransport.ets` | 对端发现、应用身份、接收器注册、原始消息/文件发送、远端启动和通道销毁 |
| `sync/transport/WearEngineTransportPolicy.ets` | 200/201/202/206/207 结果解释、可重连错误与授权错误分类 |
| `sync/watch/AutomaticSyncQueue.ets` | `automatic_sync_queue_v1.json` 恢复、过滤、去重、持久化和完成计数 |
| `sync/watch/WatchSyncCoordinator.ets` | 自动/手动串行、待处理手动请求、文件进度停滞与 durable ACK 等待 |
| `sync/phone/PhoneSyncCoordinator.ets` | 手机 requestId 生命周期、握手超时、待接收 descriptor、重复文件去重和启动取消 token |
| `sync/control/WatchRecordingControlCoordinator.ets` | Watch 端并发/重复命令处理，以及 Phone 端 READY、ACK、`pending_user_action` 状态与超时 |
| `sync/state/SyncClock.ets` | 可替换的系统时钟/调度边界，测试使用 fake clock |

`services/RecordingTransferService.ets` 从 2,047 行降到 1,725 行，继续作为现有页面调用的兼容 facade。Wear Engine 的原始 `sendMessage`、`transferFile`、receiver 注册、`startRemoteApp` 和 `destroy` 只存在于 Transport；facade 中与同步有关的布尔状态已从原来的多组组合缩减为展示所需的 `remoteComplete`、`fileTransferActive` 和 `transferAutomatic`。

旧路径 `services/WatchFileSyncProtocol.ets` 保留为 re-export 兼容入口；生产代码和测试已经改用 `sync/protocol`。Phase 0 的 `SyncStateCharacterization.ets` 已删除，原用例改为直接测试生产队列和协调器。

## 3. 保持不变的兼容契约

- 协议版本仍为 1，消息类型字符串及 JSON 字段不变。
- 手动同步 requestId 仍为 `Date.now().toString()`；自动 requestId 仍为 `auto_${Date.now()}`；控制 requestId 仍为 `control_${Date.now()}`。
- 自动队列文件仍为 `automatic_sync_queue_v1.json`，版本仍为 1，字段仍为 `version/updatedAt/completedCount/files`。
- 手机接收目录、文件命名、接收索引和 exact/legacy 文件键不变。
- 单次手动同步仍只发送一个文件；清单分页仍为每页 24 个键。
- 消息/文件重试仍为 3 次，基础退避仍为 800 ms。
- 同步握手仍为 20 秒；传输进度停滞和 durable ACK 等待仍各为 60 秒；`pending_user_action` 仍为 5 分钟。
- API 23 上 `startRemoteApp` 的 UNKNOWN_ERROR 兼容路径和硬重连 `stop -> destroy -> start` 保留。

## 4. 直接生产状态测试

本地 Hypium 实际报告为：

```text
Tests run: 35, Failure: 0, Error: 0, Pass: 35, Ignore: 0
```

Phase 2 新增或替换为直接生产实现的覆盖包括：

- wire JSON golden fixture，防止字段名、顺序和消息类型意外变化。
- 自动队列有效恢复、缺失文件清理、损坏 JSON、重复路径和原 requestId 规则。
- 自动同步中收到手动请求、待处理请求提升、活动/待处理 requestId 去重。
- durable ACK 只接受匹配 descriptor，乱序或过期 ACK 不结束当前文件。
- 进度 60 秒不变和文件 100% 后 ACK 60 秒未到的独立 fake-clock 测试。
- Phone 已标记文件持久化成功但 Watch 未收到 ACK 时，Watch 仍进入超时并保留重试状态。
- 自动消息可跨当前手动 requestId 接收，重复 descriptor 和重复文件只计一次。
- 手机同步握手超时，以及页面退出时取消仍在启动中的 receiver token。
- Watch 端控制命令忙碌与重复 ACK 重放。
- `pending_user_action` 中收到最终 ACK，以及五分钟未收到最终 ACK 的超时。
- Wear Engine 206/1008500003 被归类为需要重连的通信错误。

测试首次在受限沙箱内启动时，Previewer 无法连接本地 command pipe/WebSocket；日志明确记录 `command pipe connect failed`。清理两组旧的项目测试进程后，以本机权限运行同一命令，最终复核用时 4.770 秒并生成文本和 HTML 报告。此问题属于测试宿主，不计作业务测试结果。

## 5. 构建证据

- `entry@ohosTest` Debug 测试 HAP：构建成功，Hvigor 4.881 秒；只保留既有的 `start_window_background` 测试资源重复声明提示。该结果仅表示测试 HAP 可构建。
- 独立 `clean` 后 Debug：构建成功，Hvigor 4.974 秒；signed HAP 为 728,054 bytes，SHA-256 为 `44ac3d4ad72fcb72a2912129617d07a5f66e61eda0aced82985e45981fee891e`。
- 再次独立 `clean` 后 Release：构建成功，Hvigor 5.018 秒；signed HAP 为 374,239 bytes，SHA-256 为 `dcab9abc45430e9902e929162ab3a04a6544989322cbcaf914ec88b13a946f2a`。
- Release `pack.info` 仍声明 `phone`、`wearable`，compatible API 23、target API 26，模块类型仍为 `entry`。

## 6. 真机验收建议

本阶段由 Codex 完成的本地验证没有访问、安装或修改设备；WATCH 5 回归结论由用户于 2026-08-29 确认为通过。后续安装新 HAP 前，仍须执行项目计划第 4 节的 WATCH 5 只读导出与双份 SHA-256 清单比对。

真机建议按以下顺序验收：

1. 手表开始并停止一次短录音，确认新 WAV 正常封口、可播放，自动队列开始发送。
2. 自动文件发送过程中，在手机点击“同步手表文件”，确认显示“已加入队列”，当前自动文件结束后手动同步优先执行。
3. 手机保存后确认手表队列只移除已收到 durable ACK 的条目；源 WAV 仍保留。
4. 重复点击同步或让同一文件再次出现，确认手机不会产生重复索引/重复计数。
5. 执行一次硬重连，再次同步，确认 receiver 重建后仍能接收消息和文件。
6. 分别验证手机启动/停止手表录音；若进入 `pending_user_action`，在手表通知中完成操作并确认手机收到最终状态。

上述步骤已由用户完成真机回归并确认通过；Phase 2 可按窄范围审计后提交。
