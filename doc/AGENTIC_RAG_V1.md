# Phone Agentic RAG V1 验收

版本 1.0.20 / 1000020，基线 ca767bb6411bfd17ee8aeb8cc1b83f12001f2c21。

沿用原手机回忆入口、已配对设备认证、UseCases、证据弹层、候选选择、取消、分页和来源失效处理。新增来源事实/来源陈述/有依据的推测标签，事件时间独立显示，时间推断明确标记；技术详情不再展示内部 JSON 或人物 ID。无全局 UI 重构、投影迁移、提醒/日历/录音改动。

跨仓虚构验收 `tools/quality/check-agentic-recall.cjs` 使用 ASR 隔离夹具与脚本模型，经实际 UseCases 和生产格式化函数检查：两轮调查、来源陈述及冲突、相对事件日期、可打开次日证据、来源失效清空旧结论。原 `check-recall-query-loop.cjs`、`check-history-recall.cjs`、`check-phone-product-v2.cjs` 通过。真实模型未调用，不能据此声称其推理能力已通过。

Code Linter 0 defects；严格 phone product 的 Debug/Release 分别 clean 构建成功，未签名。官方 Watch 68 / Phone 102，合计 Hypium 170/170。SDK 固定 `.test/default` 与 product `.test/phone` 路径不一致导致过首次超时；保留失败日志，只复制本次生成且哈希一致的 ABC 后运行原门禁。没有修改 SDK、门禁或测试期望来跳过问题。

Phone 未部署：HDC 没有连接设备，隔离配置未配置签名。没有卸载、清数据或修改配对。Windows 运行服务未重启；任务状态接口 403，无法确认安全切换条件。

完整实现审计、来源能力缺口、精确测试计数和复现说明见 ASR `docs/AGENTIC_RAG_V1.md` 及交付的脱敏审核包。源码从隔离工作区提交并推送，主工作区未提交修改保留；最终完整 SHA 与远端一致性记录在包内 manifest。
