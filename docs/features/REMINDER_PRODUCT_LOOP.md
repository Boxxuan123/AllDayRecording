# 手机一次性本人待办

2026-10-01：实现与主机验证完成，真机系统通知尚未验证。

审核页复用现有 review 缓存，展示本人待办的动作、时间、原话和来源录音入口。确认、修改后确认、忽略通过现有 SQLite outbox 排队，即使断网或重启仍保留。正式提醒仅在电脑确认并返回 reminder projection 后调度。

提醒页支持改时间、取消、完成。操作保存在同一 outbox，通过现有 `/device/v3/sync` 回执确认；event revision 冲突显示在任务页。回执先到而 projection 后到时保留操作，避免旧缓存恢复旧时间。已消费候选复用 review tombstone，防止晚到的旧快照重新显示候选。

调度使用既有 HarmonyOS ReminderAgentCalendar 与应用通知权限。重复同步保留同一系统请求，清理同 group 重复项；取消、完成或失效会撤销请求。拒绝通知授权时，改期仍先撤销过时请求，并显示未调度原因。此路径不依赖页面常亮、前台轮询或常驻循环。

沿用 SDK 26 的 UTC `FIXED_TIME_ZONE` 请求；工程 compatible SDK 23 的兼容警告仍存在，目标手机能力待连接验证。调度异常会显示，当前没有低版本备用时间方案。

主机质量入口：`tools/quality/check-product-reminder-loop.cjs`，使用实际 ArkTS repository/use case/scheduler 和磁盘 SQLite，仅替换 HarmonyOS API。Hypium 用例位于 `phone/src/test/PhoneV3ReminderCommands.test.ets`。这些测试不证明手机后台或锁屏收到真实通知；真机验收应采用 replace install 保留应用数据。
