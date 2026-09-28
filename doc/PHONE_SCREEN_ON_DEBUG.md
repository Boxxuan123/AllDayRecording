# 手机真机调试：开始常亮，结束恢复

在 Windows PowerShell 中执行。每次先查看当前连接的设备，确认目标是手机；设备编号可能变化，不要直接沿用上次的编号。

## 开始调试

```powershell
$HdcBin = 'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
& $HdcBin list targets -v
$PhoneTarget = '3DK0225528040628' # 改成上一步显示的手机设备编号
& $HdcBin -t $PhoneTarget shell 'power-shell timeout -o 2147483647'
& $HdcBin -t $PhoneTarget shell 'power-shell wakeup'
& $HdcBin -t $PhoneTarget shell 'hidumper -s 3301 -a -a' | Select-String 'ScreenOffTime'
```

看到 `OverrideTimeout=2147483647ms` 表示已覆盖自动熄屏时间，约 24.8 天。`wakeup` 会点亮屏幕。

## 调试结束

```powershell
& $HdcBin -t $PhoneTarget shell 'power-shell timeout -r'
& $HdcBin -t $PhoneTarget shell 'hidumper -s 3301 -a -a' | Select-String 'ScreenOffTime'
```

确认 `OverrideTimeout` 不再是 `2147483647ms`。如果换了终端，先重新设置 `$HdcBin` 和 `$PhoneTarget`。这里只覆盖熄屏超时，不需要执行 `power-shell setmode 602`；`602` 是性能模式。
