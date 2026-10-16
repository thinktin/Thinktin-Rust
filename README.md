# Thinktin-Rust

ThinkTin 平台：托管多个开源 agent，用户领养后常驻云端、按计划执行、可多 agent 协同。服务端和客户端核心用 Rust，iOS、macOS、Android 用原生开发。

## 文档

- [架构方案 v3](docs/architecture-v3.md)（当前版本）
- [Agent 接入说明](docs/agent-integration.md)：Claude（ACP 与命令行两种接入）、Codex、Pi、OpenClaw、Hermes 的接入状态、配置注入、权限审批和已知问题
- [模型网关与密钥库](docs/llm-gateway.md)：沙箱令牌、信封加密、按别名路由换 key、流式透传、计量、限额、SSRF 防护
- [设备中继](docs/relay.md)：电脑的长连接、电脑工具调用按会话绑定路由、手机和电脑之间的配对审批消息、部署
- [工作分解结构（WBS）](docs/wbs.md) · [CSV](docs/wbs.csv)
- [架构方案 v2](docs/architecture-v2.md) · [讨论记录 2026-10-14](docs/discussion-2026-10-14.md)

## 代码结构

| crate | 类型 | 职责 |
| --- | --- | --- |
| proto | lib | 共享协议与类型：领域类型、平台 ↔ shim 的指令和事件、接口版本协商与错误模型 |
| store | lib | 数据访问层：迁移、按角色开启的事务（业务角色受行级安全约束）、各表仓储 |
| auth | lib | 账号、设备会话、运行授权、沙箱令牌 |
| gateway | lib | 接入网关：`/v1` REST 接口、实例事件流（WebSocket，按序号续传）、模型 key 管理 |
| control | lib | 实例生命周期、沙箱暂停与唤醒 |
| orchestrator | lib | 计划、触发器、运行树、多 agent 协同 |
| notify | lib | APNs、FCM、国内厂商推送、IM 渠道 |
| catalog | lib | Agent 目录：清单格式、校验、内置清单（`crates/catalog/manifests`） |
| sandbox | lib | 沙箱抽象（CubeSandbox） |
| keyvault | lib | 密钥库：按用户 DEK 的信封加密 |
| server | bin | 控制面主程序 `thinktin-server`（模块化单体）：配置、健康检查、优雅停机 |
| llm-gw | bin | 模型网关：沙箱令牌换用户 key、流式透传、计量、限额 |
| relay | bin | 设备中继 `thinktin-relay`：电脑主动连出的长连接，转电脑工具调用和手机电脑之间的消息（[说明](docs/relay.md)） |
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
  `[worker] enabled = true` 时同一进程里跑调度、流水线推进、执行、出箱投递和巡检，需要环境变量
  `THINKTIN_SANDBOX_TOKEN_SEED`（`llm-gw keygen` 生成，模型网关配对应公钥）和
  `THINKTIN_KMS_KEY`（产出物按用户 DEK 加密）；本地开发用
  `[sandbox] provider = "local"`，`manifest_override` 可以换成假 agent 的清单联调。
  `[worker] lease_secs`、`takeover_every_secs`、`retry_backoff_secs`（默认 60、15、30）决定副本被杀或宿主机宕机后
  多快有别的副本接手（见 [常驻可靠性演练](docs/reliability-drill.md)）。
  压测工具：`cargo run --release -p loadtest -- trigger-storm|wake-storm|llm-stream`（见 [压测说明](docs/loadtest.md)）。
  `[observability] metrics_listen` 打开 Prometheus 指标端口（只给内网抓取）。
  国内 Android 推送配 `[push.jpush] app_key`，Master Secret 走环境变量 `THINKTIN_JPUSH_MASTER_SECRET`；
  海外 Android 推送配 `[push.fcm] service_account_path`（Firebase 服务账号的 JSON 密钥文件）。
  产出物放在 `[storage] local_root`（默认 `.thinktin/blobs`，接口和后台任务要看到同一个目录）；
  生产用 S3 兼容的对象存储（AWS S3、阿里云 OSS、腾讯云 COS、MinIO）：`[storage] provider = "s3"`，
  `[storage.s3]` 填 `endpoint`、`region`、`bucket`（可选 `prefix`、`path_style`），访问密钥走环境变量
  `THINKTIN_S3_ACCESS_KEY_ID`、`THINKTIN_S3_SECRET_ACCESS_KEY`。
  `[api] enabled = true` 时挂上客户端接口，需要 `THINKTIN_ACCESS_TOKEN_SEED`（访问令牌签名种子）、
  `THINKTIN_CODE_PEPPER`（验证码 HMAC 密钥，十六进制）、`THINKTIN_KMS_KEY`（本地 KMS 主密钥）；
  生产的主密钥放阿里云 KMS：`[kms] provider = "aliyun"`，`[kms.aliyun]` 填 `endpoint`、`key_id`（可以是 `alias/...`），
  AccessKey 走环境变量 `THINKTIN_ALIYUN_KMS_ACCESS_KEY_ID`、`THINKTIN_ALIYUN_KMS_ACCESS_KEY_SECRET`；这时还配着
  `THINKTIN_KMS_KEY` 的话，它只用来解迁移前的老数据密钥（模型网关对应 `--aliyun-kms-endpoint`、`--aliyun-kms-key-id`）；
  短信走阿里云短信服务：`[sms.aliyun]` 填 `sign_name`、`template_code`（国内验证码模板，变量 `${code}`），
  境外号码另配 `international_sign_name`、`international_template_code`；AccessKey 走环境变量
  `THINKTIN_ALIYUN_SMS_ACCESS_KEY_ID`、`THINKTIN_ALIYUN_SMS_ACCESS_KEY_SECRET`。本地开发不配，用 `dev_sms = true` 把验证码打到标准错误。

- `thinktin-relay --database-url ... --access-key a1=<公钥>`：设备中继（独立部署）。数据库登录账号要有
  `thinktin_relay` 角色；公钥是 `thinktin-server check-config` 打印的 `access token key`。见 [设备中继](docs/relay.md)。

- `tools/client-core/`：客户端核心的绑定与打包。`gen-bindings.sh` 生成 Swift / Kotlin 绑定；
  `build-apple.sh`（macOS + Xcode）出 xcframework 和 Swift Package；`build-android.sh`（NDK + cargo-ndk）出 Android 库工程 / AAR；
  `ffi-smoke.sh` 经 C ABI 冒烟测试绑定接口。

- `tools/mock-llm/mock_llm.py`：模型网关的本地替身，供真实 agent 的冒烟测试使用。
- `tools/smoke/smoke.sh <agent>`：经 agent-shim 用真实 agent 跑一轮并检查结果，`GW=1` 时走真实的模型网关；`tools/smoke/serve_check.py <agent>` 检查常驻模式下的取消。见[接入说明](docs/agent-integration.md#9-本地运行)。
