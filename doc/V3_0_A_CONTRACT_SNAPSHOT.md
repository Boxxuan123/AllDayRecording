# V3.0-A Phone 契约快照

> 状态：current
> canonical source：AllDayRecording-ASR `contracts/v3`

Phone 的 V3 ArkTS decoder 位于
`phone/src/main/ets/v3/contracts/V3ContractModels.ets`。它是 canonical schema 的
生成快照，不是第二份契约源；精确来源版本与 fixture SHA-256 记录在
`contracts/v3/source.json`。

V3 默认关闭。当前快照只为 V3.0-A contract fixture 提供可编译 decoder，不改变
Phone Root、页面、Preferences、上传服务或 Watch↔Phone 协议。生产 Passkey RP
ID/origin 仍由 Computer V3 发布环境校验，禁止把开发占位域名写入真机发布。

Host Test 同时覆盖 canonical 已知值和未来未知 enum：未知值必须降级为本地
`unknown`，不能让整批同步响应解析失败。
