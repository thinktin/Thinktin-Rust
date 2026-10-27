# 密钥与日志审计（WBS 15.4）、租户隔离测试（WBS 15.2）

> 记录用户的厂商 key、沙箱令牌、登录令牌在系统里经过哪些地方，靠什么保证不泄露，哪些检查是自动化的，还剩哪些已知的残留。代码变了要同步更新。

## 1. 厂商 key（用户自带的 LLM key）

| 环节 | 形态 | 保护 |
|---|---|---|
| 客户端 → 接入网关 | HTTPS 请求体里的明文 | 只在 `POST /v1/credentials`、`PUT /v1/credentials/{id}/secret` 出现；接口返回值只有后 4 位 |
| 接入网关 | 反序列化后的字符串 | 立即放进 `Zeroizing` / `SecretString`，用用户的 DEK 加密后丢弃；审计日志只记厂商和后 4 位 |
| 数据库 | AES-256-GCM 密文（AAD 绑定用户和记录 id） | 用户 DEK 由 KMS 主密钥包裹；业务角色只能读到自己的行（RLS），没有 DEK 和主密钥解不开 |
| 模型网关 | 解密后的 `SecretString` | 只在换鉴权头时取出；DEK 在内存里短时缓存（`Zeroizing`）；用户注销后读不到 DEK |
| 上游请求 | `Authorization` / `x-api-key` 头 | 只发往厂商适配表里的地址或用户自定义的 https 地址（SSRF 防护）；上游错误响应里回显的 key 会被抹掉 |
| 沙箱 | **不进入** | 沙箱里只有短期沙箱令牌（环境变量），agent 的配置文件里只写环境变量引用 |

## 1.1 IM 群机器人的凭证（10.5）

| 环节 | 形态 | 保护 |
|---|---|---|
| 客户端 → 接入网关 | HTTPS 请求体里的 webhook 地址和签名密钥 | 只在 `POST /v1/im-channels`、`PUT /v1/im-channels/{id}/webhook` 出现；地址只认官方前缀，只留 token；返回值和审计只有平台和 token 后 4 位 |
| 数据库 | AES-256-GCM 密文（单独的域 `thinktin/im/v1/`，AAD 绑定用户和渠道 id） | 同模型 key；出箱条目里只有渠道 id，不带凭证 |
| 后台发送 | 解密后的 token、密钥（`Zeroizing`） | 发送时才解开；地址按固定前缀拼，不跟随重定向；网络错误、日志里去掉地址；记下的失败原因是自己写的，不照抄对方的错误信息 |

详见 [IM 渠道](im-channels.md)。

## 2. 令牌

| 令牌 | 去处 | 保护 |
|---|---|---|
| 沙箱令牌（`tts1.`） | 控制面签发 → 环境变量交给 agent-shim → agent 用它调模型网关 | 不进命令行参数、不落盘；日志里只出现打码形式（`tts1.<kid>.***`）；绑定实例、沙箱、运行授权，沙箱换了或授权吊销即失效 |
| 访问令牌（`tta1.`） | 客户端内存 | 15 分钟有效，每次请求核对会话 |
| 刷新令牌 | 客户端系统安全存储（Keychain / Keystore，经 `SessionStore`） | 库里只存哈希；轮换，旧令牌重用即吊销整个会话 |

## 3. 自动化检查

| 检查 | 位置 |
|---|---|
| 主链路跑完后：厂商 key 不在沙箱目录的任何文件里；沙箱令牌没有落盘；全程日志（debug 级别）里没有厂商 key，令牌只有打码形式 | `crates/e2e/tests/main_chain.rs` |
| 厂商收到的是用户的 key 和真实模型名，agent 只知道别名和沙箱令牌 | 同上 |
| shim 的子进程环境只有白名单变量和沙箱令牌 | `crates/agent-shim/tests/shim.rs`（`env` 用例） |
| 含密钥的配置、会话、请求结构的调试输出不含密钥 | `server::config` 的 `debug_output_hides_secrets`；`Session`、`NewCredential`、`ModelRouting`、`ApiSecrets`、`Tokens`、`SealedCredential`、`ShimLaunch`、`WebhookSecret`、`ImHook`、`NewImChannel`、`SealedImChannel` 都手写了打码的 `Debug` |
| 网关把上游错误里回显的 key 抹掉 | `crates/llm-gw/tests/gateway.rs` |
| 业务角色能碰到的、带 `user_id` 的表全部开了 RLS 并有策略；业务角色不能绕过 RLS（新加表忘了开会失败） | `crates/store/src/tests.rs` 的 `every_tenant_table_the_app_can_touch_has_rls` |
| 跨用户访问：别人的实例、运行、计划、触发器、审批、key、IM 渠道、团队、模板、产出物、收件箱，按 id 读改删和各种操作都返回 404，列表看不到，事件流连不上，原主人的数据不受影响 | `crates/gateway/tests/api.rs` 的 `other_users_objects_are_invisible` |
| 模型网关：别人的实例、换掉的沙箱、吊销或收窄的授权、注销的账号都用不了 key | `crates/llm-gw/tests/pg.rs` |

## 4. 已知残留

- **请求体缓冲**：接入网关收到的 HTTP 请求体（含明文 key）由 hyper 分配，处理完释放但不清零。缓解：只有存 key 的两个接口会出现；部署时要禁用 core dump，进程内存不落盘。
- **上游请求头**：`reqwest` / `http` 的 `HeaderValue` 不支持清零，key 在发送期间会在其内部缓冲里出现。
- **TLS 缓冲**：rustls 的明文缓冲区不清零。
- **客户端**：key 在 App 输入框和 client-core 的请求 JSON 里短暂存在，不缓存、不落盘。
- 以上都要求攻击者能读进程内存；对策是最小化进程权限和 core dump、不在这些进程里跑第三方代码。
