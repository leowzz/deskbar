# DeskBar

DeskBar 让 Android 工作台与用户电脑在局域网内配对并协作。以下术语区分设备、连接、数据和页面组成。

## Language

**Host**：提供数据和执行动作的来源电脑。它的身份独立于当前网络地址。
_Avoid_：服务端 IP、中心服务器。

**Agent**：安装在 Host 上的桌面程序，对外名称为「DeskBar 连接助手」，代表这台电脑提供已授权能力。

**Workbench**：Android App 内承载页面、组件和操作入口的工作台；移动端应用对外名称为「DeskBar 工作台」。
_Avoid_：Core Console。

**Pairing**：用户将工作台与某台 Host 建立持久信任，并授予指定能力的过程。
_Avoid_：发现成功、连上同一个 Wi-Fi。

**Endpoint**：某台 Host 的一个候选连接地址。同一 Host 可以同时或先后拥有多个 Endpoint。
_Avoid_：设备身份。

**Source**：提供某类状态的数据来源，例如会话、账号额度或 API 用量。来源的健康与新鲜度独立于 Host 是否在线。

**Session**：可在来源电脑上继续打开的任务会话。
_Avoid_：LAN 连接、网络会话。

**Shortcut**：用户在执行设备上定义的应用、网址或其他受限操作入口。

**Page**：工作台内有名称和顺序的组件容器。页面没有类型，可包含任意组件实例。
_Avoid_：布局预设、固定模式。

**Widget**：页面中的一个组件实例，拥有独立的数据绑定、摆放和显示参数。同类组件可以有多个实例。
_Avoid_：单例区域、Android 系统桌面组件。

**Placement**：某组件在指定显示方向下的位置和区域尺寸。

**Widget options**：某实例的显示参数，例如卡片目标宽高、图标大小和间距。

**Shortcut widget**：承载快捷入口的组件，可缩成一行或铺满页面。
_Avoid_：导航栏，容易与页面切换入口混淆。

**Command**：工作台向已授权 Host 提交的一次有限动作请求。

**Snapshot**：Host 在某一版本下对指定设备可见的完整状态。
