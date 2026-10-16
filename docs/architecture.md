# Desklet 架构

状态：连接、Codex / Sub2API 来源、设备许可、有限打开动作和 Android 多页组件编辑已实现。2026-10-16。

## 双端直连

桌面 Agent 同时承载本机状态、设备授权、LAN 监听和有限动作执行。Android 承载工作台、来源选择、页面与组件偏好。

```mermaid
flowchart LR
  Providers[本机采集] --> Host[HostRuntime]
  Host --> Gateway[LAN Gateway]
  Android[Android Workbench] -->|HTTPS 请求| Gateway
  Gateway -->|WSS 快照与结果| Android
  Host -->|授权与资源校验后| Executor[本机执行器]
  Executor -->|执行结果| Host
  Pages[Android 本机页面配置] --> Android
```

HostRuntime 与 LAN Gateway 嵌入桌面进程；关闭设置窗口后可继续在托盘运行。没有独立部署的 Core 或 Broker。

## 技术栈

| 部分 | 选择 | 原因 |
| --- | --- | --- |
| 桌面外壳 | Tauri + React / TypeScript | 复用现有设置、托盘与平台能力 |
| 本机运行时与 LAN | Rust | 复用现有采集与执行，统一网络实现 |
| Android 展示 | Flutter / Dart | 复用工作台、点阵、主题与适配 |
| Android 原生能力 | Kotlin + OkHttp | 连接生命周期、安全存储和系统组件 |
| 通信 | HTTPS + WSS + JSON | 快照、命令与结果共享一个 TLS 监听端口 |
| 桌面前端工具 | pnpm | 在创建可构建工程时提交对应锁文件 |

首批来源复用 Codex 会话与额度采集，以及 Sub2API 用量采集。依赖版本、Android 目标版本和打包标识在连接原型阶段落定。复杂的非敏感配置使用结构化 YAML；密钥和令牌存系统安全存储，不写进配置或仓库。

## 四个核心模块

| 模块 | 对调用者提供的接口 | 内部实现 |
| --- | --- | --- |
| HostRuntime | 取得某设备可见的状态；执行该设备的有限动作 | 采集调度、快照、新鲜度、隐私裁剪、授权、校验、命令去重与执行 |
| LAN Session | 配对、连接、订阅、提交动作、断开 | 发现、TLS、公钥固定、凭据、重连、心跳与版本协商 |
| WorkbenchStore | 展示状态、选择来源、打开会话与入口 | 缓存、来源绑定、错误映射、稳定资源身份与原生桥接 |
| LayoutWorkspace | 管理页面与组件、开始编辑、提交或取消、解析当前页 | 网格约束、参数、横竖屏摆放、撤销、草稿与本机保存 |

Tauri 负责装配运行时、设置、托盘、登录启动和更新；HostRuntime 不依赖窗口。WorkbenchScreen 不依赖 Orbit 的 InboxController。网络层不感知页面尺寸。

## 配置与数据归属

**Host 持有：** Codex / API 用量来源配置及凭据、本机应用路径与 URL、快捷入口定义、共享字段和各设备许可。每次执行重新校验，删除入口或撤销许可立即生效。

**Android 持有：** 已配对 Host、来源选择、会话分组、入口显示顺序、页面列表、各实例参数与摆放、配色、常亮与显示偏好。绑定保存稳定 ID，不保存执行路径或依赖 IP 的引用。

Host 的连接状态、Source 的新鲜度和页面的可见性相互独立。多个组件使用同一 Source 时合并订阅；隐藏组件不能关闭其他设备仍在使用的来源。

## Android 生命周期

Flutter 负责页面和组件渲染。Kotlin ConnectionRuntime 统一管理发现、TLS 固定、网络切换与快照持久化，经 EventChannel / MethodChannel 给 Flutter 提供状态与动作接口。发现模块可通过 JNI 复用 Rust，具体桥接方案需要验证。

Android 系统桌面组件读取同一个原生快照存储，避免另建连接。普通模式退出前台后允许暂停，恢复前台立即同步；用户显式开启桌面屏模式时，Activity 可见期间保持连接与常亮。

App 不可见时持续刷新需要单独验证前台服务、通知和平台要求。权限拒绝、息屏、系统回收和新 Android 局域网权限都属于真机验收范围。

## 从 Orbit 提取

来源仓库为 `orbit`，下表是提取路径，不是本仓库的运行依赖。

| 原路径或模块 | 提取方式 |
| --- | --- |
| `agents/desktop` | 复用 Tauri 外壳与设置；连接设置换为配对与设备许可 |
| `codex.rs`、`usage.rs` | 复用采集规则，改用 Desklet 领域类型 |
| `commands.rs`、`shortcuts.rs` | 复用资源校验与本机打开能力，替换授权与命令信封 |
| `runtime.rs` | 保留采集调度；MQTT 状态机替换为 LAN 监听与会话管理 |
| `nodes/app` | 复用工作台、点阵、主题和适配；移除 InboxController 依赖 |
| `nodes/android` | 复用原生全屏、组件与设备适配；迁入独立 Android 工程 |
| Core 的新鲜度与隐私裁剪规则 | 保留行为与关键用例，迁到 HostRuntime |

不整体复制 Orbit wire / Protobuf 协议、收件箱和 Core Console。首次提取允许复制成熟实现；出现实际共享变化后再决定公共库。

## 独立产品约束

Desklet 使用独立的 Android applicationId、桌面 bundle ID、配置目录、设备身份、签名和更新通道，可与 Orbit 并存。当前标识为 `app.desklet.agent` 与 `app.desklet.workbench`。

平台差异通过 Adapter 隔开：应用发现、打开应用、安全存储、登录启动与来源采集。首版按实际需求实现，不预建通用插件框架。

macOS 安装路径需验证签名、公证与本地网络授权。Windows 需验证签名安装包、防火墙、凭据存储和 Codex 发现 / 深链。复用源代码不能代替对应平台的真机证据。

## 详细契约

- [LAN 协议](protocol.md)：身份与地址、发现、配对、同步及动作语义。
- [工作台](workbench.md)：页面、组件参数、手势和本机存储。
- [开发计划](roadmap.md)：实现顺序与验收条件。

## 当前代码边界

- `crates/host`：稳定身份、设备审批、邀请有效期、凭据摘要、撤权、Codex 只读采集与额度适配、快照裁剪、入口目录和动作去重；不依赖窗口或 LAN。磁盘锁防止重复进程覆盖配置。
- `crates/lan`：嵌入式 TLS 监听、设备认证、WSS、发现、邀请 URI、来源调度与有界 OS 打开执行；没有单独部署的服务。桌面启动时从系统钥匙串读取 TLS 私钥，证书续签保持原 SPKI。
- `apps/desktop`：React 设备与共享管理、来源健康 / 额度、入口编辑与原生应用选择器、Tauri 托盘；关闭窗口继续运行，菜单栏可打开或退出。启动失败时保留窗口显示可操作提示。
- `apps/android`：Flutter 工作台；`WorkbenchData` 解析授权状态，`Connection` 提供来源和有限动作。Kotlin 管理 HTTPS / WSS、发现、Keystore 加密凭据 / 快照、动作提交和结果查询。普通断线保留上次数据，来源失效或离线禁用会话打开；撤销共享会替换并清除对应缓存。

Codex 数据库和 app-server 读取、Sub2API 登录 / 续期 / 聚合指标、深链、入口校验及 macOS 应用图标取得参考 Orbit 的成熟规则，已改用 Desklet 自有类型；没有 Orbit 运行依赖、额外后端、MQTT 或共享插件框架。Sub2API 配置归 Host，密码存独立钥匙串条目；账号变更清除旧值并丢弃在途旧账号响应。

Android `LayoutWorkspace` 使用不可变文档管理全页面草稿、历史和双方向网格校验，临时选中 / 铺满不参与保存。`LayoutRepository` 经串行队列在 App 私有目录写临时文件后原子替换，保留有效副本和旧配置 / 损坏原文件；未来版本禁止降级覆盖。`WorkbenchCanvas` 将文档绑定到单个 `Connection` 的授权快照，同源多个实例复用一条 WSS，按稳定 Host / 来源 / 资源筛选。页面滚动通过实例 ID 保留，非当前页由按需 PageView 构建。

快捷图标由 `crates/lan/src/icons.rs` 调用 NSWorkspace 取得应用 / 系统网页图标，经 sips 缩放和 PNG 重编码后交给 Host 校验与保存；快照只共享受限像素数据。Android 在解析快照时缓存图标字节，按实例图标尺寸本地渲染，不读取电脑路径或另行请求网站。显示偏好由独立 `DisplayPreferences` 和原生 Activity 管理，页面布局不直接修改系统方向或沉浸状态。
