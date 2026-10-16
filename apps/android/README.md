# Desklet 工作台

Flutter + Kotlin 的独立 Android App，标识 `app.desklet.workbench`，最低 Android 9。支持扫码 / 粘贴邀请、前台恢复重连、授权会话 / 额度 / API 用量 / 快捷入口，以及多页自由组合、重复组件、网格编辑和本机保存。

从根目录运行 `make setup`，再运行 `make android ANDROID_DEVICE=<设备序列号>`。`make android-build` 构建开发 APK。生产签名未配置，不能把 debug APK 当作发布版本。

Kotlin `ConnectionRuntime` 经 MethodChannel / EventChannel 管理固定 SPKI 的 OkHttp HTTPS / WSS、IPv4 发现与重连。设备凭据经 Android Keystore 的 AES-GCM 密钥加密，备份关闭，不存到 Flutter 配置。暂停 Activity 时停止连接，恢复时重连；不使用后台常驻服务。

摄像头不是必需硬件。无法扫码时可粘贴完整邀请，短码 PAKE 尚未实现。已在 Android 12 模拟器运行原生跨端测试；物理设备、扫码相机、Android 9 与新版权限、大字号和系统回收仍需现场验证。

页面设计见 [工作台设计](../../docs/workbench.md)，测试方法见 [跨端验证](../../tests/README.md)。`LayoutWorkspace` 管理全工作台编辑草稿和撤销历史，`LayoutRepository` 在 App 私有目录原子替换布局文件并保留恢复副本，迁移前备份旧配置。布局只含稳定资源 ID 与显示偏好，配对凭据和快照继续由 Keystore 加密。

界面遵循 [视觉规范](../../DESIGN.md)，主题集中在 `lib/rawblock.dart`：默认铂银、暗色墨黑、系统无衬线字体、细边框和圆角。主题由原生私有偏好保存；安全区、系统栏和 Material 控件随主题更新。正常模式横滑切页、纵向滚动内容；编辑模式禁用远程动作，完成保存全部草稿，取消恢复全部页面。
