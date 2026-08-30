# AllDayRecording

AllDayRecording 是一个同时交付到手机与 HUAWEI WATCH 5 的 HarmonyOS 应用。手表负责连续 PCM 录音、WAV 安全封口、中断恢复和源文件保留；手机负责 Wear Engine 接收、持久化索引和试听。

当前工程只有一个 `entry` HAP，同时声明 `phone` 与 `wearable`。源码已经按表现层、录音、同步、存储和诊断边界拆分；是否物理拆成两个 HAP 留到维护计划 Phase 6 单独验证。

## 主要目录

- `entry/src/main/ets/presentation/phone`：手机页面、Root 和 ViewModel。
- `entry/src/main/ets/presentation/watch`：手表圆屏页面、Root 和 ViewModel。
- `entry/src/main/ets/recording`：AudioCapturer 生命周期、后台任务、WAV 文件槽和会话契约。
- `entry/src/main/ets/sync`：协议、Wear Engine Transport、手机/手表协调器、自动队列和控制状态机。
- `entry/src/main/ets/shared/io`：WAV 格式、原子文件和版本化 JSON 基础设施。
- `entry/src/main/ets/services`：现有页面调用的兼容 facade、播放、恢复和接收索引。
- `entry/src/main/ets/diagnostics`：默认关闭、生产 UI 不可达的历史基线与探针。
- `entry/src/test`：可在宿主机运行的 Hypium 业务测试。
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
  clean assembleHap --mode module -p product=default -p module=entry@default \
  -p buildMode=debug --no-daemon
```

把最后一项改为 `-p buildMode=release` 并再次执行，得到独立 Release 产物。构建成功不等于测试通过，也不等于真机录音、恢复或传输通过。

## 真机与数据保护

安装可能触发恢复、索引读取或自动同步的 HAP 前，必须先确认目标设备确为 WATCH 5，并对所有非空会话、清单和 `.part` 做只读导出；至少生成两份独立的数量、总字节数与 SHA-256 清单并比较一致。安装后再次导出并解释所有新增、修改或消失的文件。

本地构建、lint 和宿主机测试不访问设备。Debug/Release HAP、签名材料、日志、设备备份、`local.properties` 和本机 `build-profile.json5` 都不得提交；仓库只保留无秘密的 `build-profile.example.json5`。

## 维护阈值

出现以下任一情况必须在评审或当前架构文档中说明：单文件超过 500 行；单类可变字段超过 25 个；一个改动同时跨越 UI、Transport、Storage 三层。阈值是复审信号，不鼓励为了行数制造无意义包装层。
