# 版本与模块边界验收（2026-10-09）

实际Phone与Watch entry@watch同属本仓库，common是随产品打包的HAR。AppScope从1.0.1/1000001/build2递增到1.0.2/1000002/build3；保持绑定发布，无模块SemVer。PC/后台共用AllDayRecording-ASR 0.6.1。

Hvigor自动注入release、完整Git hash、UTC构建时间、dirty。生成的GeneratedBuildIdentity.ets忽略、不提交；最终提交后构建两个产品并检查HAP字节码包含最终hash。签名和本地build-profile按原环境使用，未改签名配置、未上传凭据。

查看：Phone更多→版本/诊断；Watch开发者页→版本/复制。
common RuntimeDiagnostics入口：localBuildInfo、recordPeerBuild、peerBuildReport、diagnosticText/copyDiagnostics。
他端信息来自实际Wear Engine消息或已认证PC status；无上报unknown，120秒未观察offline_or_stale。可选字段支持旧端；Phone诊断上报仅在声明能力时执行，失败不改变同步结果。
协议保持Watch1、PC transfer2、V3 contract3.8.0/projection5；Phone本地schema19。本轮没有迁移，发布版本不参与兼容性拦截。

| 职责 | 状态与入口 |
|---|---|
| 录音与原始资料 | Watch音频生命周期、PhoneRecordingService：原音、恢复、manifest |
| 同步传输 | WearEngineTransport/Receiver/PhoneV3UseCases：传输、receipt、cursor |
| 转写与时间线 | 后台durable processing：job/stage/utterance；Phone接收投影 |
| 人物识别与审核 | 后台people拥有画像；Phone通过既有审核命令提交事实 |
| 事件与任务 | 后台event/reminder；CalendarReminderScheduler拥有日历投影 |
| 总结与人物记忆 | 后台Daily/PersonMemory拥有证据修订；Phone只读投影 |

有限验收（非实机）：
- check-runtime-diagnostics.cjs（30s）：真实ArkTS协议类旧/新端、不同发布号、未知/过期、复制载荷通过；原生API替身。
- check-calendar-reminders.cjs、check-sync-transport.cjs、check-phase2-original-sync.cjs（每条45s）：临时SQLite、Calendar假端口和固定同步样本通过。没有扩大通知验收。
- Hvigor assembleApp product=phone/default --no-daemon（每个240s）：两产品编译、打包、签名通过。
- Code Linter（120s）：8处既有await-thenable报告，原提交相同语句且SDK disabled；未改规则或扩大无关扫尾。
- HDC list targets（10s）一次[Empty]；未验证安装、实际Wear Engine链路或系统剪贴板UI；仍有既有SDK警告，新增剪贴板调用有SDK异常检查警告，UI捕获失败。

没有模型训练、全量录音或全历史回放。最终构建和远端核对见outputs/delivery/acceptance.json；完整hash和提交链接在交付回复。原工作区两个用户投影文件及其验证脚本保留，不混入提交。
后台详细来源、局部重算与职责见ASR docs/MODULE_BOUNDARIES_ACCEPTANCE.md。
