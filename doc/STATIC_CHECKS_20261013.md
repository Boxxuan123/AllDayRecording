# Phone 全库静态检查与回归收尾 — 2026-10-13

按用户最新要求修复既有缺陷、检查所有、提交不推送。第一轮 UI 与质量修复一起保存在隔离分支 `codex/daily-ui-round1`。原 checkout 的 diff 字节与状态清单一致，原 HEAD 未移动；签名材料与本机 build-profile 保持 ignored。

## 静态修复

Code Linter 原有 9 条全部修复，保留配置规则与作用域。8 条 await-thenable 涉及已声明的 Promise 或返回 Promise 的回调：先在 guard 后绑定明确类型的非空 Promise，再等待同一对象，保持录音封段、接收器启动/清理、连接去重与录音控制回执的等待顺序。

剩余一条为 PhoneHistoryRecall 的 JSON 深复制。采用 ArkTS 显式字段复制，并单独复制将被修改的 coverage、evidence 和失效 ID 数组；现有离线回归验证当前证据与覆盖提示不会被 stale/unavailable 响应修改，旧分页仍不能恢复失效结论。没有新增人物、任务或同步状态。

诊断 runner 把文件记录的 filePath 关联到具体 defect，失败时不再只输出 unknown file。未忽略任何已有规则。

全量回归发现的旧测试夹具也已修复：schema 版本使用生产常量、HTTP 夹具加载实际 common 诊断模块；closeout 夹具明确打开原文页、把数据库恢复到真实 v9 结构后迁移，并检查回滚后的原始队列载荷与缺失来源保护。生产迁移、数据层与 UseCases 的业务规则没有修改。

## 最终门禁

| 检查 | 结果 |
|---|---|
| Code Linter | PASS，0 defects，SDK 26 / API 26 |
| phone product / phone module 签名 debug assembleHap | PASS |
| default product / entry module 签名 debug assembleHap | PASS |
| host tests | PASS，entry 68/68 + phone 102/102 = 170/170，无忽略项、新报告 |
| 全部 CJS 专项 | PASS，41/41，完整清单如下 |
| phase1-reminder.mjs | 由 ASR 全量 Python 用例提供隔离输入执行 |
| git diff --check 与原始工作区保护 | PASS |
| 静态修复后新包重新安装、完整实机引用/播放/分页、真实任务/日历操作 | NOT_RUN，本次 hdc 无连接设备；之前 1.0.14 基础 UI 安装与截图仍有效 |
| origin/master 推送 | NOT_RUN，用户要求不推送 |

编译仍有既有 SDK 能力/弃用提示。所有专项通过临时 SQLite、合成消息、假日历与网络 I/O 执行，没有调用真实模型、真实 QQ/微信全历史扫描或修改生产数据。设备审核决定、任务完成/改期/取消和系统日历通知不由这些隔离结果替代。

## 复现

使用 Node 24、DevEco SDK/JBR 和本机 ignored 签名配置；设置 DEVECO_STUDIO_HOME、DEVECO_SDK_HOME、JAVA_HOME。Python 指向 ASR 开发环境；所有 ASR 根目录变量指向本轮隔离 checkout。

```powershell
node tools/quality/run-code-linter.mjs
hvigorw.bat assembleHap --mode module -p product=phone -p module=phone@default -p buildMode=debug --no-daemon
hvigorw.bat assembleHap --mode module -p product=default -p module=entry@default -p buildMode=debug --no-daemon
node tools/quality/run-host-tests.mjs
```

设置 PHONE_TEST_TYPESCRIPT 为前端的 node_modules/typescript、CHAT_PHONE_ASR_ROOT / AUDIT_ASR_ROOT 为 ASR checkout，CHAT_PHONE_PYTHON / PHONE_TEST_PYTHON 为开发 Python，并把 ASR 的 src 和根目录加入 PYTHONPATH。随后生成 closeout 隔离输入并运行全部 CJS：

```powershell
# 在 ASR checkout 执行
python -m tests.phase2_closeout_export "$env:TEMP/allday-ui-phase2-closeout.json"
# 切换至 Phone checkout
Get-ChildItem tools/quality -Filter 'check-*.cjs' | Sort-Object Name | ForEach-Object {
  $checkArgs = @($_.FullName)
  if ($_.Name -eq 'check-phase2-closeout.cjs') {
    $checkArgs += "$env:TEMP/allday-ui-phase2-closeout.json"
  }
  node @checkArgs
  if ($LASTEXITCODE -ne 0) { throw "Failed: $($_.Name)" }
}
```

## 本次全部专项

| 脚本 | 结果 |
|---|---|
| check-annotation-experience.cjs | PASS |
| check-annotation-sync-latency.cjs | PASS |
| check-blind-review-v2.cjs | PASS |
| check-blind-review.cjs | PASS |
| check-calendar-reminders.cjs | PASS |
| check-chat-followup-loop.cjs | PASS |
| check-cross-day-memory.cjs | PASS |
| check-daily-events.cjs | PASS |
| check-daily-evidence-playback.cjs | PASS |
| check-durable-review-queues.cjs | PASS |
| check-explicit-time.cjs | PASS |
| check-history-recall.cjs | PASS |
| check-manifest-recovery.cjs | PASS |
| check-memory-content-security.cjs | PASS |
| check-memory-continuity.cjs | PASS |
| check-phase2-closeout.cjs | PASS |
| check-phase2-e2e.cjs | PASS |
| check-phase2-original-sync.cjs | PASS |
| check-phase2-sync.cjs | PASS |
| check-phone-responsibility-boundaries.cjs | PASS |
| check-phone-sync-service.cjs | PASS |
| check-product-reminder-loop.cjs | PASS |
| check-receiver-connection.cjs | PASS |
| check-review-audio.cjs | PASS |
| check-review-cache.cjs | PASS |
| check-review-prefetch-recovery.cjs | PASS |
| check-runtime-diagnostics.cjs | PASS |
| check-self-identity-review.cjs | PASS |
| check-session-pagination-scale.cjs | PASS |
| check-sync-byte-limit.cjs | PASS |
| check-sync-connection.cjs | PASS |
| check-sync-coordinator.cjs | PASS |
| check-sync-discovery.cjs | PASS |
| check-sync-phase1.cjs | PASS |
| check-sync-phase2a-lifecycle.cjs | PASS |
| check-sync-phase2a.cjs | PASS |
| check-sync-query-cost.cjs | PASS |
| check-sync-transport.cjs | PASS |
| check-unified-review.cjs | PASS |
| check-upload-offset.cjs | PASS |
| check-voice-review-flow.cjs | PASS |
