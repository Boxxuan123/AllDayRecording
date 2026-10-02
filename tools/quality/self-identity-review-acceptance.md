# 本人审核箱验收（2026-10-02）

现有审核箱新增 self_identity_review 卡片，声音分类可见，展示时间、转写、时长、简化证据和完整试听。“是我/不是我”须听完，“不确定”保持身份；复用 SQLite 持久 voice review 队列和 operation ID，后台审核不得进入声纹 learning。

实际 HDC 验收：真实 production 候选同步、显示、完整播放及按钮解锁通过，未提交真实身份判定。隔离开发库两个 synthetic item 分别 confirm/reject，PC 投影为 Self/Non-self，手机项消失，再同步不返回；人审前后学习/Profile/NPZ/policy 指纹不变。实机发现并修复试听结束后的按钮状态刷新问题。

已安装最终正式 HAP，恢复正式 PC 接收服务，重建正式手机投影并恢复自动同步，保留原始录音和离线数据。生产库留有 4 个真实本人审核候选，未写测试判定。

验证：完整宿主 161/161；assembleHap 通过；check-self-identity-review.cjs 和 check-durable-review-queues.cjs 通过。SQLite 脚本用 Node 24 和 DevEco TypeScript。详细证据仅保存于未跟踪 outputs/。

PC 匿名完整报告在 AllDayRecording-ASR 的 docs/historical-self-backfill-20261002.md。Synthetic 结果仅用于交互诊断，不声称模型准确率。
