# Android Workbench

Flutter + Kotlin 的独立 Android App，标识 `app.desklet.workbench`，最低 Android 9。当前支持扫码 / 粘贴完整邀请、等待电脑确认、连接状态、搜索附近电脑、前台恢复重连和断开电脑；工作台业务组件尚未加入。

从根目录运行 `make setup`，再运行 `make android ANDROID_DEVICE=<设备序列号>`。`make android-build` 构建开发 APK。生产签名未配置，不能把 debug APK 当作发布版本。

Kotlin `ConnectionRuntime` 经 MethodChannel / EventChannel 管理固定 SPKI 的 OkHttp HTTPS / WSS、IPv4 发现与重连。设备凭据经 Android Keystore 的 AES-GCM 密钥加密，备份关闭，不存到 Flutter 配置。暂停 Activity 时停止连接，恢复时重连；不使用后台常驻服务。

摄像头不是必需硬件。无法扫码时可粘贴完整邀请，短码 PAKE 尚未实现。已在 Android 12 模拟器运行原生跨端测试；物理设备、扫码相机、Android 9 与新版权限、大字号和系统回收仍需现场验证。

页面设计见 [工作台设计](../../docs/workbench.md)，测试方法见 [跨端验证](../../tests/README.md)。

界面遵循 [RawBlock 规范](../../DESIGN.md)，主题集中在 `lib/rawblock.dart`。采用白底黑字、3 / 5 dp 边框、直角与文字按钮，字体位于 `assets/fonts` 并保留 OFL 许可；中文使用系统字体回退。大字号允许标题和内容换行，配对及断开弹窗可滚动。
