# LAN

嵌入桌面进程的 Rust 连接模块：HTTPS / WSS、固定 Host 公钥的邀请、设备凭据认证和 IPv4 query / offer。稳定身份与授权规则委托给 [HostRuntime](../host/README.md)，发现消息只提供候选地址。

TLS 私钥使用系统钥匙串，证书可续签且 SPKI 不变。HTTPS 优先端口 42831，冲突时选择系统端口。发现使用实验组 `239.77.68.76:42831`，尚未冻结网络参数。多网卡、IPv6、接口变化重绑与局部扫描仍待实现 / 实测。

`cargo test -p desklet-lan` 使用真实 TLS 请求验证受保护快照和撤权。专门的 Android 测试夹具默认忽略，不链接进生产应用；运行方式见 [跨端验证](../../tests/README.md)。

当前只实现 [协议草案](../../docs/protocol.md#v1-连接实现子集) 的连接子集，不提供远程命令、图标或数据源。
