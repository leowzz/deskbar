# DeskBar 连接助手

Tauri + React / TypeScript + Rust 的独立 macOS 连接应用。界面负责连接邀请、设备许可、快捷入口和 Sub2API 账号设置；Agent 采集 Codex 会话 / 额度与 API 用量，校验并执行有限打开动作。托盘负责窗口打开与退出，关闭窗口保留后台连接。

从仓库根目录运行 `make setup`、`make dev`。`pnpm --dir apps/desktop run build` 检查并构建前端，`cargo check -p deskbar-desktop` 检查原生工程。完整开发构建可用 `pnpm --dir apps/desktop run tauri build --debug --no-bundle`；正式签名、公证和安装包在发布阶段实现。

监听与配对由 [LAN](../../crates/lan/README.md) 承担，稳定身份和授权由 [HostRuntime](../../crates/host/README.md) 承担。React 不持有 TLS 私钥或设备令牌；邀请只在临时界面状态中展示。配置保存在独立应用目录，TLS 私钥使用系统钥匙串。

浏览器运行 `pnpm --dir apps/desktop run dev` 只能检查界面，不能启动 Agent；界面会明确提示使用桌面应用。没有浏览器伪装在线或内置示例数据。

界面遵循 [视觉规范](../../DESIGN.md)：默认铂银、暗色墨黑、系统无衬线字体、细边框和适度圆角。主题在应用设置中立即切换并保存在本机，原生窗口主题与背景同步。账号密码只传入 Rust 并保存到系统钥匙串，不写入前端存储或 Android 快照。
