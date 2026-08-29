# HarmonyOS 真机命令调试手册：HDC 连接、日志、截图、界面操作与文件验收

> 适用工程：`/Volumes/hardDrive/DevEcoStudioProjects/AllDayRecording`
>
> 目标：让不熟悉 DevEco Studio 或 Computer Use 的 AI，能够优先使用命令完成手机与手表的连接、构建、安装、日志读取、界面检查、截图、文件备份和真机验收。
>
> 最高安全规则：同步稳定前不得删除、覆盖或移动手表录音。覆盖安装前先做只读备份并计算校验值。除非用户明确授权，不得卸载应用、清除应用数据或删除设备文件。

## 1. 能用命令完成什么

以下工作通常不需要操作 DevEco Studio：

- 连接无线调试手表或 USB 手机；
- 查看设备在线状态、型号、设备类型和 API 版本；
- 构建并覆盖安装已签名 HAP；
- 启动、停止应用进程；
- 读取实时 Hilog 或历史日志；
- 生成设备截图并拉回 Mac；
- 导出当前 UI 结构，获取文本、按钮坐标和可点击状态；
- 点击、长按、滑动、返回、回到桌面和输入文字；
- 只读导出调试应用私有目录中的录音、索引和队列清单；
- 比较文件数量、大小和 SHA-256；
- 形成可复核的真机验收报告。

只有以下场景通常需要 DevEco Studio 或设备端人工操作：

- 首次打开开发者模式、无线调试或确认调试授权；
- 无线调试端口改变，需要在手表上查看新的 IP 和端口；
- 处理系统级授权弹窗；
- 配置自动签名或查看 IDE 专属构建配置；
- 命令无法表达的 IDE 操作。

## 2. 本工程的已知参数

以下值是本工程当前配置，不应套用到其他应用：

```text
HDC 路径：/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
Hvigor 路径：/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw
SDK 路径：/Applications/DevEco-Studio.app/Contents/sdk
工程目录：/Volumes/hardDrive/DevEcoStudioProjects/AllDayRecording
包名：AllDayRecording.huawei.com
Ability：EntryAbility
模块：entry
HAP：entry/build/default/outputs/default/entry-default-signed.hap
应用 files 目录：/data/storage/el2/base/haps/entry/files
```

2026-08-29 最近一次真机实例：

```text
手表型号：RTS-AL00
手表类型：wearable
手表 API：23
当次手表目标：192.168.5.94:46549

手机型号：PLR-AL00
手机类型：phone
手机 API：26
当次手机目标：3DK0225528040628
```

无线调试端口是临时值。每次开始工作都必须重新执行 `list targets -v`，不得盲用上一次端口。

## 3. 命令变量

在同一个终端会话内，可以先设置以下任务专用变量：

```sh
HDC_BIN="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
HVIGOR_BIN="/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw"
DEVECO_SDK_PATH="/Applications/DevEco-Studio.app/Contents/sdk"
WATCH_TARGET="192.168.5.94:46549"
PHONE_TARGET="3DK0225528040628"
BUNDLE_NAME="AllDayRecording.huawei.com"
HAP_PATH="/Volumes/hardDrive/DevEcoStudioProjects/AllDayRecording/entry/build/default/outputs/default/entry-default-signed.hap"
```

注意：某些 AI 的每次命令运行在独立 shell 中，变量不会自动保留。遇到这种环境时，应在每条命令中使用绝对路径，或在同一次命令调用中重新声明任务专用变量。

## 4. 发现并连接设备

### 4.1 查看所有目标

```sh
"$HDC_BIN" list targets -v
```

典型结果：

```text
192.168.5.94:46549    TCP    Connected    localhost
3DK0225528040628      USB    Connected    localhost
```

状态含义：

- `Connected`：可以继续执行设备命令；
- `Offline`：只是保存过该端点，当前不可用；
- `unknown`、`Device not found`：不能据此安装或宣称设备已经连接。

### 4.2 连接无线手表

先从手表无线调试页面取得当前 IP 和端口，然后执行：

```sh
"$HDC_BIN" tconn 192.168.5.94:46549
```

成功结果应包含：

```text
Connect OK
```

随后必须再次验证：

```sh
"$HDC_BIN" list targets -v
```

### 4.3 核对设备身份

手表：

```sh
"$HDC_BIN" -t "$WATCH_TARGET" shell param get const.product.model
"$HDC_BIN" -t "$WATCH_TARGET" shell param get const.product.devicetype
"$HDC_BIN" -t "$WATCH_TARGET" shell param get const.ohos.apiversion
```

手机：

```sh
"$HDC_BIN" -t "$PHONE_TARGET" shell param get const.product.model
"$HDC_BIN" -t "$PHONE_TARGET" shell param get const.product.devicetype
"$HDC_BIN" -t "$PHONE_TARGET" shell param get const.ohos.apiversion
```

安装前至少确认：

- 手表是预期的 `wearable`，不是手机；
- 手机是预期的 `phone`；
- 手表 API 23 与工程最低版本相容；
- 包名和签名属于当前新版应用，不是旧测试包。

## 5. 构建与安装

### 5.1 干净构建

在工程根目录执行：

```sh
DEVECO_SDK_HOME="$DEVECO_SDK_PATH" "$HVIGOR_BIN" --no-daemon clean
DEVECO_SDK_HOME="$DEVECO_SDK_PATH" "$HVIGOR_BIN" --no-daemon assembleHap
```

必须看到：

```text
BUILD SUCCESSFUL
```

然后检查安装包和 SHA-256：

```sh
ls -l "$HAP_PATH"
shasum -a 256 "$HAP_PATH"
```

构建成功只表示代码通过编译和打包，不代表手表运行、录音、同步或播放已经通过。

### 5.2 覆盖安装前必须备份

先创建新的、不会覆盖旧备份的目录。例如：

```sh
mkdir -p outputs/device_backups/20260829_203000_watch
mkdir -p outputs/device_backups/20260829_203000_phone
```

只读导出手表应用私有目录：

```sh
"$HDC_BIN" -t "$WATCH_TARGET" file recv -b "$BUNDLE_NAME" \
  /data/storage/el2/base/haps/entry/files \
  outputs/device_backups/20260829_203000_watch
```

只读导出手机应用私有目录：

```sh
"$HDC_BIN" -t "$PHONE_TARGET" file recv -b "$BUNDLE_NAME" \
  /data/storage/el2/base/haps/entry/files \
  outputs/device_backups/20260829_203000_phone
```

`-b` 表示通过调试应用通道访问该应用的私有目录。它只适用于可调试安装包。

记录文件数量、目录大小和音频 SHA-256：

```sh
find outputs/device_backups/20260829_203000_watch -type f | wc -l
du -sk outputs/device_backups/20260829_203000_watch
find outputs/device_backups/20260829_203000_watch -type f \
  \( -name '*.wav' -o -name '*.m4a' -o -name '*.part' \) \
  -exec shasum -a 256 {} +
```

手机目录执行相同检查。

备份没有成功、文件数量异常或设备身份不明确时，停止安装，不要继续猜测。

### 5.3 覆盖安装并保留数据

手表：

```sh
"$HDC_BIN" -t "$WATCH_TARGET" install -r "$HAP_PATH"
```

手机：

```sh
"$HDC_BIN" -t "$PHONE_TARGET" install -r "$HAP_PATH"
```

必须看到：

```text
install bundle successfully
```

`-r` 是覆盖安装。不要改成 `uninstall`，也不要先卸载再安装，因为卸载可能清除应用私有目录和录音。

### 5.4 安装后立即回读

覆盖安装后，再次把两端 `files` 目录拉到新的检查目录。使用校验模式比较安装前后内容：

```sh
rsync -nrc --itemize-changes \
  outputs/device_backups/20260829_203000_watch/files/ \
  outputs/device_checks/20260829_203000_watch_after_install/files/
```

说明：

- `-n` 只演练，不写入；
- `-c` 比较文件内容校验；
- 输出只有 `T` 通常表示本地回拉时间戳不同，内容相同；
- 出现大小或内容变化时必须进一步比较 SHA-256。

## 6. 启动、停止与进程状态

启动手表应用：

```sh
"$HDC_BIN" -t "$WATCH_TARGET" shell aa start \
  -a EntryAbility -b "$BUNDLE_NAME"
```

启动手机应用：

```sh
"$HDC_BIN" -t "$PHONE_TARGET" shell aa start \
  -a EntryAbility -b "$BUNDLE_NAME"
```

停止应用进程但保留数据：

```sh
"$HDC_BIN" -t "$WATCH_TARGET" shell aa force-stop "$BUNDLE_NAME"
"$HDC_BIN" -t "$PHONE_TARGET" shell aa force-stop "$BUNDLE_NAME"
```

查看进程 PID：

```sh
"$HDC_BIN" -t "$WATCH_TARGET" shell pidof "$BUNDLE_NAME"
"$HDC_BIN" -t "$PHONE_TARGET" shell pidof "$BUNDLE_NAME"
```

安全边界：

- 普通安装或同步验收前，不要在手表正在录音时强制停止应用；
- 只有用户明确要求中断恢复或跨进程测试时，才允许故意强制停止；
- 强制停止后必须检查 `.wav.part`、恢复报告、最终 WAV 和 SHA-256；
- `force-stop` 不等于清除数据，但会终止正在运行的录音和传输。

## 7. 读取设备日志

### 7.1 读取最近日志并自动结束

手表最近 500 行：

```sh
"$HDC_BIN" -t "$WATCH_TARGET" hilog -x -z 500
```

手机最近 500 行：

```sh
"$HDC_BIN" -t "$PHONE_TARGET" hilog -x -z 500
```

参数说明：

- `-x`：读完当前缓冲区后退出；
- `-z 500`：只读取末尾 500 行；
- 不使用 `-x` 时会持续跟随实时日志，需要手动中断。

### 7.2 按级别、标签、PID 或正则过滤

只看警告、错误和致命日志：

```sh
"$HDC_BIN" -t "$WATCH_TARGET" hilog -x -z 1000 -L WARN,ERROR,FATAL
```

按标签过滤：

```sh
"$HDC_BIN" -t "$WATCH_TARGET" hilog -x -z 1000 -T testTag,WearEngine
```

按正则过滤：

```sh
"$HDC_BIN" -t "$PHONE_TARGET" hilog -x -z 2000 \
  -e 'WearEngine|AllDayRecording|transfer|sync|error|fail'
```

先取得 PID，再按 PID 读取：

```sh
"$HDC_BIN" -t "$PHONE_TARGET" shell pidof "$BUNDLE_NAME"
"$HDC_BIN" -t "$PHONE_TARGET" hilog -x -z 1000 -P 12345
```

把 `12345` 替换成刚读取到的真实 PID。

不要默认执行 `hilog -r`，因为它会清除日志缓冲区。只有用户明确允许清理日志并且已经保存所需证据时才可以使用。

## 8. 设备截图

### 8.1 在设备生成截图

手表：

```sh
"$HDC_BIN" -t "$WATCH_TARGET" shell snapshot_display \
  -f /data/local/tmp/watch_screen.jpeg
```

手机：

```sh
"$HDC_BIN" -t "$PHONE_TARGET" shell snapshot_display \
  -f /data/local/tmp/phone_screen.jpeg
```

### 8.2 拉回 Mac

```sh
"$HDC_BIN" -t "$WATCH_TARGET" file recv \
  /data/local/tmp/watch_screen.jpeg \
  outputs/device_checks/watch_screen.jpeg

"$HDC_BIN" -t "$PHONE_TARGET" file recv \
  /data/local/tmp/phone_screen.jpeg \
  outputs/device_checks/phone_screen.jpeg
```

截图成功后，应使用本地图片查看工具打开 JPEG，而不是依赖 DevEco Studio 的设备镜像。WATCH 5 `RTS-AL00` API 23 已实测拒绝 `.png` 后缀并提示 `suffix must be .jpeg`，因此不要把示例改回 PNG。

注意：`snapshot_display` 的 `-h` 参数表示截图高度，不是 help。不要用 `snapshot_display -h` 查询帮助。

## 9. 导出 UI 结构并定位按钮

### 9.1 生成 UI 结构

```sh
"$HDC_BIN" -t "$WATCH_TARGET" shell uitest dumpLayout
```

返回示例：

```text
DumpLayout saved to:/data/local/tmp/layout_32618863823.json
```

把返回的真实路径拉回：

```sh
"$HDC_BIN" -t "$WATCH_TARGET" file recv \
  /data/local/tmp/layout_32618863823.json \
  /tmp/watch_layout.json
```

提取文字、坐标和可点击状态：

```sh
jq -r '
  .. | objects |
  select(.text? != null and .text != "") |
  [.text, .bounds, .clickable, .enabled] | @tsv
' /tmp/watch_layout.json
```

典型结果：

```text
开始录音    [101,197][365,289]    true    true
设置        [163,338][303,388]    true    true
```

部分手表会同时输出：

```text
I/O error : failed to load "/sys_prod/etc/xml/i18n_param_config.xml": Permission denied
DumpLayout saved to:...
```

只要随后明确输出 `DumpLayout saved to:` 且 JSON 能成功拉回，这条 i18n 权限提示通常不是本次 UI 导出的失败。

### 9.2 点击和滑动

点击坐标：

```sh
"$HDC_BIN" -t "$WATCH_TARGET" shell uitest uiInput click 230 243
```

双击、长按：

```sh
"$HDC_BIN" -t "$PHONE_TARGET" shell uitest uiInput doubleClick 650 750
"$HDC_BIN" -t "$PHONE_TARGET" shell uitest uiInput longClick 650 750
```

滑动：

```sh
"$HDC_BIN" -t "$PHONE_TARGET" shell uitest uiInput swipe \
  650 2200 650 700 800
```

返回、桌面、电源键：

```sh
"$HDC_BIN" -t "$PHONE_TARGET" shell uitest uiInput keyEvent Back
"$HDC_BIN" -t "$PHONE_TARGET" shell uitest uiInput keyEvent Home
"$HDC_BIN" -t "$WATCH_TARGET" shell uitest uiInput keyEvent Power
```

输入文字：

```sh
"$HDC_BIN" -t "$PHONE_TARGET" shell uitest uiInput inputText \
  600 500 '测试文字'
```

操作规则：

1. 点击前先导出当前 UI 结构；
2. 使用当前 `bounds` 的中心点，不复用旧截图坐标；
3. 点击后重新导出 UI，确认状态确实发生变化；
4. 手表和手机分辨率不同，不能共用坐标；
5. 不要根据按钮位置猜测破坏性操作。

## 10. 应用私有目录文件操作

### 10.1 只读导出目录或单个文件

导出整个 `files` 目录：

```sh
"$HDC_BIN" -t "$WATCH_TARGET" file recv -b "$BUNDLE_NAME" \
  /data/storage/el2/base/haps/entry/files \
  outputs/device_checks/watch_files_readback
```

导出单个队列清单：

```sh
"$HDC_BIN" -t "$WATCH_TARGET" file recv -b "$BUNDLE_NAME" \
  /data/storage/el2/base/haps/entry/files/automatic_sync_queue_v1.json \
  outputs/device_checks/automatic_sync_queue_v1.json
```

导出单个 WAV：

```sh
"$HDC_BIN" -t "$WATCH_TARGET" file recv -b "$BUNDLE_NAME" \
  /data/storage/el2/base/haps/entry/files/pcm_gap_test_123/segment_000001.wav \
  outputs/device_checks/segment_000001.wav
```

### 10.2 写回私有目录属于高风险操作

写入调试应用目录的语法是：

```sh
"$HDC_BIN" -t "$WATCH_TARGET" file send -b "$BUNDLE_NAME" \
  local_file \
  /data/storage/el2/base/haps/entry/files/target_file
```

只有以下条件全部满足时才能写入：

1. 用户明确要求恢复或进行受控测试；
2. 已经只读备份原文件并计算 SHA-256；
3. 已停止应用，避免并发写入；
4. 写入目标是精确文件，不是宽泛目录；
5. 写入后重新拉回并校验；
6. 不覆盖录音文件，除非用户明确要求恢复该录音且来源已验证。

不得用 `rm`、`unlink`、`rmdir`、卸载或清除应用数据来“整理”设备文件。

## 11. 文件完整性验收

### 11.1 比较手机与手表同一录音

```sh
shasum -a 256 \
  outputs/device_checks/watch/segment_000001.wav \
  outputs/device_checks/phone/segment_000001.wav
```

通过条件：

- 两边文件大小相同；
- 两边 SHA-256 完全相同；
- 手表源文件仍存在；
- 手机索引记录的来源路径与实际手表路径一致；
- 如果需要播放验收，手机应用能够正常播放该文件。

### 11.2 验收重复重试

重试前记录手机同步目录：

```sh
find outputs/device_checks/phone_before/synced_from_watch \
  -type f \( -name '*.wav' -o -name '*.m4a' \) | wc -l

find outputs/device_checks/phone_before/synced_from_watch \
  -type f \( -name '*.wav' -o -name '*.m4a' \) \
  -exec stat -f '%z' {} + | awk '{sum += $1} END {print sum}'
```

执行同一来源的真实重试后，再次回拉目录。通过条件：

- 音频文件数不增加；
- 音频总字节数不增加；
- 对应来源在索引中仍只有一条；
- 手表队列收到回执后为空；
- 手表源 WAV 仍保留。

### 11.3 验收安装未损坏旧录音

安装前后目录使用校验模式比较：

```sh
rsync -nrc --itemize-changes \
  outputs/device_backups/watch_before/files/ \
  outputs/device_checks/watch_after/files/
```

如果测试新增了录音，允许安装后目录出现新增文件，但安装前已存在文件的内容校验不得变化。

## 12. 推荐的完整真机流程

其他 AI 执行安装和验收时，应按以下顺序：

1. 查看 `hdc list targets -v`；
2. 重新连接当前无线调试端口；
3. 核对手表和手机的型号、设备类型、API；
4. 核对包名、HAP 路径和 SHA-256；
5. 只读备份两端应用 `files` 目录；
6. 记录备份文件数、总字节数和音频 SHA-256；
7. 覆盖安装，不卸载；
8. 安装后立即回读，确认旧数据未变化；
9. 启动手机接收端和手表应用；
10. 用 UI 结构确认按钮和状态；
11. 执行目标场景；
12. 在进度变化期间记录 0%、中间值、100% 或最终状态；
13. 回拉手机副本、手表源文件、索引和队列清单；
14. 比较大小和 SHA-256；
15. 确认手表源文件仍存在；
16. 写验收报告，明确区分“通过”“失败”“未测试”；
17. 报告任何仍需点击重新连接、保持前台或人工确认的限制。

不要把以下结果单独写成“真机验收通过”：

- HAP 构建成功；
- HAP 安装成功；
- UI 显示了进度但没有最终文件；
- 手机出现一个同名文件但没有比较 SHA-256；
- Wear Engine 找到了设备但没有传输；
- SDK 声明支持某 API，但真实设备没有执行成功。

## 13. HDC 与 Wear Engine 是两条不同通道

必须区分：

- HDC：开发调试连接，用于安装、日志、截图、UI 操作和文件读回；
- Wear Engine：应用运行时的手机与手表通信，用于控制命令和录音传输。

可能出现：

- HDC 正常，但 Wear Engine 提示未找到对端；
- Wear Engine 正在传输，但手表 HDC 因熄屏变为 Offline；
- 华为运动健康显示在线，但应用接收器注册已经失效；
- DevEco Studio 显示无设备，但 HDC 新端口重新连接后可用。

因此不要用一条通道的成功替代另一条通道的验收。

本工程已观察到：Wear Engine 文件接收可能卡在手机核心通道，系统日志出现 `P2pFileReceiver 140001 / recv error`，手表侧返回 `206`。仅注销并重新注册接收回调不足以恢复；当前“重新连接”会执行 `stop -> wearEngine.destroy() -> start`，释放核心通道后再注册接收器。发生该情况时：

1. 确认手表原文件和自动队列仍在；
2. 不要删除或重建录音；
3. 在手机点击“重新连接”，或停止并重新启动手机应用；
4. 等页面显示 `已通过 Wear Engine 连接：HUAWEI WATCH 5-AB3，可以同步`；
5. 再发起同步；
6. 仍失败时读取两端 Hilog，并保留失败时间点。

## 14. 常见问题

### `Connect server failed`

可能是 HDC server 没有启动、当前执行环境无法访问本机调试服务或权限被隔离。

处理顺序：

```sh
"$HDC_BIN" start -r
"$HDC_BIN" list targets -v
```

如果命令运行在受限沙箱中，需要取得访问本机 HDC 服务和设备的授权，不能改用 DevEco Studio 来掩盖这个问题。

### `Device not found or connected`

1. 重新执行 `list targets -v`；
2. 不使用 `Offline` 端点；
3. 在手表查看当前无线调试端口；
4. 执行新的 `tconn`；
5. 再核对设备型号。

### 手表熄屏后 HDC 变为 Offline

这在无线调试中可能发生。先唤醒手表，再重新执行 `tconn`。不要高频轮询熄屏手表，因为调试轮询本身可能干扰省电和录音测试。

### 普通 shell 无法读取应用私有目录

不要尝试提升权限或搜索整个 `/data`。对可调试应用使用：

```sh
hdc -t TARGET file recv -b BUNDLE_NAME REMOTE_PATH LOCAL_PATH
```

### `uitest dumpLayout` 出现 i18n 权限提示

如果后面仍输出 `DumpLayout saved to:` 且 JSON 可读，可以继续；如果没有生成路径，则视为失败。

### 安装成功但应用行为不对

安装成功不代表：

- 包名和签名与 Wear Engine 申请一致；
- 手机和手表安装的是同一新版；
- 远端应用可被启动；
- 麦克风能在后台首次打开；
- 文件已经传输并持久保存。

继续检查设备身份、包名、真实 UI、Hilog 和最终文件。

### 手机和手表用了不同包

本工程曾混淆旧包 `com.example.alldayrecording`、其他测试包与当前包 `AllDayRecording.huawei.com`。Wear Engine 的包名、签名和 `appIdentifier` 必须匹配。不要把旧包录音、旧包传输结果或旧包日志算进新版验收。

## 15. 其他 AI 必须遵守的执行约束

1. 优先使用 HDC 命令，不要为了查看设备状态而默认操作 DevEco Studio。
2. 每轮都重新发现设备，不复用可能过期的无线端口。
3. 在任何安装、恢复或中断测试前先备份不可替代录音。
4. 安装只使用覆盖安装，禁止未经授权卸载。
5. 不删除手表录音，不清理手机已有重复文件。
6. 文件传输验收必须比较最终文件大小和 SHA-256。
7. UI 进度只是辅助证据，不是最终文件完整性证据。
8. 点击设备前先导出当前 UI 结构，不猜坐标。
9. 写回应用私有目录前必须停止应用、备份目标并取得明确授权。
10. 如果测试中发现实现缺陷，先停止可能继续造成误确认的接收器，再修复和复测。
11. 如实报告首次连接、前台依赖、省电策略和系统拒绝等限制。
12. 测试结束时确认手表是否仍在录音、是否存在 `.part`、队列是否为空。

## 16. 本工程的最近验证证据

2026-08-29 自动队列与同步验收已经使用以上命令完成，没有依赖 Computer Use 操作 DevEco Studio：

- 自动队列跨手表进程重启恢复：通过；
- 同一来源重试不新增手机副本：通过；
- 手机显示 `手机已保存 12 个文件 · 手表扫描 25 个`：通过；
- 手表源文件保留和手机副本 SHA-256 一致：通过；
- Wear Engine 首次手动同步稳定性：曾未通过；硬重建 Wear Engine 通道后原积压文件成功进入手机索引。

完整报告：

[`outputs/device_checks/20260829_persistent_queue_final/PERSISTENT_QUEUE_ACCEPTANCE_REPORT.md`](../outputs/device_checks/20260829_persistent_queue_final/PERSISTENT_QUEUE_ACCEPTANCE_REPORT.md)
