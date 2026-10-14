# 独立审核入口

请先阅读 `doc/RECALL_QUERY_LOOP_20261014.md` 和审核包中的 `backend.patch`、`phone.patch`、`fictional-results.json`，按人物、日期、会话归属、模型失败状态、手机主回答内容审查。不要依据测试数量推断真实手机或真实模型已经通过；真实链路本轮 NOT_RUN。

本轮只修复历史回忆自然问题与回答闭环；未修改提醒、日历、声纹、人物记忆架构。提交前验收日志及完整 commit SHA 会由交付包记录。
