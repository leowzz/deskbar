# Desklet 连接助手

Tauri + React / TypeScript + Rust 的独立 macOS 连接应用。界面负责连接邀请、设备确认和移除，托盘负责窗口打开与退出；关闭窗口保留后台连接。当前没有采集或打开会话的能力。

从仓库根目录运行 `make setup`、`make dev`。`pnpm --dir apps/desktop run build` 检查并构建前端，`cargo check -p desklet-desktop` 检查原生工程。完整开发构建可用 `pnpm --dir apps/desktop run tauri build --debug --no-bundle`；正式签名、公证和安装包在发布阶段实现。

监听与配对由 [LAN](../../crates/lan/README.md) 承担，稳定身份和授权由 [HostRuntime](../../crates/host/README.md) 承担。React 不持有 TLS 私钥或设备令牌；邀请只在临时界面状态中展示。配置保存在独立应用目录，TLS 私钥使用系统钥匙串。

浏览器运行 `pnpm --dir apps/desktop run dev` 只能检查界面，不能启动 Agent；界面会明确提示使用桌面应用。没有浏览器伪装在线或内置示例数据。

界面遵循 [RawBlock 规范](../../DESIGN.md)：黑白配色、3 / 5 px 边框、直角、文字按钮与无阴影弹窗；标题使用 Archivo Black，正文使用 Work Sans，连接信息使用 Space Mono，字体随应用打包。原生窗口、启动背景与安装图标使用同一黑白体系。
