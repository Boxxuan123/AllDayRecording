# 真机同步性能验收

`sync-acceptance-device/Index.ets` 是临时装配入口，仅由 `build-sync-device.ps1 -Mode acceptance` 使用；脚本 finally 恢复正式入口。生产构建拒绝残留 `sync-acceptance-config.json` 和 `sync-acceptance-ca.pem`。

使用独立 HUKS alias `alldayrecording.acceptance.20260927`、独立原生 RDB `sync-acceptance-<时间>.db`、合成 WAV 和隔离接收器。生产 DeviceRemote、连接认证、UseCases、Repository、ViewModel、协调器、标注页面、录音上传实际运行，不修改正式配对、正式投影库或录音。

先备份 phone el2/base 与 database，生成逐文件 SHA-256，再覆盖安装。第一次启动导出 cache/sync-acceptance-public.txt，电脑端通过 tools/sync_acceptance_receiver.py 的本地参数登记这个公钥；这不验收初次 Passkey 注册。生成配置与 CA 公共证书放入两个专用 rawfile，再构建运行。

每轮：等待首次快照完整下载，20 次单条和 5 次 32 条标注；再同时运行样本任务与真实分片上传，重复相同采样。计时从调用正式 saveAnnotation 前开始，到已确认状态参与 didLayout 为止；不是点击屏幕的外部计时，也不是显示面板光学测量。每条选择保留独立 operation ID，32 条采样按全部确认结束。

结果存于 cache/sync-acceptance-results.json，分段日志包含 T0/T2/T4/T5/T6、原生 HTTP 耗时和复用标志。须连续保存本轮 PID 的 Hilog。电脑工具记录请求 ID、写事务等待、业务处理和模型调用，分析工具 tools/analyze_sync_acceptance.py 关联两端证据；不直接相减电脑与手机时钟。

收尾须从 rawfile 移走本轮两个生成文件、恢复正式签名包、核对正式库的表内容并启动正式应用。保留失败样本；不得用 USB 对照结果替代局域网验收。测试数据库和合成文件仅保留在明确命名的隔离位置，不能清空应用数据或删除真实录音。

补跑基线可在配置指定 baselineOnly=true、database 为明确的隔离库名，电脑工具使用 --resume 复用隔离服务身份及数据。仅允许 sync-acceptance- 前缀的测试库，不得指定正式库。采样期间不要并行构建；最后恢复已核验的正式 HAP。
