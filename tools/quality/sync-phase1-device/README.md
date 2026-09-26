# 第一阶段隔离手机 UI 验收复现

本目录 Index.ets 是**临时测试入口**，不在正式源码 import 链中。它使用生产 PhoneV3AnnotationPage、ViewModel、UseCases、PhoneProjectionRepository 和原生 AudioPlaybackService；独立 RDB、合成数据、本地桥及离线/慢传输端口替代真实业务资源。只能证明所列分层行为，不能作为完整生产备份端到端或帧性能报告。

实际结果见 ../../../doc/SYNC_PHASE1_ACCEPTANCE.md。原样例 tests/ui/main.py 和 PhoneMoreSmoke 不变；新增 runner 沿用同一 Hypium、设备配置、报告和控件操作，非 Appium。

## 前置检查与数据保护

使用 DevEco Testing 自带 Python/hdc，原 config/user_config.xml 选定手机。运行 hdc list targets，再用 -t <目标> shell param get const.product.devicetype 确认为 phone。bundle=AllDayRecording.huawei.com、module=phone、ability=EntryAbility。不要卸载、清库、操作 Watch 或断开承载 HDC 的网络。

先对正式应用原样运行样例（cwd tests/ui）：
```powershell
& 'C:\Program Files\DevEco Testing\python\python.exe' main.py
```

样例 teardown 停止应用；在应用保持停止时，用 hdc file recv 分别导出以下三目录至被忽略 outputs/sync-phase1-private/before-a/phone-files、entry-files、database，然后导出第二份 before-b：
- /data/app/el2/100/base/AllDayRecording.huawei.com/haps/phone/files
- /data/app/el2/100/base/AllDayRecording.huawei.com/haps/entry/files
- /data/app/el2/100/database/AllDayRecording.huawei.com/phone

示例命令模式：hdc -t <目标> file recv <上列远端目录> <对应本地绝对目录>。检查退出码；权限不足则停止设备变更，不以其他方法绕过。使用 tools/quality/verify-phase1-exports.py before-a before-b，要求差异零。保留私有备份，不上传/提交文件名清单或真实数据。已有同名隔离库时先确认归属，不盲目删除。

## 独立接收端与生成夹具

在电脑 ASR 仓库的单独终端启动：
```powershell
.venv\Scripts\python.exe tools/sync_phase1_test_receiver.py
```
只绑定127.0.0.1:19099，生成 outputs/sync-phase1-test-receiver/tls/receiver-ca-cert.pem；密钥保留电脑被忽略目录。另一个终端：
```powershell
& 'C:\Program Files\DevEco Testing\app\resources\bin\hdc.exe' -t <目标手机> rport tcp:19099 tcp:19099
```
这仅把手机 loopback 转发到独立合成接收端，不暴露生产接口。慢 PUT 固定 8MiB 零字节，服务每8192字节等待80ms；GET提供接收计数，不包含音频或文本。该服务只用于单次隔离验收，不是生产TLS接入实现。

在手机仓库运行已有合成生成器 tools/quality/voice-review-device/generate.py，得到 phone/src/main/resources/rawfile/voice-review-fixture.json（81条合成转写、两个人物、正弦音频）。复制上述**证书**为同 rawfile 下 sync-phase1-test-ca.pem，不复制私钥。

## 临时构建（必须在 finally 恢复源入口）

先保存当前生产 phone/src/main/ets/pages/Index.ets 到 outputs/sync-phase1-private/ 中新的备份文件，不覆盖已有备份。备份的是当前工作区文件，不使用 git checkout，以免丢失未提交修改。

在 PowerShell try 内把本目录 Index.ets 复制到生产页面入口，并执行；finally 恢复刚备份的原入口：
```powershell
$env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'
$env:JAVA_HOME = 'C:\Program Files\Huawei\DevEco Studio\jbr'
$env:JAVA_TOOL_OPTIONS = '-Djdk.util.zip.disableZip64ExtraFieldValidation=true'
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode project -p product=phone -p buildMode=debug assembleApp --no-daemon
```
需要有效本机签名配置。构建成功才可 install -r phone/build/phone/outputs/default/AllDayRecording-phone.hap 到上述明确选定手机。不要选 entry/Watch HAP。入口源文件此时应已经恢复，但设备临时安装包仍是隔离入口。

## 运行与判据

在 tests/ui 目录：
```powershell
$env:SYNC_PHASE1_TEST_CA = '<电脑仓库绝对路径>\outputs\sync-phase1-test-receiver\tls\receiver-ca-cert.pem'
& 'C:\Program Files\DevEco Testing\python\python.exe' run_phase1.py
```
run_phase1.py 用原 main 的 hdc 设置，调用真实 runner 的 run -l PhoneOfflineAnnotation;PhoneSyncInteraction。

- PhoneOfflineAnnotation：先断言“隔离验收 · 接收端离线”才允许点击重置按钮；生产版会在此失败。进入生产标注页，选择合成人物保存，8秒截止内等待反馈、RDB读回1；杀进程重启读回1/待同步；只在隔离RDB建立失败触发器后保存第二条，检查错误和操作数仍1。
- PhoneSyncInteraction：先检查真实接收字节>0且未结束，再进入生产标注页保存；读回和原生本地播放完成后再次检查接收字节递增、低于总量、ended=0。不是只断言 enabled=true；也没有执行直接滚动或帧率测量。
- 定位使用 BY.id / BY.text 及 wait_for_component 截止等待：annotation-save、annotation-error、annotation-setting-说话人、annotation-person-<合成人物ID>、phase1-*。传输状态轮询100ms不是应用性能计时。
- 每次 reset 只作用独立 sync-phase1-isolated-20260926.db。临时入口不会读取真实设备桥/配对配置、写真实审核决定或删除用户录音。

## 失败诊断

查看 tests/ui/reports/<本次时间>/summary_report.html 和 details/<用例>/。缺少隔离标题说明装错包，不能移除前置断言继续。缺控件看本次截图/树和稳定ID；连接失败检查测试服务、专用rport和独立CA，不关闭CA校验。保存失败看受控读回/隔离RDB，不去改真实库。进度不增加检查合成接收计数，不能把等待结束后的交互算成功。

报告、截图和私有日志保留忽略目录，仅在文档记录脱敏结果。Pillow/OpenCV缺失可能产生处理警告；须确认实际截图存在，不凭报告通过声称无卡顿。

## 必做清理与正式恢复

1. 停止隔离应用。只清理本轮确定创建的隔离数据库：
   /data/app/el2/100/database/AllDayRecording.huawei.com/phone/rdb/sync-phase1-isolated-20260926.db
   及实际列出的 -compare、-dwr、-shm、-wal 同名附属文件；先列出核实，再按精确路径删除，不能对目录递归删除。
2. 只清理 phone/cache 下本轮 sync-phase1-test-ca.pem、sync-phase1-tone.wav；保留其他文件。
3. 确认生产 Index.ets 恢复；删除本轮生成的 rawfile/voice-review-fixture.json 和 rawfile/sync-phase1-test-ca.pem（若原先存在则恢复其备份，不删除既有资源）。
4. 使用上面的正式 product=phone 命令增加 clean：clean assembleApp --no-daemon。核对HAP没有合成夹具/测试CA，再 install -r 恢复正式应用。不自动启动，先做数据完整性比较。
5. 再导出三目录到 after；运行 verify-phase1-exports.py before-a after，要求零差异。不要用备份覆盖差异，应先调查。
6. 停掉本轮测试接收进程；hdc -t <目标> fport ls 确认 tcp:19099 [Reverse] 后，用 fport rm tcp:19099 tcp:19099 只移除该映射。

当前交付状态已完成上述正式恢复与零差异检查。临时夹具不随正式包启用；私有导出/CA/密钥/HAP/报告不得公开提交。
