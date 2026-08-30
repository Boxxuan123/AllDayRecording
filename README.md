# AllDayRecording

AllDayRecording 是一个同时交付到手机与 HUAWEI WATCH 5 的 HarmonyOS 应用。手表负责连续 PCM 录音、WAV 安全封口、中断恢复和源文件保留；手机负责 Wear Engine 接收、持久化索引和试听。

当前工程按设备交付两个 HAP，并通过本地 `common` HAR 复用协议和纯逻辑：Watch 使用 `entry` HAP，Phone 使用 `phone` HAP。应用版本为 `1.0.1`（`versionCode = 1000001`），两个 HAP 保持同一 `bundleName`、Client ID、签名配置和 API 23/26 边界。Phase 6 的本地门禁、双端覆盖安装和用户真机验收已完成。

## 主要目录

- `entry`：仅面向 `wearable` 的 Watch HAP；包含圆屏页面、录音、恢复、发送端和 Watch 专属诊断。
- `phone`：仅面向 `phone` 的 Phone HAP；包含手机页面、接收端、接收索引和试听入口。
- `common`：本地 HAR；包含模型、共享表现状态、WAV/原子文件、协议、Transport、同步/控制协调器和播放服务。
- `entry/src/main/ets/presentation/watch`：手表圆屏页面、Root 和 ViewModel。
- `phone/src/main/ets/presentation/phone`：手机页面、Root 和 ViewModel。
- `entry/src/main/ets/recording`：AudioCapturer 生命周期、后台任务、WAV 文件槽和会话契约。
- `common/src/main/ets/sync`：协议、Wear Engine Transport、手机/手表协调器、自动队列和控制状态机。
- `common/src/main/ets/shared/io`：WAV 格式、原子文件和版本化 JSON 基础设施。
- `entry/src/main/ets/services`：Watch Sender、录音、恢复和远程启动降级 facade。
- `phone/src/main/ets/services`：Phone Receiver 与接收索引。
- `entry/src/main/ets/diagnostics`：默认关闭、生产 UI 不可达的历史基线与探针。
- `entry/src/test`、`phone/src/test`：按设备边界拆分的宿主机 Hypium 业务测试。
- `entry/src/ohosTest`：设备测试 HAP 的业务契约入口。

当前依赖与数据流详见 [当前架构](doc/CURRENT_ARCHITECTURE.md)。历史阶段报告会明确标记为 `superseded` 或 `experiment`，不作为当前产品行为的唯一依据。

## 关键不变量

- Watch 最低兼容 HarmonyOS API 23；API 26 或设备能力必须有运行时保护或兼容降级。
- 一个录音会话只持续运行一个 AudioCapturer；生产 WAV 按 60 秒采样量切分，5 秒是 PCM 内存队列上限，不是当前分片时长。
- 完整文件按 `.part -> 回写 WAV 头 -> fsync -> close -> 原子 rename` 发布。
- 中断恢复保留非空 PCM 证据；同步永不自动删除手表源录音。
- 手机完成文件持久化并更新索引后才发送 ACK。
- 自动与手动同步串行，网络传输不进入 AudioCapturer `readData` 回调。

## 本地质量门禁

所有命令都从项目根目录执行。DevEco Studio 的默认安装位置如下；如果位置不同，设置 `DEVECO_SDK_HOME`，Code Linter 也可通过 `DEVECO_STUDIO_HOME` 指向 DevEco Studio 的 `Contents` 目录。

Code Linter（读取项目根目录的 `code-linter.json5`，任何 defect 或不完整报告都会失败）：

```sh
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  --no-daemon codeLinter
```

宿主机 Hypium 测试：

```sh
PATH=/Applications/DevEco-Studio.app/Contents/tools/node/bin:/usr/bin:/bin:/usr/sbin:/sbin \
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  --mode module -p product=default -p module=entry@default \
  -p buildMode=debug test --no-daemon
```

Phone 接收索引测试需另行运行：

```sh
PATH=/Applications/DevEco-Studio.app/Contents/tools/node/bin:/usr/bin:/bin:/usr/sbin:/sbin \
DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk \
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  --mode module -p product=default -p module=phone@default \
  -p buildMode=debug test --no-daemon
```

若 runner 在 `Darwin` 后无结果文件，该次不能计为测试通过；必须以实际 Hypium 报告为准。

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

把最后一项改为 `-p buildMode=release` 并再次执行，得到独立 Release 产物。构建成功不等于测试通过，也不等于真机录音、恢复或传输通过。

## 真机与数据保护

安装可能触发恢复、索引读取或自动同步的 HAP 前，必须先确认目标设备确为 WATCH 5，并对所有非空会话、清单和 `.part` 做只读导出；至少生成两份独立的数量、总字节数与 SHA-256 清单并比较一致。安装后再次导出并解释所有新增、修改或消失的文件。

Phase 6 已按用户决定不实现 Phone `entry -> phone` 沙箱自动迁移：新的 Phone 模块从新的 `phone` 沙箱开始，旧 Phone 数据以安装前双份只读导出作为回退；Watch 继续使用 `entry` 模块名。不得把这一产品决定误写成框架能够无损迁移模块沙箱。

本地构建、lint 和宿主机测试不访问设备。Debug/Release HAP、签名材料、日志、设备备份、`local.properties` 和本机 `build-profile.json5` 都不得提交；仓库只保留无秘密的 `build-profile.example.json5`。

## 维护阈值

出现以下任一情况必须在评审或当前架构文档中说明：单文件超过 500 行；单类可变字段超过 25 个；一个改动同时跨越 UI、Transport、Storage 三层。阈值是复审信号，不鼓励为了行数制造无意义包装层。
