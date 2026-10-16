# 跨端验证

## 日常检查

先运行 `make setup`，再运行 `make check`：文档链接、Rust 格式和单元 / 真实 TLS 测试、Tauri 编译检查、桌面类型与格式、Flutter 分析与组件测试。桌面构建用 `make desktop-build`，开发 APK 用 `make android-build`。

## Android 原生连接测试

启动独立 Android 模拟器（API 28+），指定其序列号：

```sh
make test-android-connection ANDROID_DEVICE=emulator-5560
```

脚本建立临时电脑身份和私有邀请文件，再在模拟器运行 Flutter integration_test，结束后清理夹具。测试夹具仅通过显式的 ignored Rust 测试启动，自动确认一台测试设备，八秒后撤销内容共享，再过八秒撤销连接；不会链接进桌面程序。脚本拒绝物理设备序列号，避免覆盖用户设备上的配对。

当前覆盖：错误 SPKI 拒绝、完整邀请配对、审批后才能读取快照、原生 WSS、Keystore 加密保存后的读取、暂停 / 恢复重连、工作台三类快照、加密缓存恢复、未知动作拒绝、撤销单项共享后的缓存清除、电脑撤权与凭据清除。连接使用模拟器访问宿主机的 `10.0.2.2`，不把这种路径当作 Wi-Fi 自动发现或摄像头扫码验证。

## 2026-10-16 验证记录

- macOS：桌面前端生产构建、Tauri 原生编译与开发程序启动；桌面浏览器在宽屏与 560 像素窗口检查设备管理、邀请、确认与移除，交互使用测试桥接数据。
- Android：Flutter 分析、组件测试、debug APK 构建；Android 12 / API 31 arm64 模拟器的上述原生连接测试通过。
- 小米 14 Ultra / Android 16（API 36、arm64）：改名后的「Desklet 工作台」开发 APK 已通过 USB 安装并启动，确认前台 Activity 和进程存在。随后用户确认已连接成功；这不等同于相机扫码和各种权限拒绝路径都已验证。
- Rust：邀请过期、错误秘密、一次邀请不能被其他设备复用、相同请求重试、审批、摘要保存、撤权、重启保留身份 / 更换 epoch、重复进程锁、真实 TLS 认证测试通过。

## 仍未完成

物理设备扫码、真实无摄像头设备、Android 9 与新版 Android 权限、macOS 权限 / 钥匙串拒绝恢复、Wi-Fi 多播、换 IP、VPN、多网卡、端口冲突和 IPv6 仍需实测。API 用量、页面编辑、签名 / 公证、安装更新和 Windows 尚未交付。

## RawBlock 界面验证

桌面已在 1040 px 宽屏和 560 px 窄窗口检查首页、配对邀请、确认、复制和设备移除；浏览器使用测试桥接状态。检查字号、字体加载、直角、3 / 5 px 边框、至少 44 px 按钮和横向溢出。低高度邀请框使用内部滚动，键盘 Escape 可关闭。

Flutter 组件测试覆盖 360 × 640、1.8 倍系统字号、800 × 360 横屏，以及已配对长电脑名称和断开弹窗。Android 模拟器还可运行首页和配对弹窗的 UI 测试并导出截图：

```sh
# 仅在独立测试模拟器运行：测试会清除这台模拟器上的连接信息。
cd apps/android
flutter drive --driver=test_driver/ui.dart --target=integration_test/ui_test.dart \
  -d emulator-5560 --dart-define=DESKLET_SCREENSHOTS=true
```

截图默认保存到 Android 工程的 `build/ui-screenshots`，也可用 `DESKLET_SCREENSHOT_DIR` 环境变量指定本机目录。字体来源与许可见 [字体说明](../assets/fonts/README.md)。物理设备视觉效果与相机扫码仍需验证。

## 工作台内容与动作验证

`make check` 包含：只读 SQLite 会话投影、过滤归档 / 子会话、额度多窗口 / 重置 / 缺失数据、设备快照裁剪、入口路径不外泄、权限持久化、动作 TTL / epoch / 版本校验、按设备隔离和重复请求仅接收一次。Flutter 覆盖三类真实数据结构、窄屏 / 横屏 / 1.8 倍字号、打开请求仅传 ID / 版本、离线禁止提交、重置不补为 100%。

本机只读来源冒烟测试可显式运行：

```sh
cargo test --locked -p desklet-host live_local_sources -- --ignored --nocapture
```

该测试读取当前电脑的 Codex 数据库，通过本机 app-server 查询已登录账户额度，只输出会话数量与额度窗口数量。2026-10-16 已通过；不代表所有 Codex 历史数据库格式都受支持。来源异常提示与其他来源独立。

本轮补充验证：Android 12 原生跨端工作台测试已通过（三类数据、未知动作拒绝、共享撤销清缓存）；桌面浏览器使用测试桥接完成共享勾选与入口新增 / 修改 / 移除，560 px 窄窗无横向溢出。Android 模拟器导出的工作台截图已检查。

小米本轮交付：新版 APK 已覆盖安装并启动，保留原配对与 Keystore 数据。连接助手正常监听 42831，手机前台显示「已连接」。2026-10-16 用户完成会话、额度与快捷入口的真机联调，并确认功能正常。该验收不覆盖其余 Android 版本、Windows、网络切换和权限拒绝恢复等未完成场景。
