# AllDayRecording

AllDayRecording 是一个同时交付到手机与 HUAWEI WATCH 5 的 HarmonyOS 应用。手表负责连续 PCM 录音、WAV 安全封口、中断恢复和源文件生命周期；手机负责 Wear Engine 接收、持久化索引和试听。

当前工程按设备交付两个 HAP，并通过本地 `common` HAR 复用协议和纯逻辑：Watch 使用 `entry` HAP，Phone 使用 `phone` HAP。应用版本为 `1.0.1`（`versionCode = 1000001`），两个 HAP 保持同一 `bundleName`、Client ID、签名配置和 API 23/26 边界。Phone 只有 V3 本地优先工作台、V3 原生设备运行层和单一生产入口，不包含备用页面或只读入口。

## 主要目录

- `entry`：仅面向 `wearable` 的 Watch HAP；包含圆屏页面、录音、恢复、发送端和 Watch 专属诊断。
- `phone`：仅面向 `phone` 的 Phone HAP；包含手机页面、接收端、接收索引和试听入口。
- `common`：本地 HAR；包含模型、共享表现状态、WAV/原子文件、协议、Transport、同步/控制协调器和播放服务。
- `entry/src/main/ets/presentation/watch`：手表圆屏页面、Root 和 ViewModel。
- `phone/src/main/ets/presentation/phone`：Phone V3 的应用 Root 与电脑传输页面。
- `phone/src/main/ets/v3`：Phone V3 领域模型、用例、RDB 投影、Device client、UI reducer 与页面。
- `phone/src/main/ets/v3/runtime`：Phone V3 原生设备运行层；集中管理 Wear Engine 接收器、接收索引、Wi-Fi/播放生命周期和应用桥接。
- `entry/src/main/ets/recording`：AudioCapturer 生命周期、后台任务、WAV 文件槽和会话契约。
- `common/src/main/ets/sync`：协议、Wear Engine Transport、手机/手表协调器、自动队列和控制状态机。
- `common/src/main/ets/shared/io`：WAV 格式、原子文件和版本化 JSON 基础设施。
- `entry/src/main/ets/services`：Watch Sender、录音、恢复和远程启动降级 facade。
- `phone/src/main/ets/computer`：Phone 到电脑的二维码配对、mDNS 自动发现、HUKS 设备认证和断点上传边界。
- `entry/src/main/ets/diagnostics`：默认关闭、生产 UI 不可达的历史基线与探针。
- `entry/src/test`、`phone/src/test`：按设备边界拆分的宿主机 Hypium 业务测试。
- `entry/src/ohosTest`：设备测试 HAP 的业务契约入口。

当前依赖与数据流详见 [当前架构](doc/CURRENT_ARCHITECTURE.md)。历史阶段报告会明确标记为 `superseded` 或 `experiment`，不作为当前产品行为的唯一依据。
手机到电脑的首次配对、换 Wi-Fi 和上传流程详见 [手机到电脑安全传输](doc/PHONE_TO_COMPUTER_TRANSFER.md)。

工程级 `default` product 仅构建 Watch：使用 API 26 编译 SDK，但 `targetSdkVersion` 与
`compatibleSdkVersion` 均为 `6.1.0(23)`。`phone` product 仅构建 Phone，编译、目标和最低兼容
版本均为 API 26。不要把 Phone target 重新映射到 `default` product。

## 关键不变量

- Watch 最低兼容 HarmonyOS API 23；API 26 或设备能力必须有运行时保护或兼容降级。
- 一个录音会话只持续运行一个 AudioCapturer；生产 WAV 按 60 秒采样量切分，5 秒是 PCM 内存队列上限，不是当前分片时长。
- 完整文件按 `.part -> 回写 WAV 头 -> fsync -> close -> 原子 rename` 发布。
- 中断恢复保留非空 PCM 证据；普通 Wear Engine 同步始终保留手表源录音。只有加密 Wi-Fi 全量同步在手机逐文件核对 SHA-256、返回逐文件 ACK 且整批 ACK 完成后，才复核并删除该批手表源文件；任何失败或变化都继续保留。
- 手机完成文件持久化并更新索引后才发送 ACK。
- 手机首次扫码后固定配对 CA，以系统 Passkey 授权登记 HUKS 设备公钥；后续自动发现电脑并静默签名上传，录音断点上传完成后最后提交会话清单，且保留手机原文件。
- 自动与手动同步串行，网络传输不进入 AudioCapturer `readData` 回调。

## 本地质量门禁

所有命令都从项目根目录执行。DevEco Studio 的默认安装位置如下；如果位置不同，设置 `DEVECO_SDK_HOME`，Code Linter 也可通过 `DEVECO_STUDIO_HOME` 指向 DevEco Studio 的 `Contents` 目录。

Code Linter（读取项目根目录的 `code-linter.json5`，任何 defect 或不完整报告都会失败）：

```sh
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  --no-daemon codeLinter
```

宿主机 Hypium 测试门禁（依次运行 Watch 与 Phone，并校验当前报告、源码测试数和失败数）：

```sh
PATH=/Applications/DevEco-Studio.app/Contents/tools/node/bin:/usr/bin:/bin:/usr/sbin:/sbin \
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  --no-daemon hostTest
```

门禁默认给每个模块 60 秒，可通过 `HOST_TEST_TIMEOUT_MS` 设置其他正整数毫秒值。Hypium
即使报告含失败也可能让底层 `test` 任务返回 0，因此不得绕过 `hostTest` 只看 Hvigor 的
`BUILD SUCCESSFUL`。若 runner 在 `Darwin` 后超时，需在允许本地 socket 的环境重跑；没有由
当前命令新生成且经门禁解析的报告，不能计为测试通过。

设备测试 HAP 构建：

```sh
PATH=/Applications/DevEco-Studio.app/Contents/tools/node/bin:/usr/bin:/bin:/usr/sbin:/sbin \
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  assembleHap --mode module -p product=default -p module=entry@ohosTest \
  -p buildMode=debug --no-daemon
```

Debug 和 Release 必须分别先 `clean`，不能复用 `entry/build` 后把同一产物当作两种模式的证据：

```sh
PATH=/Applications/DevEco-Studio.app/Contents/tools/node/bin:/usr/bin:/bin:/usr/sbin:/sbin \
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  clean assembleApp -p product=default -p buildMode=debug --no-daemon
```

Phone 使用独立的 API 26 product 构建：

```sh
PATH=/Applications/DevEco-Studio.app/Contents/tools/node/bin:/usr/bin:/bin:/usr/sbin:/sbin \
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  clean assembleApp -p product=phone -p buildMode=debug --no-daemon
```

Windows 上如果签名阶段出现 `Invalid CEN header (invalid zip64 extra data field size)`，按打包工具
文档在当前构建进程设置 `JAVA_TOOL_OPTIONS=-Djdk.util.zip.disableZip64ExtraFieldValidation=true` 后重试。
该开关只影响 JDK 的 ZIP64 字段校验，不改变 HAP 的 API 版本。

把最后一项改为 `-p buildMode=release` 并再次执行，得到独立 Release 产物。构建成功不等于测试通过，也不等于真机录音、恢复或传输通过。

## 真机与数据保护

安装可能触发恢复、索引读取或自动同步的 HAP 前，必须先确认目标设备确为 WATCH 5，并对所有非空会话、清单和 `.part` 做只读导出；至少生成两份独立的数量、总字节数与 SHA-256 清单并比较一致。安装后再次导出并解释所有新增、修改或消失的文件。

Phase 6 已按用户决定不实现 Phone `entry -> phone` 沙箱自动迁移：新的 Phone 模块从新的 `phone` 沙箱开始，Watch 继续使用 `entry` 模块名。安装前双份只读导出仅是设备外的数据保护证据，不是应用入口或运行时数据源；不得把这一产品决定误写成框架能够无损迁移模块沙箱。

本地构建、lint 和宿主机测试不访问设备。Debug/Release HAP、签名材料、日志、设备备份、`local.properties` 和本机 `build-profile.json5` 都不得提交；仓库只保留无秘密的 `build-profile.example.json5`。

## 维护阈值

出现以下任一情况必须在评审或当前架构文档中说明：单文件超过 500 行；单类可变字段超过 25 个；一个改动同时跨越 UI、Transport、Storage 三层。阈值是复审信号，不鼓励为了行数制造无意义包装层。


## 手机到电脑的动态上传并发

上传从 3 个文件开始，范围 1–16；重试、失败或拥塞时减半，减半下限为 2（显式从 1 开始时保持 1）。同一秒内的重试合并为一次降档。达到至少 `max(4, 当前并发)` 个成功文件且观察时间不少于 1 秒后，吞吐和平均文件耗时稳定才增加 1。吞吐下降超过 15% 或平均耗时增加超过 50% 时降档；单文件耗时超过 `max(15 秒, 前窗平均耗时 × 2)` 也降档。文件耗时包括校验和请求准备，因此是保守的端到端信号，不是纯网络 RTT。

已经存在的文件和续传起点以前的字节不参与测速。换档/重试前启动的文件不参与新窗口，避免旧成功结果抵消降档。降档只暂停新文件派发，不取消、替换或重启在途任务；HTTP 重试仍占用原文件的槽位。同一文件串行分片、SHA-256、断点核对与最终会话清单提交顺序保持不变。队列失败后停止派发并等待全部在途任务结束，调用者才可重试。

## 许可

本仓库公开源码仅供查看，并非开源软件。除 GitHub 服务条款和适用法律明确要求的
权利外，不授予使用、复制、修改、再分发、商业化或创建衍生作品的许可。完整条款见
[LICENSE](LICENSE)。
