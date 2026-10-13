# Thinktin-Rust

ThinkTin 平台的 Rust 代码，cargo workspace 结构，各 crate 的职责见 [架构方案 v2 第 8 节](docs/architecture-v2.md)。

| crate | 类型 | 职责 |
| --- | --- | --- |
| proto | lib | 共享协议与类型 |
| gateway | bin | 接入网关 |
| control | bin | 控制服务 |
| catalog | lib | Agent 目录 |
| agent-shim | bin | 沙箱内守护进程 |
| llm-gw | bin | 模型网关 |
| keyvault | lib | 密钥库 |
| sandbox | lib | 沙箱抽象 |
| relay | bin | 设备中继 |
| desktop | bin | 电脑端守护进程 |
| client-core | lib | 客户端共享核心 |

文档：[架构方案 v2](docs/architecture-v2.md) · [讨论记录 2026-10-14](docs/discussion-2026-10-14.md)
