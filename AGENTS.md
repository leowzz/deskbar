# Desklet

- 当前已实现第一版双端连接，业务工作台仍在开发中。先读 [README.md](README.md)；实现任务再读对应设计和 [开发计划](docs/roadmap.md)。术语以 [CONTEXT.md](CONTEXT.md) 为准。
- 产品系列名使用 Desklet，电脑端显示名为「Desklet 连接助手」，移动端为「Desklet 工作台」。用户说明和设计文档默认简体中文，代码与技术标识使用英文。
- 视觉实现以 [DESIGN.md](DESIGN.md) 为准：01 铂银为默认浅色，02 墨黑为暗色；其余原型配色仅供历史参考。
- 桌面沿用 Tauri / React / Rust，Android 沿用 Flutter / Kotlin。不要因通用脚手架默认值增加中心服务或另一套后端。
- LAN、状态与执行约束以 [协议草案](docs/protocol.md) 为准；页面与组件行为以 [工作台设计](docs/workbench.md) 为准。协议在实现前仍是草案。
- 从 Orbit 提取代码时移除运行依赖；来源与归属见 [架构](docs/architecture.md)。保留其他人的改动，不顺带修改 Orbit。
- 修改实现时同步受影响文档；完成时运行与变更相称的检查。文档改动运行 `make check`，并说明哪些验证仍未完成。
