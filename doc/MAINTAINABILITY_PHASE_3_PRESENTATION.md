# Phase 3：手机/手表表现层拆分

## 1. 当前状态

截至 2026-08-30，Phase 3 已完成。用户已确认 WATCH 5 真机视觉与录音流程回归通过，代码提交为 `2cfa334`。Codex 本阶段未安装或访问 WATCH 5，也未读取或改动设备录音文件。

本阶段不改变录音参数、文件格式、同步协议、存储路径、导航结构、手表圆屏尺寸或 API 26 视觉保护。

## 2. 拆分结果

| 边界 | 职责 |
| --- | --- |
| `pages/Index.ets` | 仅检查 `deviceInfo.deviceType` 并挂载 Phone/Watch Root |
| `presentation/phone/PhoneRootPage.ets` | 手机生命周期、Tabs、Navigation 和 API 26 沉浸材质保护 |
| `presentation/phone/PhoneRecordingViewModel.ets` | receiver、播放、手动同步、硬重连、录音控制和手机 UI 状态 |
| `PhoneHomePage/PhoneRecordingHistoryPage/PhoneSettingsPage/PhoneDeveloperPage` | 手机四个独立页面组件 |
| `PhoneSyncProgressView.ets` | 手机同步进度的单一展示组件 |
| `presentation/watch/WatchRootPage.ets` | 手表生命周期与竖向 Swiper |
| `presentation/watch/WatchRecordingViewModel.ets` | 录音、播放、自动发送、权限、通知降级、计时和手表 UI 状态 |
| `WatchHomePage/WatchDeveloperPage` | 手表首页与开发者页两个独立圆屏组件 |
| `presentation/shared/RecordingPresentation.ets` | 不可变同步 UI 快照、生命周期 token 和格式化函数 |

`Index.ets` 从 1,394 行降到 17 行，不再直接拥有录音、播放、Wear Engine、权限、计时或导航业务。

## 3. 状态与生命周期

- 原先 16 个独立同步/文件进度字段收束为每次整体替换的 `PhoneSyncUiState`，避免页面读到混合旧新批次的状态。
- Root 的 `aboutToAppear/aboutToDisappear` 只转发给 ViewModel；页面组件不直接调用异步服务。
- 所有从 UI 事件发起的 Promise 都有成功/失败观察者；清理任务也保留引用直到完成。
- 页面退出会使 lifecycle token 失效，旧 receiver、播放和录音回调不再修改新页面状态。
- 快速离开并重进时，必须等待上一次资源清理完成才能重新注册；清理失败会阻止重复 receiver/录音服务。
- 手表计时器由 ViewModel 拥有，页面退出及 token 失效时都会清理。

## 4. UI 兼容性

- 手机仍为“首页/录音记录/设置”三个底部 Tab，设置中仍通过 `NavDestination` 进入开发者界面。
- API 26 仍使用 `ImmersiveMaterial(THIN)`，API 23 回退路径仍使用透明背景和 `COMPONENT_THICK` 模糊。
- 手表仍为竖向 Swiper，默认索引 1 为首页，下滑进入开发者页。
- 手表首页和开发者页的宽度、按钮高度、字号、padding、颜色资源和原有中文固定文案保留。

## 5. 测试与构建证据

Hypium 最终文本报告：

```text
Tests run: 39, Failure: 0, Error: 0, Pass: 39, Ignore: 0
```

Phase 3 新增 4 项直接生产纯逻辑测试：同步进度整体快照、空闲默认值、页面退出/重启 token 失效和格式化兼容。Phase 0–2 原有 35 项全部继续通过。

- 独立 `clean` Debug：Hvigor 5.918 秒；signed HAP 771,103 bytes，SHA-256 `8b3179bd7bd2967727b614567b15b16b3db774c03d4a8acef355e5e26ad78aea`。
- 再次独立 `clean` Release：Hvigor 5.125 秒；signed HAP 391,991 bytes，SHA-256 `cf3e0739472e9b54f77f52d71c0f7b761fa2008f1cdef72061dd7251d9c28144`。
- `entry@ohosTest` Debug 测试 HAP：Hvigor 4.045 秒，仅保留既有 `start_window_background` 资源重复提示。
- Release `pack.info` 仍为 `phone` + `wearable`、compatible API 23、target API 26、`entry` 模块。
- 两次应用构建均未报告 `presentation` 新文件的 ArkTS 警告；输出的未处理异常/系统能力提示来自原有 services/shared/sync 文件。

## 6. WATCH 5 验收清单

安装任何新 HAP 前，仍须执行项目计划第 4 节的只读导出与双份 SHA-256 清单比对。

1. 手表首页默认可见，圆屏文案和主按钮没有裁切；下滑可进入开发者界面，上滑返回。
2. 在首页开始、熄屏、亮屏并停止录音，确认计时、封口、试听和自动同步不变。
3. 手机三个 Tab、开发者界面路由、录音列表选择/播放和同步进度显示正常。
4. 手机启动/停止手表录音，包括 `pending_user_action` 通知降级，状态与 Phase 2 一致。
5. 反复进入/退出页面并执行一次“重新连接”，确认没有重复 receiver、重复回调或退出后继续计时。

## 7. 真机验收结论

2026-08-30，用户按上述清单完成 WATCH 5 真机测试并确认通过。Phase 3 的表现层拆分未观察到圆屏布局、录音、播放、同步、远程控制或页面生命周期回归。
