# Thinktin-Rust

ThinkTin 平台：托管多个开源 agent，用户领养后常驻云端、按计划执行、可多 agent 协同。服务端和客户端核心用 Rust，iOS、macOS、Android 用原生开发。

## 文档

- [架构方案 v3](docs/architecture-v3.md)（当前版本）
- [工作分解结构（WBS）](docs/wbs.md) · [CSV](docs/wbs.csv)
- [架构方案 v2](docs/architecture-v2.md) · [讨论记录 2026-10-14](docs/discussion-2026-10-14.md)

## 代码结构

| crate | 类型 | 职责 |
| --- | --- | --- |
| proto | lib | 共享协议与类型 |
| store | lib | 数据访问层、数据库迁移 |
| auth | lib | 账号、设备会话、运行授权 |
| gateway | lib | 接入网关、事件流续传 |
| control | lib | 实例生命周期、沙箱暂停与唤醒 |
| orchestrator | lib | 计划、触发器、运行树、多 agent 协同 |
| notify | lib | APNs、FCM、国内厂商推送、IM 渠道 |
| catalog | lib | Agent 目录 |
| sandbox | lib | 沙箱抽象（CubeSandbox） |
| keyvault | lib | 密钥库 |
| server | bin | 控制面主程序（模块化单体） |
| llm-gw | bin | 模型网关 |
| relay | bin | 设备中继 |
| agent-shim | bin | 沙箱内守护进程 |
| desktop | lib | 电脑端 MCP 工具服务（供 macOS App 调用） |
| client-core | lib | 客户端共享核心（UniFFI） |

原生客户端在 `apps/apple`（iOS + macOS）和 `apps/android`。
