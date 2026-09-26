# 手机 UI 自动化入门：Hypium

这是一条独立于 `phone/src/test` ArkTS 单元测试的 Python UI 用例。应用的 bundleName 是 `AllDayRecording.huawei.com`，手机模块是 `phone`，入口 Ability 是 `EntryAbility`，入口页面是 `phone/src/main/ets/pages/Index.ets` → `PhoneRootPage`。用例文件为 [`testcases/PhoneMoreSmoke.py`](testcases/PhoneMoreSmoke.py)，其同名 JSON 是 Hypium 的用例配置。

## 手机准备

1. 在手机的“设置 → 关于本机”中连续点击版本号，开启开发者选项；在“设置 → 系统和更新 → 开发人员选项”中开启 USB 调试。连接电脑后，在手机上允许 USB 调试授权，保持解锁、亮屏。
2. 先用 DevEco Studio 将本项目的 **phone** 模块安装到手机。测试只负责启动已安装的应用，不负责构建或安装 HAP。
3. 用 DevEco Testing 自带的 hdc 确认连接。在 PowerShell 中运行：

   ```powershell
   & 'C:\Program Files\DevEco Testing\app\resources\bin\hdc.exe' list targets
   ```

   应看到一台设备序列号；若有多台，请只保留目标手机连接。本机验证时序列号为 `3DK0225528040628`。还可运行 `hdc shell param get const.product.devicetype`，手机应返回 `phone`。

## 最简单的运行方法

在 PowerShell 中进入本目录，使用 **DevEco Testing 自带的 Python** 运行：

```powershell
cd C:\Users\32673\DevEcoStudioProjects\AllDayRecording\tests\ui
& 'C:\Program Files\DevEco Testing\python\python.exe' main.py
```

`main.py` 会把 DevEco Testing 自带的 hdc 加入当前进程的 PATH，然后让 Hypium 读取 `config/user_config.xml` 和 `testcases/PhoneMoreSmoke.json`。用例依次停止旧实例、启动 App、等待并点击“更多”页签、验证“设备与数据”分区、停止 App。成功时终端出现 `passed: 1, failed: 0`；报告在 `reports/<运行时间>/summary_report.html`。点击的是 Hypium 找到的真实控件，没有坐标点击。

## 在 DevEco Testing 客户端中运行

DevEco Testing 客户端的“回归测试”服务读取**测试包**，不直接导入 `.py`。如需在客户端看实时投屏、步骤与报告：

1. 按华为[应用 UI 测试（基于 Python）](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/hypium-python-guidelines)指引，在 PyCharm 安装与 DevEco Testing 匹配的 **DevEco Testing Hypium** 插件，并把本目录 `tests/ui` 作为 Hypium 工程打开。生成测试包还需要该 Python 环境安装 `setuptools`；当前 DevEco Testing 自带 Python 没有它，须按插件提示为打包环境安装。
2. 本目录已备好 `setup-regression.py`、`MANIFEST.in`、`config/user_config.xml` 和单用例的 `testcases/PhoneMoreSmoke.json` / `.py`。在 PyCharm 的工程根目录右键选择 **DevEco Testing Hypium → 生成测试服务包 → 回归测试**，填写应用名称和场景，生成测试包。
3. 打开 **DevEco Testing → 测试服务 → 回归测试**，选择已连接的手机，在“测试包路径”选择刚生成的包，查看包详情后点击“创建任务”。执行页可看手机实时投屏和各步骤结果。

本机已用 Hypium 6.1.0.210 和 HarmonyOS 手机实际运行本用例：`1 passed, 0 failed`。官方[回归测试说明](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/other-test)说明了测试包生成与客户端执行入口。

## 定位与稳定性

当前用例使用固定中文文本 `BY.text("更多")` 和 `BY.text("设备与数据")`。首页的“更多”页签始终存在，目标分区不依赖录音、审核、同步数据，因此本阶段无需改动 ArkUI 业务代码。它们目前没有专用 `id`；如果以后文案本地化、出现重名或页签结构变化，应在页签/分区加入稳定 `id`，再改为 `BY.id(...)`。其他页面中的动态录音列表、审核数量、网络/设备状态及“同步与备份”导航菜单不适合首条冒烟测试，后续覆盖时要补稳定标识与测试数据准备。

框架可在未安装 Pillow/OpenCV 时完成本条控件测试，但步骤截图处理可能打印相关警告；本机报告的用例结果仍为通过。

## 第一阶段业务验收扩展

新增 `run_phase1.py` 沿用本工程驱动与配置，运行 `PhoneOfflineAnnotation` 和 `PhoneSyncInteraction`。这两个用例必须先安装隔离测试入口，不能直接用于正式应用。准备、数据保护、运行与正式恢复见 [隔离真机复现说明](../../tools/quality/sync-phase1-device/README.md)，本次结果和未完成项见 [第一阶段验收记录](../../doc/SYNC_PHASE1_ACCEPTANCE.md)。原 `main.py` / `PhoneMoreSmoke` 仍按上述方式独立运行。
