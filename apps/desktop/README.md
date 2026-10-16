# DeskBar 连接助手

Tauri + React / TypeScript + Rust 的独立 macOS 连接应用。界面负责连接邀请、设备许可、屏幕编辑与实时预览、快捷入口和 Sub2API 账号设置；Agent 采集 Codex 会话 / 额度与 API 用量，校验并执行有限打开动作。托盘负责窗口打开与退出，关闭窗口保留后台连接。

从仓库根目录运行 `make setup`、`make dev`。`pnpm --dir apps/desktop run build` 检查并构建前端，`cargo check -p deskbar-desktop` 检查原生工程。完整开发构建可用 `pnpm --dir apps/desktop run tauri build --debug --no-bundle`；正式签名、公证和安装包在发布阶段实现。

监听与配对由 [LAN](../../crates/lan/README.md) 承担，稳定身份和授权由 [HostRuntime](../../crates/host/README.md) 承担。React 不持有 TLS 私钥或设备令牌；邀请只在临时界面状态中展示。配置保存在独立应用目录，TLS 私钥与 API 密码单独保存在 `credentials/store.json`；macOS / Linux 凭据目录为 `0700`、文件为 `0600`，使用临时文件原子替换，不额外加密。已有安装首次导入钥匙串，保留原公钥和配对；成功后重启不再访问钥匙串。

浏览器运行 `pnpm --dir apps/desktop run dev` 只能检查界面，不能启动 Agent；界面会明确提示使用桌面应用。没有浏览器伪装在线或内置示例数据。

界面遵循 [视觉规范](../../DESIGN.md)：默认铂银、暗色墨黑、系统无衬线字体、细边框和适度圆角。主题在应用设置中立即切换并保存在本机，原生窗口主题与背景同步。账号密码只传入 Rust 并保存到本机凭据文件，不写入前端存储或 Android 快照。

「屏幕编辑」嵌入共享的 Flutter Web 渲染器。桌面 dev / build 会先运行 `scripts/build_editor.sh`，需要 Flutter SDK；资源、CanvasKit 和中文字体随安装包分发。更改 Dart 编辑器后重新运行构建；浏览器测试需显式测试桥接，生产无模拟数据。布局变更停止操作约 450ms 后自动写入电脑的设备记录并推送给设备；编辑期间可以继续修改，失败时保留当前改动。

组件直接点击编辑，整块区域拖动，属性表单独立于渲染区：目标竖屏时在右侧，横屏时在下方。切换方向保留选择和当前改动，横竖屏摆放独立。
