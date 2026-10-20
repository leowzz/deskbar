# 构建、发布与更新

## 常用命令

首次执行 `make setup` 会从 `.env.example` 创建本机 `.env`。两者使用 `version=v0.1.0` 格式，`.env` 不提交；不要手动改版本文件，统一使用发布命令。

```sh
make check                    # 全量检查，包含发布脚本测试
make release                  # patch +1，同步版本、提交、创建 annotated tag
make release V=v1.2.3          # 显式指定更高的正式版本
# 确认后自行推送当前分支，再推送新 tag：
git push
git push origin v1.2.3
```

`make release` 要求工作区干净、版本来源一致且 tag 不存在。同步 `.env`、`.env.example`、Rust workspace / Cargo.lock、桌面 package.json / Tauri 配置和 Android pubspec；Android versionCode 每次加一。本地提交或 tag 不触发远端构建，脚本不自动 push。只支持正式版 `vX.Y.Z`，预发布不进入此通道。版本事务测试使用临时 Git 仓库。

| 构建命令 | 产物 |
| --- | --- |
| `make desktop-build` | 本机桌面调试程序，不打安装包 |
| `make desktop-release` | 本机桌面安装包及签名更新包，需 updater 私钥 |
| `make android-build` | 调试 APK，不作为发布或正式版覆盖更新 |
| `make android-release` | arm64 发布签名 APK |
| `make android-bundle` | arm64 发布签名 AAB，可选商店用途 |

桌面产物在 `target/release/bundle/`（指定 target 后在 `target/<target>/release/bundle/`），APK 在 `apps/android/build/app/outputs/flutter-apk/`，AAB 在 `apps/android/build/app/outputs/bundle/release/`。构建不修改版本。

本机构建签名桌面更新包：

```sh
export TAURI_SIGNING_PRIVATE_KEY="$HOME/.config/deskbar/signing/updater.key"
export TAURI_SIGNING_PRIVATE_KEY_PASSWORD=''
# 未配置 Apple 证书的本机测试包使用 ad-hoc 签名：
APPLE_SIGNING_IDENTITY=- make desktop-release
```

## CI 与安装包

[Checks](../.github/workflows/check.yml) 在 main push / PR 时运行 `make check`。[Release](../.github/workflows/release.yml) 只由版本 tag 触发，先检查版本、tag 的远端分支归属、签名配置和发布脚本，再构建：

- macOS Apple Silicon（arm64）：DMG 和 Tauri `.app.tar.gz` 更新包。
- Windows x64：NSIS `.exe` 安装包，同时用于更新。
- Android arm64：发布签名 APK。

每个平台上传 artifact；发布任务必须等待三平台成功，校验文件集合和 SHA-256，再生成 `latest.json` 与 `SHA256SUMS`。先上传到 draft，全部成功后才公开 Release。失败可重跑 draft；已经公开的同版本拒绝覆盖，应递增版本重新发布。发布阶段串行执行，并读取现有静态清单比较版本；只有更高版本才设为 Latest，防止旧版本迟到覆盖最新通道。

Flutter 固定 3.44.8，Node 24、pnpm 11.9.0，Rust stable，Python 3.11+。桌面构建包含 Flutter Web 预览器，Windows 同样需要 Flutter；构建脚本关闭 Git Bash 的路径转换，保证 `/editor/` 原样传给 Flutter。复制预览器用 Python，不依赖 rsync。

Android 在发布 APK 构建后运行 `:app:testDebugUnitTest` 验证原生逻辑；当前工程只注册 debug 单元测试变体，没有 `testReleaseUnitTest`。发布 APK 另用 `apksigner` 验证签名。

## 签名配置

Repository Secrets：

| Secret | 用途 |
| --- | --- |
| `TAURI_SIGNING_PRIVATE_KEY` | DeskBar 专用 updater 私钥，必需 |
| `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` | updater 私钥密码，未加密密钥可留空 |
| `DESKBAR_ANDROID_KEYSTORE_BASE64` | 已有 Android 发布 JKS 的 Base64，必需 |
| `DESKBAR_ANDROID_KEYSTORE_PASSWORD` | JKS 密码，必需 |
| `DESKBAR_ANDROID_KEY_ALIAS` | 签名别名，必需 |
| `DESKBAR_ANDROID_KEY_PASSWORD` | 签名密钥密码，必需 |
| `APPLE_CERTIFICATE` / `APPLE_CERTIFICATE_PASSWORD` / `APPLE_SIGNING_IDENTITY` | 可选 Apple P12 签名组，全有或全无 |
| `APPLE_ID` / `APPLE_PASSWORD` / `APPLE_TEAM_ID` | 可选公证组，全有或全无；要求上述签名组，密码为 app-specific password |

updater 公钥保存在 [Tauri 配置](../apps/desktop/src-tauri/tauri.conf.json)，私钥本机保存在 `~/.config/deskbar/signing/updater.key`，需要独立备份。不要更换已分发客户端信任的公钥，或在日志中打印私钥。

Android 沿用现有签名；Gradle 优先读取 `DESKBAR_ANDROID_KEYSTORE_FILE` 及上述密码和别名变量，否则读取 `~/.config/deskbar/signing/deskbar-release.properties`。properties 字段为 `keystoreFile`、`keystorePassword`、`keyAlias`、`keyPassword`。密钥库和配置权限应为 `0600`。缺失签名时 release 构建失败。先前记录的 Android 证书 SHA-256 为 `12:61:8D:E7:86:32:31:6F:58:3D:BA:A7:E5:CF:63:EF:FE:44:68:F3:40:30:7C:D9:E6:E5:C8:ED:BB:5C:0C:06`，发布时仍应与实际 APK 核对。

`DESKBAR_ANDROID_KEYSTORE_BASE64` 必须是原发布 JKS 文件内容的 Base64，允许换行；不能填文件路径。CI 在预检时验证编码和 JKS 文件头，还原失败时不输出密钥内容。更新此 Secret 可用 `base64 < /path/to/release.jks | gh secret set DESKBAR_ANDROID_KEYSTORE_BASE64 --repo leowzz/deskbar`；不要创建新密钥替换已分发应用的签名。

未配置 Apple 证书时，macOS 采用 ad-hoc 签名，未公证，首次启动可能需要系统手动允许。Windows 当前不做 Authenticode，可能显示未知发布者。Tauri `.sig` 是更新包验签，不代表 Apple 公证或 Windows 发布者签名。

## 应用内更新

双端只读取静态地址：

```text
https://github.com/leowzz/deskbar/releases/latest/download/latest.json
```

不查询 GitHub REST / GraphQL API。清单内下载链接固定到具体版本的 `/releases/download/vX.Y.Z/` 资产；桌面平台键是 `darwin-aarch64` 和 `windows-x86_64`，Android 元数据放在独立 `android` 字段（URL、SHA-256、大小、version_code）。发布脚本是清单生成的唯一入口。

电脑在「设置 → 软件更新」检查，发现新版后选择「安装并重启」，Tauri 下载、验证签名并安装。Android 在设置中检查；未配对也可从顶部更新按钮进入。下载 APK 后验证大小、SHA-256、包名、版本号和与已安装应用一致的签名，再打开系统安装器。首次需要允许此应用安装更新，授权后返回再次点击安装；不静默安装。

双端拒绝相同、旧版和预发布；Android 还要求更高的 versionCode。检查失败显示重试，不误报已是最新版。尚无正式 Release 时显示无法检查。检查不会下载或安装，安装需要用户操作。调试签名 APK 无法覆盖升级为正式签名，应先安装正式包。

验证命令：`make release-test` 覆盖版本事务、脏工作区、已有 tag、提交失败恢复、完整产物与损坏文件；`make check` 包含 Rust 更新版本策略和 Flutter 更新交互。Android 原生清单测试可在 `apps/android/android` 执行 `./gradlew :app:testDebugUnitTest`。本地通过不等于 GitHub 构建或已发布；三平台安装、旧版更新、权限拒绝与网络失败仍需真实安装包验证。
