# Release

当前没有可发布安装包、CI 或签名配置。

后续承载 Android、macOS 与 Windows 的打包和更新配置。DeskBar 使用独立应用标识、配置目录、身份和签名更新通道，可与 Orbit 并存。

macOS 需要签名与公证；Windows 验证签名安装、防火墙与平台动作；Android 使用独立签名。密钥与发布凭据由系统安全存储或 CI secret 提供，不能提交到本目录。

验收以已发布安装包在新设备上的行为为准，见 [开发计划](../docs/roadmap.md)。
