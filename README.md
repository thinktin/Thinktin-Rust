# Thinktin-Rust

ThinkTin 平台：托管多个开源 agent，用户领养后常驻云端、按计划执行、可多 agent 协同。服务端和客户端核心用 Rust，iOS、macOS、Android 用原生开发。

## 文档

- [架构方案 v3](docs/architecture-v3.md)（当前版本）
- [Agent 接入说明](docs/agent-integration.md)：Claude（ACP 与命令行两种接入）、Codex、Pi、OpenClaw、Hermes 的接入状态、配置注入、权限审批和已知问题
- [模型网关与密钥库](docs/llm-gateway.md)：沙箱令牌、信封加密、按别名路由换 key、流式透传、计量、限额、SSRF 防护
- [工作分解结构（WBS）](docs/wbs.md) · [CSV](docs/wbs.csv)
- [架构方案 v2](docs/architecture-v2.md) · [讨论记录 2026-10-14](docs/discussion-2026-10-14.md)

## 代码结构

| crate | 类型 | 职责 |
| --- | --- | --- |
| proto | lib | 共享协议与类型：领域类型、平台 ↔ shim 的指令和事件、接口版本协商与错误模型 |
| store | lib | 数据访问层：迁移、按角色开启的事务（业务角色受行级安全约束）、各表仓储 |
| auth | lib | 账号、设备会话、运行授权、沙箱令牌 |
| gateway | lib | 接入网关、事件流续传 |
| control | lib | 实例生命周期、沙箱暂停与唤醒 |
| orchestrator | lib | 计划、触发器、运行树、多 agent 协同 |
| notify | lib | APNs、FCM、国内厂商推送、IM 渠道 |
| catalog | lib | Agent 目录：清单格式、校验、内置清单（`crates/catalog/manifests`） |
| sandbox | lib | 沙箱抽象（CubeSandbox） |
| keyvault | lib | 密钥库：按用户 DEK 的信封加密 |
| server | bin | 控制面主程序 `thinktin-server`（模块化单体）：配置、健康检查、优雅停机 |
| llm-gw | bin | 模型网关：沙箱令牌换用户 key、流式透传、计量、限额 |
| relay | bin | 设备中继 |
| agent-shim | bin | 沙箱内守护进程：驱动 agent（ACP、Claude Code stream-json）、配置注入、审批转发 |
| desktop | lib | 电脑端 MCP 工具服务（供 macOS App 调用） |
| client-core | lib | 客户端共享核心（UniFFI） |

原生客户端在 `apps/apple`（iOS + macOS）和 `apps/android`。

## 开发工具

- `tools/dev/setup-db.sh`：起本机的 PostgreSQL 16 和 Redis，建开发用账号。之后
  `export DATABASE_URL=postgres://thinktin_dev:thinktin_dev@127.0.0.1:5432/postgres`，
  store、server 的测试每个测试建一个新库（没设置 DATABASE_URL 时跳过，设 `THINKTIN_REQUIRE_DB=1` 则改为失败）。
- `thinktin-server [--config server.toml] [serve|migrate|check-config]`：本地运行控制面。
  配置项见 `crates/server/src/config.rs`；`DATABASE_URL`、`THINKTIN_LISTEN`、`THINKTIN_NODE_ID` 覆盖配置文件。

- `tools/mock-llm/mock_llm.py`：模型网关的本地替身，供真实 agent 的冒烟测试使用。
- `tools/smoke/smoke.sh <agent>`：经 agent-shim 用真实 agent 跑一轮并检查结果，`GW=1` 时走真实的模型网关；`tools/smoke/serve_check.py <agent>` 检查常驻模式下的取消。见[接入说明](docs/agent-integration.md#9-本地运行)。
