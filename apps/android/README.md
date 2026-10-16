# DeskBar 工作台

Flutter + Kotlin 的独立 Android App，标识 `app.deskbar.workbench`，最低 Android 9。支持扫码 / 粘贴邀请、前台恢复重连、授权会话 / 额度 / API 用量 / 快捷入口，以及接收电脑管理的多页组件布局。

从根目录运行 `make setup`，再运行 `make android ANDROID_DEVICE=<设备序列号>`。`make android-build` 构建开发 APK。生产签名未配置，不能把 debug APK 当作发布版本。

Kotlin `ConnectionRuntime` 经 MethodChannel / EventChannel 管理固定 SPKI 的 OkHttp HTTPS / WSS、IPv4 发现与重连。设备凭据经 Android Keystore 的 AES-GCM 密钥加密，备份关闭，不存到 Flutter 配置。暂停 Activity 时停止连接，恢复时重连；不使用后台常驻服务。

摄像头不是必需硬件。无法扫码时可粘贴完整邀请，短码 PAKE 尚未实现。已在 Android 12 模拟器运行原生跨端测试；物理设备、扫码相机、Android 9 与新版权限、大字号和系统回收仍需现场验证。

页面和组件在电脑「屏幕编辑」中管理，Android 主入口不提供编辑。`WorkbenchCanvas` 从授权快照读取布局，布局随快照由 Keystore 缓存；不再读取或迁移旧本机布局文件。手机通过现有 WSS 上报可用宽高、字号、主题、当前页和已应用布局版本。

基础设置保留主题、全屏、锁定旋转、重连与断开连接；右上角入口和长按空白均可打开。显示偏好独立保存在设备，不由电脑布局覆盖。横滑切页、纵向滚动，离线显示旧数据并禁用打开。

电脑嵌入式编辑入口为 `lib/desktop_editor.dart`，与 Android 共用布局及组件代码；`scripts/build_editor.sh` 构建并复制本地资源到桌面 public 目录。编辑器支持多页草稿、撤销、保存失败重试和尺寸调试。

设计见 [工作台设计](../../docs/workbench.md)，测试与真机验证边界见 [跨端验证](../../tests/README.md)。
