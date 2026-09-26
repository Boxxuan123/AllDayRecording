# 第二阶段 A 独立真机生产链路

`Index.ets` 是临时入口，不被生产页面 import。沿用 `tests/ui/main.py` 的 DevEco Testing/Hypium、设备配置和报告；用稳定 ID/文字和有截止时间的条件等待。真实结果见 `doc/SYNC_PHASE2A_ACCEPTANCE.md`，不能仅凭脚本存在判断通过。

## 范围

独立原生 RDB、合成 8 MiB PCM WAV、两秒本地 WAV、独立 HUKS alias、独立 CA/receiver/device。生产 `PhoneV3ViewModel`、协调器、标注页、UseCases、Repository、DeviceRemote，以及 `ComputerRecordingBackupService/Runtime/UploadService` 均实际执行。仅替换配置存放位置、录音清单装配和测试入口；**不覆盖生产备份文件扫描/筛选的真机验收**。电脑工具只延迟真实 UploadStore 的每次 append，保留正式签名、challenge、分片、SHA-256、完成和 manifest；没有假 backup 状态。

电脑凭手机原生 HUKS 公钥在本地引导隔离设备凭据；**不验收 Passkey 注册仪式**。正式网络请求仍须通过生产认证。测试材料只能放在忽略的 outputs/，不得提交设备配置、证书私钥、公钥导出、HAP 或原始报告。

## 准备与复跑

以下操作只针对已确认的 phone 目标；本轮用 `3DK0225528040628`。禁止卸载或清应用数据。先按第一阶段 README 导出 phone-files、entry-files、database 到本轮全新私有 before 目录。停止正常应用后再安装隔离包。

1. 在手机仓库运行 `tools/quality/build-sync-device.ps1 phase2a`。脚本保存当前生产 Index 字节，在 finally 恢复；失败不得安装。使用 DevEco Testing 自带 hdc：

   ```powershell
   & 'C:\Program Files\DevEco Testing\app\resources\bin\hdc.exe' -t 3DK0225528040628 install -r phone/build/phone/outputs/default/AllDayRecording-phone.hap
   & 'C:\Program Files\DevEco Testing\app\resources\bin\hdc.exe' -t 3DK0225528040628 shell aa start -a EntryAbility -b AllDayRecording.huawei.com
   ```

2. 等待“隔离 HUKS 公钥已准备”。将 `/data/app/el2/100/base/AllDayRecording.huawei.com/haps/phone/cache/sync-phase2a-public.txt` 用 `hdc -t <phone> file recv` 导出至 `outputs/sync-phase2a-private/public.txt`。权限不足时停止设备修改；不绕过沙箱。
3. 电脑仓库另一终端运行（每轮选择未使用的输出目录）：

   ```powershell
   .venv\Scripts\python.exe tools/sync_phase2a_device_receiver.py --public-key '<手机仓库>\outputs\sync-phase2a-private\public.txt' --output outputs/sync-phase2a-device-run
   ```

4. `hdc -t <phone> rport tcp:19100 tcp:19100`。复制工具生成的 `phone-config.json` 和 `tls/receiver-ca-cert.pem` 到手机 `phone/src/main/resources/rawfile/sync-phase2a-config.json`、`sync-phase2a-ca.pem`；只复制 CA 公共证书，绝不复制私钥。重新执行 phase2a 构建并覆盖安装。用 rawfile 是因为本机 HDC 不允许往应用 cache 直接写入，未绕过权限。
5. 在手机 `tests/ui` 运行：

   ```powershell
   $env:SYNC_PHASE2A_EVIDENCE='<电脑仓库>\outputs\sync-phase2a-device-run\evidence.json'
   & 'C:\Program Files\DevEco Testing\python\python.exe' run_phase2a.py
   ```

该用例清理/重建**明确命名的独立测试库** `sync-phase2a-isolated-20260926.db`，构造旧 schema 10 的 outbox/index 状态，再通过生产迁移打开为 11 并断言回填。它不回退真实业务库。然后在真实上传中保存一条已登记资源标注，验证新 operation_id 的 applied 回执、上传仍未完成、内存与原生持久化待同步均为零；实际返回、播放完整两秒 WAV、在 Scroll 控件内滑动，并确认上传字节仍增加。最后等待正式 manifest 完成并删除**测试 alias**。8/10/20/180 秒只是驱动截止，不是手机性能统计。

`outputs/sync-phase2a-production-evidence.json` 只含本轮合成编号、驱动观察时间及服务端上传进度；`outputs/sync-phase2a-private/state.json` 可用于诊断内存/持久化计数。原始报告在 `tests/ui/reports/`，忽略且不提交。失败时必须查看本次报告，不能沿用旧 PASS。

## 必做恢复

1. 成功用例最后点击“清理隔离测试密钥”；若提前失败，重新打开隔离入口仅点击该按钮，等待“隔离测试密钥已清理”。它只删除 `alldayrecording.phase2a.synthetic.20260926`，不删除正式 alias。
2. 停止应用。先列出核实，再精确删除独立 RDB 路径及实际存在的同名 `-compare/-dwr/-shm/-wal`；不得删除 rdb 目录。只删除本轮 cache 的 `sync-phase2a-ca.pem`、`sync-phase2a-public.txt`、`sync-phase2a-recording.wav`、`sync-phase2a-tone.wav`、`sync-phase2a-state.json`。保留所有真实文件。
3. 删除本轮生成的两个 phase2a rawfile；若也运行第一阶段，清理其两个生成 rawfile 和明确命名的测试库/cache。既有文件须恢复其备份，不能删除他人材料。
4. `tools/quality/build-sync-device.ps1 production` 执行正式 `product=phone clean assembleApp`；脚本会拒绝残留的上述 rawfile。检查 HAP 不含测试文件后 `install -r`，不自动启动业务同步。
5. 再导出三目录到 after，用 `tools/quality/verify-phase1-exports.py before after` 比较完整 SHA-256 清单。发现差异先调查，不能用备份覆盖。
6. 停止本轮独立 receiver，`hdc -t <phone> fport ls` 核实后仅 `fport rm tcp:19100 tcp:19100`；不影响其他映射或 HDC 网络。保留私有备份和报告。
