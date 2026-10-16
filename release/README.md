# Release

Android 发布签名已配置，桌面与其他平台的发布仍待后续接入。

本机发布密钥位于 `~/.config/deskbar/signing/`：

- `deskbar-release.keystore`：JKS 密钥库，权限 `0600`。
- `deskbar-release.properties`：本机路径、别名和密码，权限 `0600`。

Gradle release 构建优先读取 `DESKBAR_ANDROID_KEYSTORE_FILE`、`DESKBAR_ANDROID_KEYSTORE_PASSWORD`、`DESKBAR_ANDROID_KEY_ALIAS` 和 `DESKBAR_ANDROID_KEY_PASSWORD`；未设置时读取上述本机配置。缺少配置时，release 构建会直接失败，避免产出未签名或使用错误密钥的包。

当前证书 SHA-256 指纹为 `12:61:8D:E7:86:32:31:6F:58:3D:BA:A7:E5:CF:63:EF:FE:44:68:F3:40:30:7C:D9:E6:E5:C8:ED:BB:5C:0C:06`。升级和发布前应将线上包的指纹与此值比较。

GitHub Actions 使用以下 Repository Secrets：

| Secret | 内容 |
| --- | --- |
| `DESKBAR_ANDROID_KEYSTORE_BASE64` | `deskbar-release.keystore` 的 Base64 内容 |
| `DESKBAR_ANDROID_KEYSTORE_PASSWORD` | `keystorePassword` |
| `DESKBAR_ANDROID_KEY_ALIAS` | `keyAlias`，当前为 `deskbar-release` |
| `DESKBAR_ANDROID_KEY_PASSWORD` | `keyPassword` |

本机可用 `base64 < ~/.config/deskbar/signing/deskbar-release.keystore | tr -d '\\n'` 生成第一项的值，再通过 GitHub 仓库的 Settings → Secrets and variables → Actions 保存。本地构建从配置文件读取，CI 从 GitHub Secret 读取；密码不写入仓库或工作流日志。

后续承载 Android、macOS 与 Windows 的打包和更新配置。DeskBar 使用独立应用标识、配置目录、身份和签名更新通道，可与 Orbit 并存。

macOS 需要签名与公证；Windows 验证签名安装、防火墙与平台动作；Android 使用独立签名。密钥与发布凭据由系统安全存储或 CI secret 提供，不能提交到本目录。

验收以已发布安装包在新设备上的行为为准，见 [开发计划](../docs/roadmap.md)。
