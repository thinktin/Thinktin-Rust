# ThinkTin 模型网关与密钥库

> 更新日期：2026-10-14　｜　对应 WBS：9.1 信封加密、4.4 沙箱令牌、9.2 鉴权与路由、9.3 流式透传、9.4 计量、9.5 限额与熔断、9.6 SSRF 防护、9.7 厂商适配（进行中）
>
> 依据《ThinkTin 平台架构方案 v3》第 5 节和 4.6 节。

## 1. 状态

模型网关（`crates/llm-gw`）、密钥库（`crates/keyvault`）和沙箱令牌（`crates/auth` 的 `sandbox_token`）都已实现，并用真实 agent 跑通了整条链路：

```
agent（沙箱内） ──沙箱令牌──▶ llm-gw ──用户 key──▶ 厂商
      ▲                      │ 校验令牌、按别名路由、换 key
      └──── 原样流式返回 ◀────┘ 同时记录用量
```

| Agent | 协议 | 经网关实测 |
|---|---|---|
| Claude（`acp` 和 `cli` 两种接入） | Anthropic Messages（带 `?beta=true`） | 通过，含工具调用和审批（两次模型请求） |
| Codex | OpenAI Responses | 通过 |
| Pi | Chat Completions | 通过 |
| OpenClaw | Chat Completions | 通过 |
| Hermes | Chat Completions | 通过 |

每次实测都检查：厂商收到的每个请求都带用户 key、从没见过沙箱令牌；agent 用的别名被换成了上游模型；每次调用都记了用量（`GW=1 tools/smoke/smoke.sh <agent>`，见第 9 节）。

## 2. 密钥库（9.1）

- **信封加密**：每个用户一把 32 字节数据密钥（DEK），由 KMS 主密钥加密后存库。用户的 API key 用 DEK 做 AES-256-GCM 加密，随机数 12 字节放在密文前面。
- **AAD 绑定**：DEK 的 AAD 是 `thinktin/dek/<主密钥 id>/<用户 id>`；API key 的 AAD 是带长度前缀的“用户 id + 记录 id”。密文挪到别的用户或别的记录下都解不开。
- **只显示后 4 位**：`SealedSecret.last4` 只存后 4 位；key 短于 12 个字符时显示 `****`。
- **DEK 缓存**：解开的 DEK 在内存里缓存 5 分钟（可调），用 `Zeroizing` 包装。解开的 API key 用 `SecretString` 包装，一次请求用完就丢，不缓存。
- **注销即销毁**：`destroy_user_key` 删掉 DEK 并清缓存，该用户的所有密文从此无法解开。
- **KMS**：`Kms` trait，现有本地实现 `LocalKms`（开发用，主密钥从环境变量读）。云 KMS 适配随 2.6 接入。

## 3. 沙箱令牌（4.4）

格式 `tts1.<kid>.<base64url(claims)>.<base64url(Ed25519 签名)>`，签名覆盖前三段，校验用 `verify_strict`。控制面持私钥签发，网关只持公钥，按 `kid` 支持多把公钥并存（轮换）。

| 字段 | 含义 | 网关怎么核对 |
|---|---|---|
| `iid` | 实例 | 实例存在、启用 |
| `uid` | 用户 | 等于实例的所属用户 |
| `grant` | 运行授权 | 没被吊销 |
| `sbx` | 沙箱 id，每次唤醒都变 | 等于实例当前的沙箱 id，旧沙箱的令牌立即失效 |
| `net` | 沙箱的来源地址 | 等于请求的来源地址（IPv4 映射的 IPv6 按 IPv4 比较）；为空的令牌默认拒绝 |
| `iat`、`exp` | 签发、过期时间 | 允许 30 秒时钟偏差；有效期最长 7 天 |
| `jti` | 令牌 id | 只用于审计和用量记录 |

令牌可以放在 `Authorization: Bearer`、`x-api-key` 或 `api-key` 头里（各家 SDK 用法不同）。所有校验失败对 agent 都只返回“sandbox token rejected”，具体原因只写日志。

## 4. 接口（9.2、9.3）

| 路径 | 转发到厂商的 | 说明 |
|---|---|---|
| `POST /anthropic/v1/messages` | `<anthropic_base>/v1/messages` | 只放行查询参数 `beta=true` |
| `POST /anthropic/v1/messages/count_tokens` | `<anthropic_base>/v1/messages/count_tokens` | 不计量 |
| `POST /openai/v1/chat/completions` | `<openai_base>/chat/completions` | |
| `POST /openai/v1/responses` | `<openai_base>/responses` | 厂商不提供时返回 400 |
| `GET /anthropic/v1/models[/{id}]`、`GET /openai/v1/models[/{id}]` | 不转发 | 只列实例配置的别名 |
| `GET /healthz` | | |

**路由**：令牌 → 实例 → 请求体里的 `model`（别名）→ 凭证 + 上游模型。凭证必须属于实例的用户且没被停用。

**请求体只改两处**：顶层 `model` 换成上游模型；Chat Completions 流式请求没开 `stream_options.include_usage` 时替 agent 打开（第 6 节）。其余字段按原始字节、原顺序转发。顶层出现重复键直接 400，避免网关和厂商对同一请求读出不同的 `model`。

**请求头白名单**：Anthropic 协议只转发 `anthropic-version`（缺省补 `2023-06-01`）、`anthropic-beta`、`accept`、`user-agent`；OpenAI 协议只转发 `openai-beta`、`accept`、`user-agent`。agent 带的鉴权头、Cookie 等一律丢掉，换成用户 key：OpenAI 协议用 `Authorization: Bearer`，Anthropic 协议按厂商表用 `x-api-key`、`Bearer` 或两者都带。

**响应**：状态码和响应体原样流回；响应头只回 `content-type`、`retry-after`、`request-id`、`x-request-id`、`anthropic-ratelimit-*`、`x-ratelimit-*`。厂商返回非 2xx 时读完错误体（最多 1 MiB），把其中出现的用户 key 抹成 `[redacted]` 再返回。

**错误格式**：网关自己产生的错误按协议给出（Anthropic 的 `{"type":"error","error":{...}}`，OpenAI 的 `{"error":{...}}`），agent 能正常显示。

| 情况 | 状态码 |
|---|---|
| 令牌缺失或无效 | 401 |
| 别名没配置 | 404 |
| 请求体不合法、厂商不支持该协议 | 400 |
| 凭证不可用 | 403 |
| 请求体超过上限（默认 32 MiB） | 413 |
| 速率、并发超限，熔断 | 429，带 `Retry-After` |
| key 的当日预算用完 | 402（不用 429，免得 agent 反复重试） |
| 上游地址被 SSRF 防护拦截、连不上 | 502 |
| 上游超时 | 504 |

## 5. 数据模型

网关通过 `Directory` trait 读路由数据，生产环境由控制面（Postgres）提供并在本地缓存；现有内存实现和开发用的 JSON 文件（`DevStore`）。

```jsonc
{
  "kms_key_id": "dev",
  "user_keys": { "user-1": { "kms_key_id": "dev", "ciphertext": [/* 包裹后的 DEK */] } },
  "credentials": [{
    "id": "cred-1", "user_id": "user-1", "vendor": "deepseek",   // 或 "custom"，此时用下面三项
    "anthropic_base": null, "openai_base": null, "responses": false,
    "secret": { "ciphertext": [/* 随机数 + 密文 */], "last4": "a1b2" },
    "daily_token_limit": 2000000, "disabled": false
  }],
  "instances": [{
    "id": "inst-1", "user_id": "user-1", "sandbox": "sbx-1", "active": true,
    "routes": { "main": { "credential": "cred-1", "model": "deepseek-chat" } },
    "limits": { "requests_per_minute": 120, "max_concurrent": 8 }
  }],
  "revoked_grants": []
}
```

## 6. 计量（9.4）

| 协议 | 用量从哪来 |
|---|---|
| Anthropic Messages | 流式：`message_start` 的 `message.usage`，`message_delta` 的累计值覆盖；非流式：响应体 `usage` |
| Chat Completions | 带 `usage` 的分片（取最后一个）；非流式：响应体 `usage`。缓存命中取 `prompt_tokens_details.cached_tokens`，DeepSeek 取 `prompt_cache_hit_tokens` |
| Responses | `response.completed`、`response.incomplete`、`response.failed` 事件里的 `response.usage`；非流式：响应体 `usage` |

- 统一成四个数：未命中缓存的输入、缓存命中、缓存写入、输出。预算按四者之和记账。
- **补 `include_usage`**：Chat Completions 流式请求没开时网关替 agent 打开（这是透传原则唯一的例外），并在转发时去掉厂商多发的那个“`choices` 为空、只带 `usage`”的分片，agent 看到的流和没开时一样。厂商表里 `chat_stream_usage = false` 的厂商不补。
- 计量记录（`UsageRecord`）含时间、实例、用户、运行授权、沙箱、令牌 id、别名、凭证、厂商、上游模型、接口、是否流式、状态码、结果、用量、耗时，**不含请求和响应内容**。现在以结构化日志输出（target `llm_gw::usage`），用量表随 9.10 接入。
- **结果**：`complete`（读完）、`client_closed`（agent 中途断开，记下已知的用量）、`upstream_error`（上游连接出错）、`upstream_status`（上游返回非 2xx）。
- SSE 解析是增量的，任意切分都能正确处理；单个事件超过 8 MiB 就放弃取用量、照常转发。

## 7. 限额与熔断（9.5）

- **按实例限速**：令牌桶，容量和每分钟补充量都是 `requests_per_minute`（默认 120）。
- **按实例限并发**：`max_concurrent`（默认 8），许可一直持有到响应流结束。
- **熔断**：一分钟内被限速拒绝的次数达到每分钟配额（agent 无视 429 在猛打，比如死循环），就熔断 5 分钟，并输出 `llm_gw::breaker` 告警日志，供控制面通知用户。
- **按 key 每日预算**：`daily_token_limit`，按东八区切天（`--budget-utc-offset-hours` 可调）。请求前检查、响应后记账，所以同时在途的请求可能让当天用量略微超出上限。账本现在在内存里，生产放 Redis。

## 8. SSRF 防护（9.6）

用户可以给自定义端点填 base URL，网关替用户发请求，所以：

1. **静态检查**：只允许 https；URL 不能带用户名密码、查询串、片段；主机是 IP 字面量时直接检查（URL 解析器会把 `0x7f.1`、`2130706433` 这类写法规范化，绕不过去）。
2. **解析时检查**：访问厂商的 HTTP 客户端装了只返回公网地址的 DNS 解析器，任何一个解析结果不是公网地址就整体拒绝。检查过的地址就是实际连接的地址，没有“检查一次、连接时再解析一次”的 DNS 重绑定窗口。
3. **不跟随重定向**。
4. **出口代理**：配了 `--egress-proxy` 时域名由代理解析，网关只做一次预检，最终要靠代理自己的策略兜底（架构方案要求网关出网走专用出口代理）。

拦截的地址：IPv4 的本网络、私网、回环、运营商级 NAT（含阿里云元数据 100.100.100.200）、链路本地（含 169.254.169.254 等云元数据）、文档和基准测试网段、组播和保留地址；IPv6 只放行全球单播 `2000::/3`，再排除 Teredo、6to4、文档网段，IPv4 映射和 NAT64 地址按内嵌的 IPv4 判断。

## 9. 本地运行

```bash
cargo build -p llm-gw
export THINKTIN_DEV_KMS_KEY=$(python3 -c 'import secrets; print(secrets.token_hex(32))')   # 本地 KMS 主密钥
target/debug/llm-gw keygen --kid dev          # 打印 THINKTIN_DEV_TOKEN_SEED=... 和 --token-key dev=...
export THINKTIN_DEV_TOKEN_SEED=...

# 保存一把 key（从标准输入读，不进命令行参数），再手动在 dev.json 里加实例和别名
printf %s "$DEEPSEEK_KEY" | target/debug/llm-gw put-key --store dev.json --id cred-1 --user user-1 --vendor deepseek

target/debug/llm-gw serve --store dev.json --token-key dev=...
target/debug/llm-gw issue-token --instance inst-1 --user user-1 --sandbox sbx-1 --net 127.0.0.1
target/debug/llm-gw vendors                   # 厂商适配表

# 真实 agent 走网关的端到端测试：agent → agent-shim → llm-gw → 扮演厂商的替身
GW=1 tools/smoke/smoke.sh claude
GW=1 PROMPT='MOCK_TOOL:Bash:{"command": "touch x", "description": "touch"}' EXPECT=MOCK_DONE \
  tools/smoke/smoke.sh claude --harness cli --allow-tools execute
```

`--insecure-upstreams`（允许 http 和非公网上游）和 `--allow-unbound-tokens`（接受不绑定来源地址的令牌）只用于本地开发。

## 10. 已知问题与后续工作

| 问题 | 影响 | 后续 |
|---|---|---|
| 来源地址按 TCP 对端地址核对 | 网关前面如果有做 SNAT 的负载均衡，对端地址会变成负载均衡的地址 | 部署时让沙箱直连网关，或增加可信代理配置 |
| 预算请求前检查、响应后记账 | 同时在途的请求可能让当天用量略微超出上限 | 生产账本放 Redis，必要时预扣 |
| agent 中途断开时只记下已知的用量 | Anthropic 流式断开时输出 token 数只有 `message_start` 里的值，厂商实际计费可能更多 | 可接受；对账以厂商账单为准 |
| 只有 Chat Completions 接口的厂商不能给 Codex 用 | Codex 只会 Responses 协议 | 网关做协议转换（架构方案 5.3，后期） |
| 厂商适配表待逐家核实 | 地址和鉴权头以官方文档为准 | 9.7 |
| 路由数据、预算账本、用量记录都在内存或日志里 | 只适合开发 | 3.x 数据层、9.10 用量看板 |
