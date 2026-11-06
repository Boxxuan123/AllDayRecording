# 工具索引

所有命令从项目根目录运行。脚本保留既有路径和同目录依赖；新增脚本按所属模块归类，运行产物写入 outputs。 HarmonyOS 质量门禁与验收脚本位于 quality/。

正式业务实现位于源码模块；这些工具不作为新的应用入口。历史审核报告已移入 docs/history。

## 设备传输与同步

- [quality/build-sync-device.ps1](<quality/build-sync-device.ps1>)
- [quality/check-daily-sync-stale.cjs](<quality/check-daily-sync-stale.cjs>)
- [quality/check-manifest-recovery.cjs](<quality/check-manifest-recovery.cjs>)
- [quality/check-phase2-original-sync.cjs](<quality/check-phase2-original-sync.cjs>)
- [quality/check-phase2-sync.cjs](<quality/check-phase2-sync.cjs>)
- [quality/check-phone-sync-service.cjs](<quality/check-phone-sync-service.cjs>)
- [quality/check-receiver-connection.cjs](<quality/check-receiver-connection.cjs>)
- [quality/check-sync-byte-limit.cjs](<quality/check-sync-byte-limit.cjs>)
- [quality/check-sync-connection.cjs](<quality/check-sync-connection.cjs>)
- [quality/check-sync-coordinator.cjs](<quality/check-sync-coordinator.cjs>)
- [quality/check-sync-discovery.cjs](<quality/check-sync-discovery.cjs>)
- [quality/check-sync-phase1.cjs](<quality/check-sync-phase1.cjs>)
- [quality/check-sync-phase2a-lifecycle.cjs](<quality/check-sync-phase2a-lifecycle.cjs>)
- [quality/check-sync-phase2a.cjs](<quality/check-sync-phase2a.cjs>)
- [quality/check-sync-query-cost.cjs](<quality/check-sync-query-cost.cjs>)
- [quality/check-sync-transport.cjs](<quality/check-sync-transport.cjs>)
- [quality/check-upload-offset.cjs](<quality/check-upload-offset.cjs>)

## 声音、身份与历史诊断

- [quality/check-annotation-experience.cjs](<quality/check-annotation-experience.cjs>)
- [quality/check-annotation-sync-latency.cjs](<quality/check-annotation-sync-latency.cjs>)
- [quality/check-blind-review-v2.cjs](<quality/check-blind-review-v2.cjs>)
- [quality/check-blind-review.cjs](<quality/check-blind-review.cjs>)
- [quality/test-purity-review-device.py](<quality/test-purity-review-device.py>)
- [quality/test-purity-review-offline.py](<quality/test-purity-review-offline.py>)
- [quality/wait-purity-audio-pack.py](<quality/wait-purity-audio-pack.py>)

## 构建、工程门禁与业务检查

- [quality/check-calendar-reminders.cjs](<quality/check-calendar-reminders.cjs>)
- [quality/check-daily-events.cjs](<quality/check-daily-events.cjs>)
- [quality/check-daily-evidence-playback.cjs](<quality/check-daily-evidence-playback.cjs>)
- [quality/check-durable-review-queues.cjs](<quality/check-durable-review-queues.cjs>)
- [quality/check-phase1-reminder.mjs](<quality/check-phase1-reminder.mjs>)
- [quality/check-phase2-closeout.cjs](<quality/check-phase2-closeout.cjs>)
- [quality/check-phase2-e2e.cjs](<quality/check-phase2-e2e.cjs>)
- [quality/check-phone-responsibility-boundaries.cjs](<quality/check-phone-responsibility-boundaries.cjs>)
- [quality/check-product-reminder-loop.cjs](<quality/check-product-reminder-loop.cjs>)
- [quality/check-review-audio.cjs](<quality/check-review-audio.cjs>)
- [quality/check-review-cache.cjs](<quality/check-review-cache.cjs>)
- [quality/check-review-prefetch-recovery.cjs](<quality/check-review-prefetch-recovery.cjs>)
- [quality/check-self-identity-review.cjs](<quality/check-self-identity-review.cjs>)
- [quality/check-session-pagination-scale.cjs](<quality/check-session-pagination-scale.cjs>)
- [quality/check-voice-review-flow.cjs](<quality/check-voice-review-flow.cjs>)
- [quality/generate-build-identity.mjs](<quality/generate-build-identity.mjs>)
- [quality/phone-paged-fixture.cjs](<quality/phone-paged-fixture.cjs>)
- [quality/phone-sqlite-harness.cjs](<quality/phone-sqlite-harness.cjs>)
- [quality/run-code-linter.mjs](<quality/run-code-linter.mjs>)
- [quality/run-host-tests.mjs](<quality/run-host-tests.mjs>)
- [quality/verify-phase1-exports.py](<quality/verify-phase1-exports.py>)
- [quality/voice-review-device/generate.py](<quality/voice-review-device/generate.py>)

## 聊天事项与验收

- [quality/check-chat-followup-loop.cjs](<quality/check-chat-followup-loop.cjs>)

## 服务运行与重启

- [quality/check-runtime-diagnostics.cjs](<quality/check-runtime-diagnostics.cjs>)
