# Protocol

当前实现契约见 [协议 v1 连接子集](../docs/protocol.md#v1-连接实现子集)，[消息样例](v1.examples.json) 包含发现、快照和撤权。完整工作台与动作协议仍是草案。

当前没有代码生成或已冻结的 JSON Schema。跨端连接测试直接验证 Rust 与 Kotlin / Flutter 的兼容；后续在协议冻结时补入 Schema 与生成类型的一致性检查。不能把样例当作完整校验器。
