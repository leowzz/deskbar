# Desklet

Desklet 把 Android 屏幕变成电脑旁的工作台。电脑安装 **Desklet 连接助手**（Agent），Android 安装 **Desklet 工作台**，通过局域网配对连接。目标是显示会话、额度与 API 用量，并打开已授权的会话和快捷入口。

**当前阶段：连接与配对的第一版实现。** 已有独立的 macOS 桌面 Agent 和 Android App，支持局域网发现、扫码或粘贴完整邀请、电脑确认、加密直连、自动重连和移除设备。配对后目前只显示电脑连接状态；会话、额度、API 用量、快捷入口和页面编辑尚未接入。

短配对码依赖的 PAKE、多网卡与网络变化、物理设备适配、签名安装与发布仍在开发计划中。当前构建是开发版本。

## 产品范围

- 一个桌面安装包，加一个 Android 安装包；无需部署 Core、MQTT Broker 或独立服务器。
- 会话、额度、API 用量和快捷入口均作为可选组件，支持同类组件重复添加。
- 页面自由组合组件，左右横滑切页；每个实例独立设置位置、区域尺寸和显示参数。
- Session 卡片可调整目标宽高与间距；快捷入口可调整图标大小和横纵间距，也可铺满整页。
- 配对绑定稳定主机身份与公钥，IP 变化后重新发现并核验原身份。

产品系列名使用 **Desklet**，仓库名使用 `desklet`。电脑端对外名称为 **Desklet 连接助手**，移动端为 **Desklet 工作台**。应用标识、协议身份和配置目录保持不变。

## 从这里开始

| 文档 | 内容 |
| --- | --- |
| [视觉规范](DESIGN.md) | RawBlock 黑白、粗边框、直角和字体规范 |
| [产品范围](docs/product.md) | 用户任务、首版能力和交付边界 |
| [架构](docs/architecture.md) | 双端结构、模块接口、配置归属和代码提取路径 |
| [LAN 协议草案](docs/protocol.md) | 发现、IP 变化、配对、同步和动作语义 |
| [页面与组件](docs/workbench.md) | 页面管理、实例参数、手势和本机保存 |
| [领域术语](CONTEXT.md) | Host、Agent、Page、Widget 等统一含义 |
| [开发计划](docs/roadmap.md) | 分阶段产物、验收条件和待验证项 |
| [LocalSend 研究](docs/research/localsend-discovery.md) | 固定版本源码分析与可借鉴部分 |
| [交互原型](docs/prototypes/workbench.html) | 示例数据；仅内存状态；不连接设备 |

## 运行开发版本

需要 Rust（1.89+）、Node.js（22+）、pnpm 11、Flutter 3.44 / Dart 3.12，以及对应平台构建工具。桌面目前在 macOS 验证；Android 最低版本为 Android 9（API 28）。依赖已提交锁文件。

```sh
make setup           # 安装桌面与 Flutter 依赖
make dev             # 打开 Desklet 连接助手，关闭窗口后仍在菜单栏运行
make android         # 在指定 Android 设备运行，先设置 ANDROID_DEVICE
make check           # 文档、格式、Rust 测试、桌面类型与 Flutter 检查
make android-build   # 生成开发 APK，不是签名发布版本
make prototype       # 保留原 HTML 布局原型预览
```

`make android ANDROID_DEVICE=<设备序列号>` 用于选择运行设备。Android 开发 APK 位于 `apps/android/build/app/outputs/flutter-apk/app-debug.apk`。

两端连接同一 Wi-Fi，在电脑上点击「连接设备」，再在 Android 的「Desklet 工作台」中扫码。没有摄像头时，复制完整邀请并在 Android 点击「粘贴邀请」；最后回到电脑允许连接。邀请两分钟过期，只能配对一台设备。电脑可随时移除已配对设备。

工作台 App 退到后台时暂停连接，回到前台后重新同步。自动发现不可用时仍可扫码或粘贴邀请；访客网络隔离和防火墙仍可能阻止直连。启动遇到配置或钥匙串访问问题时会显示提示，处理后退出重开。

验证范围和可重复运行的跨端测试见 [tests/README.md](tests/README.md)。

## 目录

```text
apps/
  desktop/       Tauri + React / Rust Agent
  android/       Flutter + Kotlin 连接界面
crates/
  host/          身份、配对授权与最小快照
  lan/           TLS 监听、认证连接与发现
protocol/        后续的版本化 Schema 与跨语言消息样例
docs/            设计、研究和单文件原型
tests/           跨端测试说明
release/         后续的打包、签名和更新配置
scripts/         文档检查与跨端测试脚本
```

技术栈沿用已确定的 Tauri、React、Rust、Flutter 和 Kotlin。桌面前端使用 pnpm；依赖版本由锁文件固定。连接界面与原生连接已经实现，业务组件仍按开发计划推进。

## 开发约定

修改功能前阅读对应设计；行为发生变化时同步更新文档。实现范围以开发计划中的当前阶段为准。业务通信走 HTTPS / WSS，发现消息只提供地址线索。组件显示偏好不能更改配对授权或远程动作的执行电脑。
