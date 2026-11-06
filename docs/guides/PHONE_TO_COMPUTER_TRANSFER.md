# 手机到电脑安全传输

手机端在“设置 -> 上传录音到电脑”提供一次配对、自动发现和断点上传。它只上传手机已经安全保存的手表分段录音，不直接访问手表，也不会在上传成功后删除手机原文件。

## 首次配对

1. 在电脑端启动 `allday-asr transfer receive`。
2. 在电脑上打开终端显示的 `transfer-pairing.png`。
3. 手机点击“扫描电脑上的配对二维码”。二维码一次携带当前 HTTPS 地址、配对 CA、CA 指纹、稳定接收端标识和首次配对码，不再需要两端复制粘贴。
4. 按系统界面确认一次 Passkey。

手机验证二维码中 CA 的 DER SHA-256 指纹后才保存证书。Passkey 只授权首次登记：登记过程中手机在 HUKS 生成 P-256 设备私钥，电脑只保存对应公钥。配对码、设备私钥和 Passkey 私钥都不会写入应用配置。

HarmonyOS Passkey 要求 RP 域名已经在 AppGallery Connect/App Linking 中与当前应用关联。首次真机联调前，需要确定真实且稳定的域名，并让电脑端使用相同 RP ID 与 origin，例如：

```powershell
allday-asr transfer receive `
  --passkey-rp-id transfer.example.com `
  --passkey-origin https://transfer.example.com
```

默认 `alldayrecording.local` 只是电脑端占位值，不能替代 AGC 域名关联。

## 后续上传与换 Wi-Fi

上传时手机通过 `_allday-pc._tcp` mDNS/DNS-SD 服务自动查找配对电脑，并只接受 TXT 记录中稳定 `receiver_id` 一致的候选地址。候选地址仍必须通过已保存 CA 的 TLS 校验，因此伪造 mDNS 广播不能冒充电脑。

找到电脑后，手机为实际 HTTP 请求申请一次性 challenge，并使用 HUKS 私钥静默签名。签名严格绑定：

- challenge ID 和随机 nonce；
- HTTP 方法与接口路径；
- 原始请求正文 SHA-256；
- PUT 分片的 `Upload-Offset`。

Challenge 有效期为 120 秒且只能使用一次。正常上传不再调用 Passkey，不弹身份确认，也没有可复制的长期 Bearer Token。换 Wi-Fi 后电脑更新 mDNS 地址和由原 CA 签发的当前 IP 证书，手机自动重新发现，用户不需要修改地址或重新认证。

手机按以下顺序上传：

1. 从 `ReceivedRecordingFile.sourcePath` 恢复原 Watch 会话目录。
2. 计算录音完整 SHA-256，创建或恢复确定性的上传任务。
3. 从电脑返回的真实 offset 开始分片续传。
4. 所有录音完成后生成并上传 `AllDayRecording session manifest v1` 的 `session_summary.json`。

网络中断后重新点击上传即可恢复。电脑完成全文件 SHA-256 校验并原子发布后，手机才显示该文件完成。

## 安全边界

- 只使用经过配对 CA 验证的 HTTPS，不提供“忽略证书错误”。
- Passkey 只用于首次登记、恢复或重新授权；日常传输使用 HUKS 设备密钥。
- HUKS 私钥不可通过应用配置导出，电脑端只持久化公钥。
- mDNS 只负责发现位置，不参与信任判断。
- 每个签名只能用于一个准确请求，不能重放或换到另一个文件分片。
- 上传不会覆盖电脑端同路径的不同内容，手机原文件始终保留。
